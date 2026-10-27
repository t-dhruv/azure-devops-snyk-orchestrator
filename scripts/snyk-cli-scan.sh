#!/usr/bin/env bash
# Run one Snyk CLI scan and keep its outputs on the agent.
#   usage: snyk-cli-scan.sh <sca|code|iac|container>
#
# Exit-code policy (trigger-only pipeline):
#   0 ok | 1 issues found (still ok) | 3 nothing to scan (info) | anything else -> SucceededWithIssues
# The step itself never fails the job.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE=${1:?mode required}
: "${SCAN_SRC_DIR:?}" "${SCAN_OUT_DIR:?}"
[[ -n "${SNYK_TOKEN:-}" && "$SNYK_TOKEN" != '$('* ]] || fail "SNYK_TOKEN is not available (check snykTokenVariableGroup)."
have snyk || fail "snyk CLI not on PATH (setup-cli step failed?)."

mkdir -p "$SCAN_OUT_DIR"
cd "$SCAN_SRC_DIR" || fail "Source dir missing: $SCAN_SRC_DIR"

COMMON=()
[[ -n "${SCAN_SNYK_ORG:-}" ]] && COMMON+=("--org=$SCAN_SNYK_ORG")
REPO_ARGS=()
[[ -n "${SCAN_REPO_WEBURL:-}" ]] && REPO_ARGS+=("--remote-repo-url=$SCAN_REPO_WEBURL")
[[ -n "${SCAN_REF:-}" ]]         && REPO_ARGS+=("--target-reference=$SCAN_REF")
PROJECT_NAME="${SCAN_REPO_PROJECT:-ado}/${SCAN_REPO_NAME:-$SCAN_KEY}"
read -r -a EXTRA <<< "${SCAN_EXTRA_ARGS:-}"
read -r -a PY    <<< "${SCAN_SNYK_PY_ARGS:-}"

run() {   # run <label> <stdout-file> <log-file> <cmd…>   (same file twice = combined)
  local label=$1 outf=$2 logf=$3; shift 3
  log "▶ $label: $*"
  if [[ "$outf" == "$logf" ]]; then "$@" > "$logf" 2>&1; else "$@" > "$outf" 2> "$logf"; fi
  local rc=$?
  tail -n 40 "$logf"
  case $rc in
    0) record_result "$label" ok "" ;;
    1) record_result "$label" issues-found "" ;;
    3) record_result "$label" nothing-to-scan ""; log "$label: no supported files." ;;
    *) record_result "$label" failed "exit $rc"; warn "$label exited $rc — see $logf"; FAILED=1 ;;
  esac
}
FAILED=0
O=$SCAN_OUT_DIR

case "$MODE" in
  sca)
    SCA=(--all-projects "--detection-depth=${SCAN_DETECTION_DEPTH:-8}" "--exclude=${SCAN_SNYK_EXCLUDE:-.snyk-restore,.jfrog}")
    run sca-monitor "$O/sca-monitor.json" "$O/sca-monitor.log" \
      snyk monitor "${SCA[@]}" ${PY[@]+"${PY[@]}"} "${COMMON[@]}" "${REPO_ARGS[@]}" --json ${EXTRA[@]+"${EXTRA[@]}"}
    if [[ "${SCAN_SCA_ALSO_TEST:-false}" == [Tt]rue ]]; then
      run sca-test "$O/sca-test.log" "$O/sca-test.log" \
        snyk test "${SCA[@]}" ${PY[@]+"${PY[@]}"} "${COMMON[@]}" \
          "--json-file-output=$O/sca-test.json" ${EXTRA[@]+"${EXTRA[@]}"}
    fi
    ;;
  code)
    CODE=("--sarif-file-output=$O/code.sarif" "--json-file-output=$O/code.json")
    if [[ "${SCAN_CODE_REPORT:-true}" == [Tt]rue ]]; then
      CODE+=(--report "--project-name=$PROJECT_NAME" "${REPO_ARGS[@]}")
    fi
    run code "$O/code.log" "$O/code.log" snyk code test "${CODE[@]}" "${COMMON[@]}" ${EXTRA[@]+"${EXTRA[@]}"}
    ;;
  iac)
    run iac "$O/iac.log" "$O/iac.log" \
      snyk iac test --report "${COMMON[@]}" "${REPO_ARGS[@]}" \
        "--json-file-output=$O/iac.json" "--sarif-file-output=$O/iac.sarif" ${EXTRA[@]+"${EXTRA[@]}"}
    ;;
  container)
    : "${SCAN_IMAGE:?SCAN_IMAGE required}"
    safe=$(printf '%s' "$SCAN_IMAGE" | tr -c 'A-Za-z0-9._-' '_')
    CT=("$SCAN_IMAGE" "--project-name=$SCAN_IMAGE" --json)
    [[ -n "${SCAN_DOCKERFILE:-}" && -f "$SCAN_DOCKERFILE" ]] && CT+=("--file=$SCAN_DOCKERFILE")
    run "container:$SCAN_IMAGE" "$O/container-$safe.json" "$O/container-$safe.log" \
      snyk container monitor "${CT[@]}" "${COMMON[@]}" ${EXTRA[@]+"${EXTRA[@]}"}
    ;;
  *) fail "Unknown mode '$MODE'." ;;
esac

(( FAILED )) && complete_with_issues "Snyk $MODE did not complete cleanly."
exit 0
