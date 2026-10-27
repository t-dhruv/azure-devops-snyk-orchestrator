# Snyk Scan Orchestrator (Azure DevOps YAML)

## TL;DR

- **One pipeline, triggered by your background job** through the REST API. Each run takes **1–`maxTargets` repos** (default **5**, configurable). Each repo gets its **own stage**, and all the stages run **in parallel** on Linux agents.
- For each repo: **clone by repoId at the tip of the supplied branch → detect the tech stack → restore dependencies through JFrog → trigger Snyk (SCA, Code, IaC, Container) → keep the outputs on the agent**.
- **It only triggers scans.** Findings never fail the run. A broken restore or scan marks the job *SucceededWithIssues* and the other scans keep going.
- **Templates do the "dynamic" part.** At compile time, `technologies` and `scanTypes` decide which templates get included. At run time, `detect.sh` decides which of those steps actually run.

```bash
# Queue 2 repos (PAT needs Build: Read & execute)
cat > targets.json <<'EOF'
[
  { "repoId": "6b1e2f3a-1111-4c2d-9a8b-0f1e2d3c4b5a", "project": "Claims", "branch": "main" },
  { "repoId": "0a9b8c7d-2222-4e3f-8a7b-1c2d3e4f5a6b", "project": "Claims", "branch": "release/2026.10", "scanTypes": ["sca","code"] }
]
EOF
ADO_ORG=myorg ADO_PROJECT=DevSecOps PIPELINE_ID=123 ADO_PAT=*** MAX_TARGETS=5 ./examples/trigger-scan.sh targets.json
# More targets than MAX_TARGETS are split into several runs automatically.
# Dry run (returns the expanded YAML and queues nothing):
PREVIEW=true ADO_ORG=... ./examples/trigger-scan.sh targets.json
```

The scan outputs end up on the agent at `$(Agent.WorkFolder)/_snyk-results/<BuildId>/<repoKey>/`, which holds `summary.json`, `detection.json`, logs, JSON/SARIF files, and the task reports.

---

## Flow

```
Background job ──POST /pipelines/{id}/runs──▶ azure-pipelines.yml
                                               │  validates 1..maxTargets targets
                    ┌──────────────┬───────────┴───┬──────────────┐
                Scan_repoA     Scan_repoB      Scan_repoC  …  (parallel stages, dependsOn: [])
                    │
                    ├─ checkout self (templates + scripts)
                    ├─ clone-repo.sh     repoId → REST lookup → shallow fetch of branch tip
                    ├─ detect.sh         stacks, toolchains, restore roots, IaC, venv
                    ├─ restore/router    JfrogCliV2@1 per stack × up to 8 roots (runtime-gated)
                    ├─ snyk/router       SCA · Code · IaC · Container (task or CLI)
                    └─ collect-results   summary.json, copy reports, prune old runs
```

## Layout

```
azure-pipelines.yml                 entry: runtime parameters, maxTargets guard, fan-out
templates/stages/scan-target.yml    one stage+job per repo
templates/steps/checkout-target.yml
templates/steps/detect.yml
templates/steps/restore/router.yml  which stacks to consider (compile time)
templates/steps/restore/jfrog-restore.yml   generic JFrog restore unrolled over slots
templates/steps/snyk/{router,setup-cli,cli-step,sca,code,iac,container}.yml
templates/steps/finalize.yml
scripts/*.sh                        all logic lives here (shellcheck-clean, testable locally)
examples/                           REST body, bash trigger, C# trigger client
```

## Repos per run (`maxTargets`)

- Pipeline parameter `maxTargets` (default `5`). A run with 0 or more than `maxTargets` targets fails fast in a single `InvalidRequest` stage, before any agent work.
- Both trigger examples batch automatically: `MAX_TARGETS` in `trigger-scan.sh`, `maxTargetsPerRun` in `SnykScanTrigger.cs`. Each also sends the value as `maxTargets`, so the job and the pipeline always agree.
- To lock the limit so callers can't raise it, delete the `maxTargets` parameter and hard-code the number in the guard expression in `azure-pipelines.yml`.

## Scan target shape (`scanTargets` item)

| Field | Required | Default | Notes |
|---|---|---|---|
| `repoId` | ✅ | — | Azure Repos GUID. Works across projects. |
| `project` | | — | Speeds up the lookup. Without it, the org-level API is used. |
| `branch` | ✅ | — | Cloned at its **tip** (`main` or `refs/heads/main`). Also sent to Snyk as `--target-reference`. The head SHA that got scanned is recorded in `summary.json` for traceability. |
| `key` | | repoId with `-`→`_` | Stage name suffix. `[A-Za-z0-9_]` only. Must be unique within the run, so set it if the same repo appears twice (e.g. two branches). The C# client does this for you. |
| `technologies` | | `[auto]` | `auto` · `none` · `dotnet` `npm` `maven` `gradle` `python` `go` |
| `scanTypes` | | `defaultScanTypes` (`sca, code, iac`) | `sca` `code` `iac` `container` |
| `containerImages` | | — | `[{ image, dockerfile }]`. Only used when `container` is in `scanTypes`. |
| `submodules` | | `false` | |

