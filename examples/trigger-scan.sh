#!/usr/bin/env bash
# Queue the Snyk orchestrator pipeline for up to 5 repos.
#   ADO_ORG=myorg ADO_PROJECT=DevSecOps PIPELINE_ID=123 ADO_PAT=*** [MAX_TARGETS=5] ./trigger-scan.sh targets.json [requestId]
# targets.json = JSON array of scan targets ({repoId, branch, ...}; see azure-pipelines.yml).
# More targets than MAX_TARGETS are split into several runs.
# Tip: set PREVIEW=true to get the fully expanded YAML back without running anything.
set -euo pipefail
TARGETS_FILE=${1:?targets.json required}
REQ_ID=${2:-"bg-$(date -u +%Y%m%d%H%M%S)"}

MAX=${MAX_TARGETS:-5}

COUNT=$(jq 'length' "$TARGETS_FILE")
(( COUNT >= 1 )) || { echo "targets file is empty"; exit 1; }
MISSING=$(jq '[.[] | select((.repoId // "") == "" or (.branch // "") == "")] | length' "$TARGETS_FILE")
(( MISSING == 0 )) || { echo "$MISSING target(s) missing repoId or branch"; exit 1; }

BATCHES=$(( (COUNT + MAX - 1) / MAX ))
for (( b = 0; b < BATCHES; b++ )); do
  BATCH=$(jq -c --argjson s $((b * MAX)) --argjson n "$MAX" '.[$s:$s+$n]' "$TARGETS_FILE")
  BODY=$(jq -n \
    --arg req "$REQ_ID-$((b + 1))" \
    --arg targets "$BATCH" \
    --arg max "$MAX" \
    --argjson preview "${PREVIEW:-false}" \
    '{previewRun: $preview, templateParameters: {requestId: $req, maxTargets: $max, scanTargets: $targets}}')

  curl -sS --fail-with-body -u ":${ADO_PAT:?}" \
    -H 'Content-Type: application/json' \
    -X POST "https://dev.azure.com/${ADO_ORG:?}/${ADO_PROJECT:?}/_apis/pipelines/${PIPELINE_ID:?}/runs?api-version=7.1" \
    -d "$BODY" | jq '{id, name, state, url: ._links.web.href, finalYaml: (.finalYaml // null | if . then (.[0:400] + "…") else null end)}'
done
