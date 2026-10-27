#!/usr/bin/env bash
# Shared helpers for the Snyk scan pipeline. Source, don't execute.

log()   { echo "[snyk-scan] $*"; }
warn()  { echo "##vso[task.logissue type=warning]$*"; }
error() { echo "##vso[task.logissue type=error]$*"; }
fail()  { error "$*"; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }

# Publish a job-scoped pipeline variable (visible to later steps).
setvar() { echo "##vso[task.setvariable variable=$1]${2:-}"; }
setsecret() { [[ -n "${1:-}" ]] && echo "##vso[task.setsecret]$1"; }
prependpath() { echo "##vso[task.prependpath]$1"; }
complete_with_issues() { echo "##vso[task.complete result=SucceededWithIssues;]$*"; }

# retry <max> <cmd...>  — linear backoff 5s, 10s, ...
retry() {
  local max=$1 n=1; shift
  until "$@"; do
    (( n >= max )) && return 1
    warn "Attempt $n/$max failed: $1 … retrying in $((n * 5))s"
    sleep $((n * 5)); n=$((n + 1))
  done
}

# json_get '<.path.to.key>'  (stdin JSON → scalar). Uses jq, falls back to python3.
json_get() {
  local path=$1
  if have jq; then
    jq -r "if ($path) == null then \"\" else ($path) end"
  else
    python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1].lstrip(".").split("."):
    d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else (str(d).lower() if isinstance(d, bool) else d))' "$path"
  fi
}

urlencode() {
  if have jq; then jq -rn --arg v "$1" '$v|@uri'
  else python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; fi
}

# Minimal JSON string escaper (no jq dependency for writing files).
jstr() {
  local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}
  printf '"%s"' "$s"
}

# jarr item1 item2 … → JSON array of strings
jarr() {
  local out="[" first=1 i
  for i in "$@"; do
    (( first )) || out+=","
    out+=$(jstr "$i"); first=0
  done
  printf '%s]' "$out"
}

# Record a step outcome for the run summary.
record_result() {   # record_result <scan> <status> <detail>
  mkdir -p "${SCAN_OUT_DIR:?}"
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$SCAN_OUT_DIR/results.tsv"
}
