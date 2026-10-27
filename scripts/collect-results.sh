#!/usr/bin/env bash
# Final step (always runs): keep outputs on the agent, write summary.json, prune old runs.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUT=${SCAN_OUT_DIR:?}
ROOT=${SCAN_RESULTS_ROOT:?}
mkdir -p "$OUT"

# 1. Snyk task (service-connection mode) writes its reports to the job temp dir,
#    which the agent wipes after the job — copy them next to our own outputs.
if [[ "${SCAN_AUTH_MODE:-}" == serviceConnection && -d "${AGENT_TEMPDIRECTORY:-}" ]]; then
  mkdir -p "$OUT/task-reports"
  find "$AGENT_TEMPDIRECTORY" -maxdepth 3 -type f \
       \( -name 'report*.json' -o -name 'report*.html' -o -iname '*snyk*.json' -o -iname '*snyk*.html' \) \
       -exec cp -f {} "$OUT/task-reports/" \; 2>/dev/null
  rmdir "$OUT/task-reports" 2>/dev/null || true
fi

# 2. summary.json
RESULTS="[]"
if [[ -f "$OUT/results.tsv" ]]; then
  RESULTS="["; first=1
  while IFS=$'\t' read -r scan status detail; do
    (( first )) || RESULTS+=","; first=0
    RESULTS+="{\"scan\":$(jstr "$scan"),\"status\":$(jstr "$status"),\"detail\":$(jstr "$detail")}"
  done < "$OUT/results.tsv"
  RESULTS+="]"
fi

cat > "$OUT/summary.json" <<EOF
{
  "requestId": $(jstr "${SCAN_REQUEST_ID:-}"),
  "buildId": $(jstr "${BUILD_BUILDID:-}"),
  "targetKey": $(jstr "${SCAN_KEY:-}"),
  "repository": $(jstr "${SCAN_REPO_PROJECT:-}/${SCAN_REPO_NAME:-}"),
  "repositoryUrl": $(jstr "${SCAN_REPO_WEBURL:-}"),
  "branch": $(jstr "${SCAN_REF:-}"),
  "headCommit": $(jstr "${SCAN_COMMIT:-}"),
  "cloneOk": $(jstr "${SCAN_CLONE_OK:-false}"),
  "jobStatus": $(jstr "${AGENT_JOBSTATUS:-}"),
  "agent": $(jstr "${AGENT_NAME:-}"),
  "authMode": $(jstr "${SCAN_AUTH_MODE:-}"),
  "cliResults": $RESULTS,
  "finishedUtc": $(jstr "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
}
EOF

# 3. Run-page summary (what was triggered — not vulnerability data)
MD="$OUT/summary.md"
{
  echo "### Snyk trigger • ${SCAN_REPO_PROJECT:-?}/${SCAN_REPO_NAME:-${SCAN_KEY:-?}}"
  echo "- Branch: \`${SCAN_REF:-n/a}\` (head \`${SCAN_COMMIT:0:12}\`)"
  echo "- Agent: \`${AGENT_NAME:-?}\` • outputs: \`$OUT\`"
  if [[ -f "$OUT/results.tsv" ]]; then
    echo; echo "| Scan | Status |"; echo "|---|---|"
    while IFS=$'\t' read -r s st _; do echo "| $s | $st |"; done < "$OUT/results.tsv"
  fi
} > "$MD"
echo "##vso[task.uploadsummary]$MD"

# 4. Free disk: drop the clone unless asked to keep it
if [[ "${SCAN_KEEP_SOURCE:-false}" != [Tt]rue && -n "${SCAN_SRC_DIR:-}" && -d "$SCAN_SRC_DIR" ]]; then
  rm -rf "$SCAN_SRC_DIR" && log "Removed source clone."
fi

# 5. Retention: delete run folders older than N days
DAYS=${SCAN_RETENTION_DAYS:-14}
if [[ "$ROOT" != "/" && -d "$ROOT" && "$DAYS" =~ ^[0-9]+$ && "$DAYS" -gt 0 ]]; then
  find "$ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +"$DAYS" -print -exec rm -rf {} + 2>/dev/null \
    | sed 's/^/[snyk-scan] pruned /'
fi

log "Results kept at $OUT"
ls -la "$OUT" || true
exit 0
