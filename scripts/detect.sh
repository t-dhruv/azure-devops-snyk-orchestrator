#!/usr/bin/env bash
# Detect ecosystems in the cloned repo and prepare restore entry points.
#
# Publishes (job variables):
#   SCAN_<TECH>_ROOT_<n>     project roots needing a JFrog restore ('' = slot unused)
#   SCAN_DOTNET_ENTRY_1      aggregate .sln covering every .NET project
#   SCAN_GRADLE_WRAPPER_<n>  true|false
#   SCAN_PYTHON_REQ_<n>      requirements file per slot
#   SCAN_NEEDS_RESTORE       true if any slot is set
#   SCAN_HAS_IAC             true if IaC files exist
#   SCAN_HAS_DOCKER_CLI      true if docker is on the agent
#   SCAN_SNYK_EXCLUDE        value for snyk --exclude
#   SCAN_SNYK_PY_ARGS        python flags for snyk (venv interpreter, skip unresolved)
# Writes $SCAN_OUT_DIR/detection.json
#
# Never fails the job for a missing toolchain: it warns and lets Snyk scan
# whatever it can (lockfiles, Snyk Code, IaC).
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC=${SCAN_SRC_DIR:?}
OUT=${SCAN_OUT_DIR:?}
SLOTS=${SCAN_RESTORE_SLOTS:-8}
TMPD=${AGENT_TEMPDIRECTORY:-/tmp}
TECHS=",${SCAN_TECHNOLOGIES:-auto},"; TECHS=${TECHS// /}; TECHS=${TECHS,,}
TECHS=${TECHS//,nuget,/,dotnet,}; TECHS=${TECHS//,pip,/,python,}
mkdir -p "$OUT"

allowed() { [[ "$TECHS" != *",none,"* ]] && [[ "$TECHS" == *",auto,"* || "$TECHS" == *",$1,"* ]]; }
rel()     { local p=${1#"$SRC"}; p=${p#/}; printf '%s' "${p:-.}"; }

PRUNE_NAMES=(.git node_modules bin obj target dist build out vendor .venv venv __pycache__
             .snyk-restore .jfrog .terraform .gradle .idea .vs bower_components)
PRUNE=()
for n in "${PRUNE_NAMES[@]}"; do PRUNE+=(-name "$n" -o); done
unset 'PRUNE[${#PRUNE[@]}-1]'

# find_files <find -name expr…>  → sorted absolute paths, build/vendor dirs pruned
find_files() {
  find "$SRC" -type d \( "${PRUNE[@]}" \) -prune -o -type f \( "$@" \) -print 2>/dev/null | LC_ALL=C sort
}
dirs_of()  { while IFS= read -r f; do [[ -n "$f" ]] && dirname "$f"; done; }
# Keep only directories that have no ancestor in the same list.
top_most() {
  local -a kept=(); local d k skip
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    skip=0
    for k in ${kept[@]+"${kept[@]}"}; do
      if [[ "$d" == "$k" || "$d" == "$k"/* ]]; then skip=1; break; fi
    done
    (( skip )) || kept+=("$d")
  done < <(LC_ALL=C sort -u)
  [[ ${#kept[@]} -gt 0 ]] && printf '%s\n' "${kept[@]}"
}
# publish_slots <PREFIX> <KEY> items…  → PREFIX_KEY_1..N
publish_slots() {
  local prefix=$1 key=$2 i; shift 2
  local -a items=("$@")
  for (( i = 1; i <= SLOTS; i++ )); do setvar "${prefix}_${key}_${i}" "${items[i-1]:-}"; done
  if (( ${#items[@]} > SLOTS )); then
    warn "${prefix#SCAN_}: ${#items[@]} roots found, restoring the first $SLOTS; the rest are scanned without restore."
  fi
}

declare -A RESTORE=()     # tech -> JSON array of relative roots
FOUND=(); NOTES=()
NEEDS_RESTORE=false
note() { NOTES+=("$*"); warn "$*"; }

# Reset every slot so runtime conditions never see an undefined macro.
for t in DOTNET NPM MAVEN GRADLE PYTHON GO; do publish_slots "SCAN_$t" ROOT; done
publish_slots SCAN_DOTNET ENTRY
publish_slots SCAN_GRADLE WRAPPER
publish_slots SCAN_PYTHON REQ
PY_ARGS=""

# ---------------------------------------------------------------------------
# .NET — one aggregate solution so a single `jf dotnet restore` covers everything
# ---------------------------------------------------------------------------
relax_global_json() {
  have jq || return 0
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if jq -e '.sdk.version' "$f" >/dev/null 2>&1; then
      jq '.sdk.rollForward = "latestMajor" | .sdk.allowPrerelease = true' "$f" > "$f.tmp" 2>/dev/null \
        && mv "$f.tmp" "$f" && log "Relaxed SDK pin in $(rel "$f") (rollForward=latestMajor)"
    fi
  done < <(find_files -name global.json)
}

mapfile -t DOTNET_PROJ < <(find_files -name '*.csproj' -o -name '*.fsproj' -o -name '*.vbproj')
if (( ${#DOTNET_PROJ[@]} )); then
  FOUND+=(dotnet)
  if ! allowed dotnet; then
    log ".NET found but not in technologies list — no restore."
  elif ! have dotnet; then
    note ".NET projects found but 'dotnet' SDK is not on the agent; scanning without restore."
  else
    relax_global_json
    RD="$SRC/.snyk-restore"; mkdir -p "$RD"
    new_sln() {
      rm -f "$RD"/SnykRestore.sln*
      ( cd "$RD" && { dotnet new sln -n SnykRestore --format sln >/dev/null 2>&1 \
                      || dotnet new sln -n SnykRestore >/dev/null 2>&1; } )
      find "$RD" -maxdepth 1 -name 'SnykRestore.sln*' | head -1
    }
    SLN=$(new_sln)
    if [[ -z "$SLN" ]]; then
      note "Could not create aggregate solution (dotnet new sln failed); .NET scanned without restore."
    else
      if ! dotnet sln "$SLN" add --in-root "${DOTNET_PROJ[@]}" > "$OUT/dotnet-sln.log" 2>&1; then
        SLN=$(new_sln)
        for p in "${DOTNET_PROJ[@]}"; do
          dotnet sln "$SLN" add --in-root "$p" >> "$OUT/dotnet-sln.log" 2>&1 \
            || warn "Could not add $(rel "$p") to restore solution."
        done
      fi
      publish_slots SCAN_DOTNET ROOT "$RD"
      publish_slots SCAN_DOTNET ENTRY "$SLN"
      RESTORE[dotnet]=$(jarr "$(rel "$SLN") (${#DOTNET_PROJ[@]} projects)")
      NEEDS_RESTORE=true
    fi
  fi
fi

# ---------------------------------------------------------------------------
# npm — restore only package.json roots with no lockfile (self or ancestor)
# ---------------------------------------------------------------------------
has_js_lock_upwards() {
  local d=$1
  while :; do
    for l in package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock; do
      [[ -f "$d/$l" ]] && return 0
    done
    [[ "$d" == "$SRC" || "$d" == "/" ]] && return 1
    d=$(dirname "$d")
  done
}
mapfile -t PKG_FILES < <(find_files -name package.json)
if (( ${#PKG_FILES[@]} )); then
  FOUND+=(npm)
  NPM_ROOTS=(); NPM_WS=()
  for f in "${PKG_FILES[@]}"; do
    d=$(dirname "$f")
    has_js_lock_upwards "$d" && continue
    in_ws=0
    for w in ${NPM_WS[@]+"${NPM_WS[@]}"}; do [[ "$d" == "$w"/* ]] && { in_ws=1; break; }; done
    (( in_ws )) && continue
    NPM_ROOTS+=("$d")
    grep -q '"workspaces"' "$f" && NPM_WS+=("$d")
  done
  if (( ${#NPM_ROOTS[@]} )); then
    if ! allowed npm; then log "npm roots without lockfile found but npm not in technologies list."
    elif ! have npm;  then note "npm projects without lockfile found but 'npm' is not on the agent."
    else
      publish_slots SCAN_NPM ROOT "${NPM_ROOTS[@]}"
      RESTORE[npm]=$(jarr "${NPM_ROOTS[@]/#$SRC/.}")
      NEEDS_RESTORE=true
    fi
  else
    log "npm: every package.json is covered by a lockfile — no restore needed."
  fi
fi

# ---------------------------------------------------------------------------
# Maven — top-most pom.xml (reactor root covers its modules)
# ---------------------------------------------------------------------------
mapfile -t MVN_ROOTS < <(find_files -name pom.xml | dirs_of | top_most)
if (( ${#MVN_ROOTS[@]} )); then
  FOUND+=(maven)
  if ! allowed maven; then log "Maven found but not in technologies list."
  elif ! have mvn;    then note "Maven projects found but 'mvn' is not on the agent."
  else
    publish_slots SCAN_MAVEN ROOT "${MVN_ROOTS[@]}"
    RESTORE[maven]=$(jarr "${MVN_ROOTS[@]/#$SRC/.}")
    NEEDS_RESTORE=true
  fi
fi

# ---------------------------------------------------------------------------
# Gradle — settings.gradle roots, plus standalone build.gradle outside them
# ---------------------------------------------------------------------------
mapfile -t GR_SETTINGS < <(find_files -name 'settings.gradle' -o -name 'settings.gradle.kts' | dirs_of | top_most)
mapfile -t GR_BUILDS   < <(find_files -name 'build.gradle'    -o -name 'build.gradle.kts'    | dirs_of | top_most)
GR_ROOTS=(${GR_SETTINGS[@]+"${GR_SETTINGS[@]}"})
for b in ${GR_BUILDS[@]+"${GR_BUILDS[@]}"}; do
  covered=0
  for s in ${GR_SETTINGS[@]+"${GR_SETTINGS[@]}"}; do [[ "$b" == "$s" || "$b" == "$s"/* ]] && { covered=1; break; }; done
  (( covered )) || GR_ROOTS+=("$b")
done
if (( ${#GR_ROOTS[@]} )); then
  FOUND+=(gradle)
  if ! allowed gradle; then log "Gradle found but not in technologies list."
  else
    GR_OK=(); GR_WRAP=()
    for r in "${GR_ROOTS[@]}"; do
      if [[ -f "$r/gradlew" ]]; then chmod +x "$r/gradlew"; GR_OK+=("$r"); GR_WRAP+=(true)
      elif have gradle;        then GR_OK+=("$r"); GR_WRAP+=(false)
      else note "Gradle root $(rel "$r") has no wrapper and 'gradle' is not on the agent."
      fi
    done
    if (( ${#GR_OK[@]} )); then
      if ! have java; then note "Gradle projects found but 'java' is not on the agent."
      else
        publish_slots SCAN_GRADLE ROOT    "${GR_OK[@]}"
        publish_slots SCAN_GRADLE WRAPPER "${GR_WRAP[@]}"
        RESTORE[gradle]=$(jarr "${GR_OK[@]/#$SRC/.}")
        NEEDS_RESTORE=true
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Python (pip) — isolated venv, one slot per requirements file
# ---------------------------------------------------------------------------
mapfile -t PY_REQS < <(find_files -name 'requirements*.txt' -o -path '*/requirements/*.txt')
mapfile -t PY_OTHER < <(find_files -name 'pyproject.toml' -o -name 'setup.py' -o -name 'Pipfile' -o -name 'poetry.lock')
if (( ${#PY_REQS[@]} + ${#PY_OTHER[@]} )); then
  FOUND+=(python)
  PY_BIN=$(command -v python3 || command -v python || true)
  if [[ -z "$PY_BIN" ]]; then
    note "Python manifests found but no python3 on the agent."
  else
    VENV="$TMPD/snyk-venv"
    if "$PY_BIN" -m venv "$VENV" >/dev/null 2>&1 || { have virtualenv && virtualenv -q "$VENV" >/dev/null 2>&1; }; then
      prependpath "$VENV/bin"           # later steps (jf pip, snyk) use the venv
      PY_ARGS="--command=$VENV/bin/python --skip-unresolved"
      if (( ${#PY_REQS[@]} )) && allowed python; then
        PY_DIRS=(); for r in "${PY_REQS[@]}"; do PY_DIRS+=("$(dirname "$r")"); done
        publish_slots SCAN_PYTHON ROOT "${PY_DIRS[@]}"
        publish_slots SCAN_PYTHON REQ  "${PY_REQS[@]}"
        RESTORE[python]=$(jarr "${PY_REQS[@]/#$SRC/.}")
        NEEDS_RESTORE=true
      fi
    else
      note "Could not create a Python venv (install python3-venv on the agent); pip restore skipped."
      PY_ARGS="--command=$PY_BIN --skip-unresolved"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Go modules — every go.mod is its own module
# ---------------------------------------------------------------------------
mapfile -t GO_ROOTS < <(find_files -name go.mod | dirs_of)
if (( ${#GO_ROOTS[@]} )); then
  FOUND+=(go)
  if ! allowed go; then log "Go found but not in technologies list."
  elif ! have go;   then note "Go modules found but 'go' is not on the agent."
  else
    publish_slots SCAN_GO ROOT "${GO_ROOTS[@]}"
    RESTORE[go]=$(jarr "${GO_ROOTS[@]/#$SRC/.}")
    NEEDS_RESTORE=true
  fi
fi

# ---------------------------------------------------------------------------
# Lockfile-only ecosystems (Snyk reads these directly — nothing to restore)
# ---------------------------------------------------------------------------
mapfile -t LOCK_ONLY < <(find_files -name Gemfile.lock -o -name composer.lock -o -name Cargo.lock \
  -o -name Package.resolved -o -name Podfile.lock -o -name pubspec.lock -o -name mix.lock \
  -o -name packages.config -o -name Pipfile.lock -o -name poetry.lock -o -name packages.lock.json)

# ---------------------------------------------------------------------------
# IaC + containers
# ---------------------------------------------------------------------------
HAS_IAC=false
if [[ -n "$(find_files -name '*.tf' -o -name '*.tf.json' -o -name 'Chart.yaml' | head -1)" ]]; then
  HAS_IAC=true
else
  while IFS= read -r f; do
    if grep -qsE '^(apiVersion:|AWSTemplateFormatVersion|Resources:)' "$f" \
       || grep -qs 'deploymentTemplate.json' "$f"; then HAS_IAC=true; break; fi
  done < <(find_files -name '*.yaml' -o -name '*.yml' -o -name '*.json' | head -3000)
fi
mapfile -t DOCKERFILES < <(find_files -name 'Dockerfile' -o -name 'Dockerfile.*' -o -name '*.Dockerfile')

# ---------------------------------------------------------------------------
# Publish
# ---------------------------------------------------------------------------
EXCLUDE=".snyk-restore,.jfrog"
[[ -n "${SCAN_EXTRA_EXCLUDE:-}" ]] && EXCLUDE+=",${SCAN_EXTRA_EXCLUDE}"

setvar SCAN_NEEDS_RESTORE "$NEEDS_RESTORE"
setvar SCAN_HAS_IAC "$HAS_IAC"
setvar SCAN_HAS_DOCKER_CLI "$(have docker && echo true || echo false)"
setvar SCAN_SNYK_EXCLUDE "$EXCLUDE"
setvar SCAN_SNYK_PY_ARGS "$PY_ARGS"

TOOLS="{"; first=1
for t in git jq curl dotnet node npm java mvn gradle python3 go docker jf snyk; do
  (( first )) || TOOLS+=","; first=0
  TOOLS+="\"$t\":$(have "$t" && echo true || echo false)"
done; TOOLS+="}"

RESTORE_JSON="{"; first=1
for k in "${!RESTORE[@]}"; do
  (( first )) || RESTORE_JSON+=","; first=0
  RESTORE_JSON+="$(jstr "$k"):${RESTORE[$k]}"
done; RESTORE_JSON+="}"

LOCK_REL=(); for l in ${LOCK_ONLY[@]+"${LOCK_ONLY[@]}"}; do LOCK_REL+=("$(rel "$l")"); done
DF_REL=();   for d in ${DOCKERFILES[@]+"${DOCKERFILES[@]}"}; do DF_REL+=("$(rel "$d")"); done

cat > "$OUT/detection.json" <<EOF
{
  "technologiesRequested": $(jstr "${SCAN_TECHNOLOGIES:-auto}"),
  "technologiesFound": $(jarr ${FOUND[@]+"${FOUND[@]}"}),
  "restorePlan": $RESTORE_JSON,
  "lockfileOnly": $(jarr ${LOCK_REL[@]+"${LOCK_REL[@]}"}),
  "iac": $HAS_IAC,
  "dockerfiles": $(jarr ${DF_REL[@]+"${DF_REL[@]}"}),
  "tools": $TOOLS,
  "notes": $(jarr ${NOTES[@]+"${NOTES[@]}"})
}
EOF

log "Technologies found : ${FOUND[*]:-none}"
log "Restore needed     : $NEEDS_RESTORE"
log "IaC files          : $HAS_IAC"
log "Lockfile-only      : ${#LOCK_ONLY[@]} file(s)"
log "Detection written  : $OUT/detection.json"
exit 0