> Over REST, an **object parameter is sent as a JSON string** (`"scanTargets": "[{...}]"`). See `examples/run-request.json`. Check that your org accepts it by sending the body once with `"previewRun": true`.

## Technology handling

| Stack | Detected by | Restore (JFrog) | Notes |
|---|---|---|---|
| .NET | `*.csproj/fsproj/vbproj` | `jf dotnet restore` on a generated **aggregate .sln** that contains every project | `global.json` SDK pin is relaxed (`rollForward=latestMajor`) in the throw-away clone. `packages.config` is read as-is. |
| npm/yarn/pnpm | `package.json` | Only for roots **without** a lockfile (`jf npm install --ignore-scripts`) | Lockfiles are scanned directly. Workspace roots cover their children. |
| Maven | top-most `pom.xml` | `jf mvn dependency:tree` | Pre-fetches the deps that Snyk's own `dependency:tree` call needs. |
| Gradle | `settings.gradle(.kts)` roots + standalone `build.gradle` | `jf gradle dependencies` (uses the wrapper when present) | Best effort, because Snyk re-resolves through the repos declared in the build. |
| Python | `requirements*.txt` | `jf pip install -r` into an **isolated venv** | Snyk gets `--command=<venv python> --skip-unresolved`. Poetry/Pipfile locks are read directly. |
| Go | every `go.mod` | `jf go mod download` | Fills the module cache used by Snyk's `go list`. |
| Ruby, PHP, Rust, Swift, Dart, Elixir… | lockfiles | none needed | Snyk reads the lockfile. |
| IaC | `*.tf`, Helm, K8s/CFN/ARM manifests | — | Snyk IaC (CLI). |
| Anything else | — | — | Snyk Code still runs, and `--all-projects` picks up whatever it supports. |

A missing toolchain on the agent produces a **warning** and the scan continues without restore. It never errors.

## Auth modes

| | `snykAuthMode: serviceConnection` (default) | `snykAuthMode: token` |
|---|---|---|
| SCA / Code / Container | `SnykSecurityScan@1` + Snyk service connection | Snyk CLI + `SNYK_TOKEN` from a variable group (Key Vault-linked recommended) |
| IaC | CLI. Needs `snykTokenVariableGroup` too, otherwise it's skipped with a warning | CLI |
| Local outputs | Task reports copied from the job temp dir (best effort) | JSON + SARIF for every scan |
| Snyk CLI download | The task downloads it from Snyk's CDN | Cached on the agent. Can come from JFrog (`snykOptions.cliJfrogPath`) |

Snyk results are uploaded with `monitor` / `--report`, so your dashboard reads them from Snyk.

## One-time setup

1. **Extensions:** *Snyk Security Scan* and *JFrog* (Azure DevOps Marketplace).
2. **Service connections:** JFrog Platform V2 (`jfrogServiceConnection`) and Snyk (`snykServiceConnection`). Optionally add a JFrog Artifactory V2 connection (`jfrogArtifactoryConnection`) if agents can't reach `releases.jfrog.io` for the JFrog CLI and extractors.
3. **Variable group** (for token mode or IaC): secret `SNYK_TOKEN`.
4. **Pre-authorize** the pool, the service connections and the variable group for this pipeline. REST-triggered runs can't click *Permit*.
5. **Repo access for cloning by ID:**
   - Give *Project Collection Build Service (org)* **Read** on the target repos (org level is easiest).
   - Turn off *Limit job authorization scope to current project* and *Protect access to repositories in YAML pipelines* for this project. If you'd rather leave them on, set `gitTokenVariable` to a secret variable that holds a PAT or service-principal token.
6. **Agents:** Linux, at least `maxTargets` agents in `poolName` and the same number of self-hosted parallel jobs. With fewer, stages queue instead of running in parallel. Needs `git curl jq` (or `python3`), plus the toolchains you want restored: `dotnet`, `node/npm`, `java+mvn/gradle`, `python3-venv`, `go`, and `docker` for container scans.
7. Update the `jfrogRepos` defaults (virtual repo names) in `azure-pipelines.yml`.

## Verify on the first real run

- `JfrogCliV2@1` → `workingDirectory` input. If your extension version ignores it, the restore runs in the wrong folder. Check the step log (`.jfrog/projects/*.yaml` should appear under the target root).
- `SnykSecurityScan@1` → `testDirectory` gets an absolute path. Snyk documents it as relative. If the task scans the pipeline repo instead, switch to `../src`.
- A good smoke test is one small test repo that mixes several stacks. `detection.json` shows exactly what was planned.

## Extending

- **New stack:** add its detection to `scripts/detect.sh` (publish `SCAN_<TECH>_ROOT_<n>`), then add one block to `templates/steps/restore/router.yml`.
- **More roots per stack:** raise `slots` in `jfrog-restore.yml` and `SCAN_RESTORE_SLOTS` together.
- **New scan type:** add `templates/steps/snyk/<type>.yml` and a case in `scripts/snyk-cli-scan.sh`.

## Local testing

```bash
shellcheck -x scripts/*.sh
SCAN_SRC_DIR=/path/to/any/repo SCAN_OUT_DIR=/tmp/out AGENT_TEMPDIRECTORY=/tmp bash scripts/detect.sh
cat /tmp/out/detection.json
```
