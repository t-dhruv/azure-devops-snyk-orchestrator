# First-run checklist

Everything you need to set up before the first test run. Work through the sections top to bottom.

## TL;DR

| # | What | Where | Example value |
|---|---|---|---|
| 1 | Install 2 extensions | ADO → Organization settings → Extensions | *Snyk Security Scan*, *JFrog* |
| 2 | JFrog service connection | Project settings → Service connections → **JFrog Platform V2** | name `jfrog-platform` |
| 3 | Snyk service connection | Project settings → Service connections → **Snyk Authentication** | name `snyk` |
| 4 | (Optional) Variable group with `SNYK_TOKEN` | Pipelines → Library | name `snyk-cli-token` |
| 5 | Repo read access for the build identity | Project settings → Repositories → Security | *Project Collection Build Service* → Read = Allow |
| 6 | Linux agent pool + tools | Organization settings → Agent pools | pool `linux-snyk`, plus `git curl jq python3-venv` … |
| 7 | Edit defaults in `azure-pipelines.yml` | this repo | JFrog repo names, pool, Snyk org |
| 8 | Create the pipeline, pre-authorize resources | Pipelines → New pipeline → GitHub → this repo | note the **pipeline ID** |
| 9 | PAT for the background job | User settings → Personal access tokens | scope **Build: Read & execute** |
| 10 | Smoke test | `examples/trigger-scan.sh` | 1 repo, `scanTypes: [sca, code]` |

```bash
# The fastest first test once 1-9 are done:
echo '[{"repoId":"<repo-guid>","branch":"main","scanTypes":["sca","code"]}]' > targets.json
PREVIEW=true ADO_ORG=myorg ADO_PROJECT=DevSecOps PIPELINE_ID=123 ADO_PAT=*** ./examples/trigger-scan.sh targets.json  # dry run
ADO_ORG=myorg ADO_PROJECT=DevSecOps PIPELINE_ID=123 ADO_PAT=*** ./examples/trigger-scan.sh targets.json               # real run
```

---

## 1. Azure DevOps extensions

| Extension (Marketplace) | Provides | Used in |
|---|---|---|
| **Snyk Security Scan** | `SnykSecurityScan@1` task, *Snyk Authentication* connection type | `templates/steps/snyk/sca.yml`, `code.yml`, `container.yml` |
| **JFrog** (JFrog Azure DevOps Extension) | `JfrogCliV2@1`, `JFrogToolsInstaller@1`, *JFrog Platform V2* / *Artifactory V2* connection types | `templates/steps/restore/*`, `snyk/setup-cli.yml`, `snyk/container.yml` |

## 2. Service connections

Create them in the **same project as the pipeline**.

| Pipeline parameter | Connection type | Fields | Default name in YAML |
|---|---|---|---|
| `jfrogServiceConnection` | **JFrog Platform V2** | Server URL `https://myco.jfrog.io/`, access token (read on the virtual repos) | `jfrog-platform` |
| `snykServiceConnection` | **Snyk Authentication** | Snyk API token (service account). For a non-US Snyk tenant, also set the API endpoint, e.g. `https://api.eu.snyk.io` | `snyk` |
| `jfrogArtifactoryConnection` *(optional)* | **JFrog Artifactory V2** | Same JFrog URL and token. Only needed if agents **can't** reach `releases.jfrog.io` to download the JFrog CLI and Maven/Gradle extractors | `''` (off) |

> If you use different names, either change the defaults in `azure-pipelines.yml` or pass them as parameters in the REST call.

## 3. Variable group (optional for the first test)

You need it for **IaC scans** in either mode, and for everything when `snykAuthMode: token`.

| Group name (`snykTokenVariableGroup`) | Variable | Secret? | Notes |
|---|---|---|---|
| `snyk-cli-token` | `SNYK_TOKEN` | ✅ | Snyk API token (Key Vault-linked group recommended) |
| | `SNYK_API` | no | Only for a non-US Snyk tenant, e.g. `https://api.eu.snyk.io` |

**First test without the group:** set `defaultScanTypes: [sca, code]`, or send `"scanTypes":["sca","code"]` per target. Otherwise IaC is skipped with a warning, which is harmless.

## 4. Permissions (cloning repos by ID)

