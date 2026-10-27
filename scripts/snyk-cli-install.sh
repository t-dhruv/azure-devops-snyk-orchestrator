#!/usr/bin/env bash
# Make the Snyk CLI available on PATH for later steps.
# Order: cached copy (<7 days) -> JFrog download (previous step) -> SNYK_CLI_URL -> existing 'snyk' on PATH.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DEST="${AGENT_TOOLSDIRECTORY:-$HOME/.cache}/snyk-cli"
BIN="$DEST/snyk"
mkdir -p "$DEST"

# A JFrog download (jf rt dl --flat) lands as snyk-linux
if [[ -f "$DEST/snyk-linux" ]]; then mv -f "$DEST/snyk-linux" "$BIN" && chmod +x "$BIN"; fi

fresh() { [[ -x "$BIN" ]] && [[ -n "$(find "$BIN" -mtime -7 2>/dev/null)" ]]; }

if fresh; then
  log "Using cached Snyk CLI at $BIN"
elif [[ -n "${SNYK_CLI_URL:-}" ]] && curl -fsSL --retry 3 --retry-delay 5 -o "$BIN.tmp" "$SNYK_CLI_URL"; then
  chmod +x "$BIN.tmp" && mv -f "$BIN.tmp" "$BIN"
  log "Downloaded Snyk CLI from $SNYK_CLI_URL"
elif [[ -x "$BIN" ]]; then
  warn "Snyk CLI download failed; reusing stale cached copy."
elif have snyk; then
  BIN=$(command -v snyk); DEST=$(dirname "$BIN")
  log "Using Snyk CLI already on PATH: $BIN"
else
  fail "Snyk CLI unavailable: download failed and none installed. Set snykOptions.cliJfrogPath or preinstall 'snyk' on the agent."
fi

prependpath "$DEST"
"$BIN" --version || fail "Snyk CLI at $BIN is not runnable."
