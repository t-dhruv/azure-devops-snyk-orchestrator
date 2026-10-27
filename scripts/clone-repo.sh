#!/usr/bin/env bash
# Resolve an Azure Repos repository by ID and shallow-clone the tip of the requested branch.
#
# Env (from template): GIT_TOKEN TARGET_JSON TARGET_REPO_ID TARGET_PROJECT
#                      TARGET_BRANCH TARGET_SUBMODULES
# Env (pipeline)     : SYSTEM_COLLECTIONURI SCAN_SRC_DIR SCAN_OUT_DIR SCAN_KEY SCAN_REQUEST_ID
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

setvar SCAN_CLONE_OK false

: "${SCAN_SRC_DIR:?}" "${SCAN_OUT_DIR:?}" "${SYSTEM_COLLECTIONURI:?}"
REPO_ID=${TARGET_REPO_ID:-}
PROJECT=${TARGET_PROJECT:-}
BRANCH=${TARGET_BRANCH:-}
BRANCH=${BRANCH#refs/heads/}
SUBMODULES=${TARGET_SUBMODULES:-false}

[[ -n "${GIT_TOKEN:-}" && "${GIT_TOKEN}" != '$('* ]] \
  || fail "No git token. Map '${GIT_TOKEN:-gitTokenVariable}' or allow scripts to access the OAuth token."

GUID_RE='^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
[[ "$REPO_ID" =~ $GUID_RE ]] || fail "repoId '$REPO_ID' is not a valid GUID."
[[ -n "$BRANCH" ]] || fail "branch is required for repo $REPO_ID."
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || fail "branch '$BRANCH' is not a valid branch name."

mkdir -p "$SCAN_OUT_DIR"
printf '%s\n' "${TARGET_JSON:-}" > "$SCAN_OUT_DIR/target.json"
echo "##vso[build.addbuildtag]snyk-req-${SCAN_REQUEST_ID:-manual}"

# ---- 1. Resolve repository metadata --------------------------------------------
ORG_URL=${SYSTEM_COLLECTIONURI%/}
AUTH_B64=$(printf ':%s' "$GIT_TOKEN" | base64 | tr -d '\n')
setsecret "$AUTH_B64"

api_get() {   # api_get <url> <outfile>  → echoes HTTP code
  curl -sS --retry 3 --retry-delay 3 -o "$2" -w '%{http_code}' \
       -H "Authorization: Basic $AUTH_B64" -H 'Accept: application/json' "$1" || echo 000
}

META=$(mktemp)
urls=()
[[ -n "$PROJECT" ]] && urls+=("$ORG_URL/$(urlencode "$PROJECT")/_apis/git/repositories/$REPO_ID?api-version=7.1")
urls+=("$ORG_URL/_apis/git/repositories/$REPO_ID?api-version=7.1")

code=000
for u in "${urls[@]}"; do
  code=$(api_get "$u" "$META")
  [[ "$code" == 200 ]] && break
done
case "$code" in
  200) ;;
  401|403) fail "HTTP $code reading repo $REPO_ID. Grant the build identity 'Read' on the repo, and disable 'Limit job authorization scope' / 'Protect access to repositories in YAML pipelines' (or use a PAT/service-principal token via gitTokenVariable)." ;;
  404) fail "Repository $REPO_ID not found (or not visible to the build identity)." ;;
  *)   fail "Unexpected HTTP $code from Repositories API for $REPO_ID." ;;
esac

REMOTE_URL=$(json_get '.remoteUrl'      < "$META")
REPO_NAME=$( json_get '.name'           < "$META")
REPO_PROJ=$( json_get '.project.name'   < "$META")
WEB_URL=$(   json_get '.webUrl'         < "$META")
DEF_BRANCH=$(json_get '.defaultBranch'  < "$META")
DISABLED=$(  json_get '.isDisabled'     < "$META")
cp "$META" "$SCAN_OUT_DIR/repo.json"; rm -f "$META"

[[ "$DISABLED" == true ]] && fail "Repository $REPO_PROJ/$REPO_NAME is disabled."
[[ -n "$REMOTE_URL" ]]    || fail "Repositories API returned no remoteUrl for $REPO_ID."

REF=$BRANCH
[[ -n "$DEF_BRANCH" ]] || fail "Repository $REPO_PROJ/$REPO_NAME is empty."

log "Repo     : $REPO_PROJ/$REPO_NAME ($REPO_ID)"
log "Branch   : $REF"

# ---- 2. Shallow clone -------------------------------------------------------------
rm -rf "$SCAN_SRC_DIR"; mkdir -p "$SCAN_SRC_DIR"
export GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1
git_auth=(-c "http.extraheader=AUTHORIZATION: basic $AUTH_B64" -c core.longpaths=true -c advice.detachedHead=false)

git -C "$SCAN_SRC_DIR" init -q
git -C "$SCAN_SRC_DIR" remote add origin "$REMOTE_URL"

retry 3 git "${git_auth[@]}" -C "$SCAN_SRC_DIR" fetch -q --depth 1 --no-tags origin "refs/heads/$REF" \
  || fail "Could not fetch branch '$REF' from $REPO_PROJ/$REPO_NAME (does it exist?)."
git -C "$SCAN_SRC_DIR" checkout -q --detach FETCH_HEAD
RESOLVED=$(git -C "$SCAN_SRC_DIR" rev-parse HEAD)

if [[ "$SUBMODULES" == true || "$SUBMODULES" == True ]]; then
  git "${git_auth[@]}" -C "$SCAN_SRC_DIR" submodule update --init --recursive --depth 1 \
    || warn "Submodule update failed; scanning without submodules."
fi

# ---- 3. Publish metadata ----------------------------------------------------------
setvar SCAN_REPO_NAME    "$REPO_NAME"
setvar SCAN_REPO_PROJECT "$REPO_PROJ"
setvar SCAN_REPO_WEBURL  "$WEB_URL"
setvar SCAN_REF          "$REF"
setvar SCAN_COMMIT       "$RESOLVED"    # informational: branch head that was scanned
setvar SCAN_CLONE_OK     true
log "Checked out $RESOLVED into $SCAN_SRC_DIR"