| Setting | Where | Value |
|---|---|---|
| Build identity can read target repos | Project settings → Repositories → *Security* (or org level for all projects) | **Project Collection Build Service (`<org>`)** → *Read* = **Allow** |
| Limit job authorization scope to current project for non-release pipelines | Project settings → Pipelines → Settings | **Off** (needed for repos in other projects) |
| Protect access to repositories in YAML pipelines | Project settings → Pipelines → Settings | **Off** |

**Can't turn those two settings off?** Store a PAT (*Code: Read*) or service-principal token as a secret variable, e.g. `GIT_READ_TOKEN`, and set the pipeline parameter `gitTokenVariable: GIT_READ_TOKEN`.

## 5. Linux agents

### Count

- At least **`maxTargets` agents (default 5)** in the pool **and** the same number of **self-hosted parallel jobs**. With fewer, stages queue one after another instead of running in parallel.

### Required packages (every agent)

```bash
sudo apt-get update
sudo apt-get install -y git curl jq ca-certificates python3 python3-venv
```

### Toolchains (only for the stacks you want *restored*; missing ones produce a warning, not an error)

| Stack | Needs on PATH | Ubuntu example |
|---|---|---|
| .NET | `dotnet` (SDK, newest you support) | `sudo apt-get install -y dotnet-sdk-8.0` (add `dotnet-sdk-10.0` too if available) |
| npm | `node`, `npm` | NodeSource / `nvm` → Node 20+ |
| Maven | `java`, `mvn` (**3.9+** recommended) | `sudo apt-get install -y openjdk-17-jdk maven` |
| Gradle | `java` + `gradlew` in repo **or** `gradle` | `sudo apt-get install -y openjdk-17-jdk` |
| Python | `python3`, `python3-venv` | (above) |
| Go | `go` | `sudo snap install go --classic` or tarball |
| Container scans | `docker`, agent user in `docker` group | `sudo usermod -aG docker <agent-user>` then restart the agent |

**Snyk CLI:** you don't need to install it. The Snyk task downloads its own copy, and token mode installs it into `Agent.ToolsDirectory`. You *can* preinstall `snyk` as a fallback.

### Outbound network (allow from agents)

| Host | Why |
|---|---|
| `dev.azure.com`, `*.visualstudio.com` | Repo lookup + git clone |
| `myco.jfrog.io` (your JFrog) | All package restores, `jf docker pull` |
| `api.snyk.io` (or regional, e.g. `api.eu.snyk.io`) | Snyk results upload |
| `static.snyk.io` / `downloads.snyk.io` | Snyk CLI download (task + token mode). If blocked, use `snykOptions.cliJfrogPath` |
| `releases.jfrog.io` | JFrog CLI auto-download. If blocked, set `jfrogArtifactoryConnection` |

### Disk

- Results live in `$(Agent.WorkFolder)/_snyk-results/` and are pruned after `resultsRetentionDays` (14).
- Package caches grow over time: `~/.nuget/packages`, `~/.m2`, `~/.npm`, `~/go/pkg/mod`. Budget roughly 20–50 GB per agent.

## 6. Values to edit in `azure-pipelines.yml`

| Parameter | Default | Set to |
|---|---|---|
| `poolName` | `linux-snyk` | Your Linux pool name |
| `jfrogServiceConnection` | `jfrog-platform` | Name from step 2 |
| `snykServiceConnection` | `snyk` | Name from step 2 |
| `snykTokenVariableGroup` | `''` | `snyk-cli-token` if you created it |
| `snykAuthMode` | `serviceConnection` | Keep for the first test |
| `jfrogRepos.nuget` | `nuget-virtual` | Your NuGet **virtual** repo key |
| `jfrogRepos.npm` | `npm-virtual` | npm virtual repo |
| `jfrogRepos.maven` | `maven-virtual` | Maven virtual repo |
| `jfrogRepos.gradle` | `gradle-virtual` | Gradle/Maven virtual repo |
| `jfrogRepos.pypi` | `pypi-virtual` | PyPI virtual repo |
| `jfrogRepos.go` | `go-virtual` | Go virtual repo |
| `jfrogRepos.cli` / `.extractors` | `jfrog-cli-remote` / `extractors` | Only if `jfrogArtifactoryConnection` is set |
| `snykOptions.org` | `''` | Snyk org ID (empty = the token's default org) |
| `defaultScanTypes` | `[sca, code, iac]` | `[sca, code]` until the token group exists |
| `maxTargets` | `5` | Repos per run |
| `resultsRoot` | `$(Agent.WorkFolder)/_snyk-results` | Keep, or point at a bigger disk |

> **Don't set any `SCAN_*` variables yourself.** The scripts generate them at run time.

## 7. Create the pipeline

1. **Pipelines → New pipeline → GitHub** → `t-dhruv/azure-devops-snyk-orchestrator` → *Existing Azure Pipelines YAML file* → `/azure-pipelines.yml` → **Save** (don't run yet). This needs a GitHub service connection / GitHub App authorization.
2. Note the **pipeline ID**, the `definitionId=` value in the URL.
3. **Pre-authorize resources.** REST-triggered runs can't click *Permit*:
   - Agent pool → *Security* / *Pipeline permissions* → add this pipeline
   - Each service connection → *Security* → *Pipeline permissions* → add this pipeline
   - Variable group (if used) → *Pipeline permissions* → add this pipeline
4. **Run once manually** (*Run pipeline*) with `scanTargets` set to:

   ```yaml
   - repoId: <guid>
     branch: main
     scanTypes: [sca, code]
   ```

   This also clears any pending permission prompts.

**Find a repo GUID:**

```bash
curl -s -u :$ADO_PAT "https://dev.azure.com/myorg/Claims/_apis/git/repositories/claims-api?api-version=7.1" | jq -r .id
```

## 8. Background job / trigger credentials

| Value | Example | Notes |
|---|---|---|
| `ADO_ORG` | `myorg` | |
| `ADO_PROJECT` | `DevSecOps` | Project that **hosts the pipeline** (not the scanned repos) |
| `PIPELINE_ID` | `123` | From step 7 |
| `ADO_PAT` | `***` | Scope **Build: Read & execute**. Or use an Entra service principal with *Queue builds* on the pipeline |
| `MAX_TARGETS` | `5` | Must be ≤ the pipeline's `maxTargets` |

## 9. Smoke test plan

1. **Dry run.** `PREVIEW=true ./examples/trigger-scan.sh targets.json` should return the expanded YAML with no errors. This proves that passing `scanTargets` as a JSON string works in your org.
2. **One repo, `[sca, code]`.** Check that:
   - the stage `Scan_<repo>` is green or orange (*SucceededWithIssues* is fine), and
   - on the agent: `ls $AGENT_WORK/_snyk-results/<buildId>/<key>/` shows `summary.json`, `detection.json`, `target.json`, `repo.json`.
3. **Check the restore folder.** In the *Restore • …* step log, the `jf … restore` should run inside the target repo, not the pipeline repo. If it doesn't, the JFrog task ignores `workingDirectory` on your extension version; open an issue and I'll switch it to path-based arguments.
4. **Check the Snyk task directory.** The Snyk SCA step should scan `.../src`. If it scans `.../pipeline` instead, change `testDirectory` in `templates/steps/snyk/sca.yml` / `code.yml` to `../src`.
5. **Scale up.** Send 5 repos with different stacks and confirm all 5 stages run at the same time.
6. **Add IaC.** Create the token group, set `snykTokenVariableGroup`, and add `iac`.

## 10. Common first-run errors

| Symptom | Fix |
|---|---|
| `HTTP 401/403 reading repo …` | Step 4: permissions or the two pipeline settings, or use `gitTokenVariable` |
| `Repository … not found` | Wrong GUID, or the build identity can't see that project |
| `Could not fetch branch 'x'` | Branch doesn't exist / typo (`refs/heads/` prefix is optional) |
| Run waits on *"needs permission to access a resource"* | Step 7.3 pre-authorization |
| `scanTargets must contain 1-5 items` | Empty list or more than `maxTargets` |
| `IaC scan skipped` warning | Expected without `snykTokenVariableGroup` |
| `SNYK_TOKEN is not available` | Token mode/IaC: group missing `SNYK_TOKEN`, or the group isn't authorized |
| Snyk task fails downloading the CLI | Agents can't reach `static.snyk.io`. Switch to `snykAuthMode: token` + `snykOptions.cliJfrogPath` |
| `jf: command not found` / JFrog CLI download error | Agents can't reach `releases.jfrog.io`. Set `jfrogArtifactoryConnection` |
| `.NET projects found but 'dotnet' SDK is not on the agent` | Install the SDK. The scan still ran, just without restore |
| `Could not create a Python venv` | `sudo apt-get install -y python3-venv` |
| Container step skipped | `docker` missing, or the agent user isn't in the `docker` group |
