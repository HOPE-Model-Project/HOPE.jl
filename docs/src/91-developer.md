# [Developer documentation](@id dev_docs)

!!! note "Contributing guidelines"
    If you haven't, please read the [Contributing guidelines](90-contributing.md) first.

If you want to make contributions to this package that involves code, then this guide is for you.

## Current branch plan

The repository branch transition is complete:

1. `main` is the active development branch. All contributions go here.
2. The legacy `master` (pre-v2, Maryland-focused) is archived as a separate repository: [HOPE-MD](https://github.com/HOPE-Model-Project/HOPE-MD).

Contributors should branch from and open pull requests into `main`.

## First time clone

!!! tip "If you have write access"
    If you have write access to the main repository, you can clone it directly and skip the fork workflow.

If this is the first time you work with this repository, the safest setup is:

1. Fork the repository if you do not have write access.
2. Clone your fork, which creates a git remote called `origin`.
3. Add the main repository as `upstream`:

   ```bash
   git remote add upstream https://github.com/HOPE-Model-Project/HOPE.jl.git
   ```

4. Fetch the latest branches:

   ```bash
   git fetch upstream
   ```

5. Create your working branch from `upstream/main`:

   ```bash
   git switch -c my-change upstream/main
   ```

## Linting and formatting

Install a plugin on your editor to use [EditorConfig](https://editorconfig.org).
This will ensure that your editor is configured with important formatting settings.

We use [https://pre-commit.com](https://pre-commit.com) to run the linters and formatters.
In particular, the Julia code is formatted using [JuliaFormatter.jl](https://github.com/domluna/JuliaFormatter.jl), so please install it globally first:

```julia-repl
julia> # Press ]
pkg> activate
pkg> add JuliaFormatter
```

To install `pre-commit`, we recommend using [pipx](https://pipx.pypa.io) as follows:

```bash
# Install pipx following the link
pipx install pre-commit
```

With `pre-commit` installed, activate it as a pre-commit hook:

```bash
pre-commit install
```

To run the linting and formatting manually, enter the command below:

```bash
pre-commit run -a
```

**Now, you can only commit if all the pre-commit tests pass**.

## Testing

For standard validation, open Julia in the repository folder, activate the environment, and run `test`:

```julia-repl
julia> # press ]
pkg> activate .
pkg> test
```

For documentation changes, also validate the docs environment when practical:

```bash
julia --project=docs docs/make.jl
```

If your change touches workflow files, verify the target branch names and trigger conditions at the same time.

### Holistic GTEP-to-PCM regression suite

The standard package tests exercise the linkage logic with small fixtures. The
holistic regression suite additionally solves paired Maryland ModelCases and
checks the persisted handoff contract, transfer reconciliation, acceptance
thresholds, activity metrics, and source-case immutability.

Clone `HOPEModelCases` beside or inside the HOPE checkout, then run the fast,
constraint-rich benchmark with the portable HiGHS solver:

```bash
julia --project=. scripts/run_holistic_regressions.jl \
  --suite restricted \
  --modelcases ModelCases \
  --solver highs
```

For a release candidate, run both the restricted benchmark and the larger
Maryland 20% RPS benchmark. A licensed local solver can be selected without
editing either case:

```bash
julia --project=. scripts/run_holistic_regressions.jl \
  --suite all \
  --modelcases ModelCases \
  --solver gurobi
```

The runner always clones inputs into temporary directories. Compact coverage,
handoff, reconciliation, and realized-input audit artifacts are written under
`artifacts/holistic/`; the source ModelCases are never used as output targets.
The GitHub workflow runs the restricted benchmark for relevant pull requests
and pushes. The public 20% RPS benchmark runs weekly or through manual workflow
dispatch so routine contributions do not pay its full runtime cost.

### Agent-safe holistic integration tests

The MCP package has two opt-in real-solver tests. The restricted test is the
fast lifecycle smoke test. The high-resolution test retains the annual Maryland
GTEP stage and uses a bounded-memory July slice for the 656-bus PCM stage:

```powershell
.\scripts\run_md_july_agent_integration.ps1
```

The public `hope_prepare_holistic_validation_study` tool exposes this preparation
through the registered `md-rps20-annual-gtep-monthly-pcm` profile. It invokes only
the registered ModelCases builder, writes derived cases below the durable study
directory, checks the temporal metadata and source fingerprints, and never uses
the published ModelCases as output targets. By default it prepends 48
chronological hours from the prior month as a PCM warm-up period, so commitment
and storage state at the evaluation-month boundary are endogenous rather than
free. The study manifest records the profile, builder hash, source hashes,
warm-up hours, evaluation hours, and derived-case paths. The test requires
successful scientific acceptance, persistent status recovery after the
in-memory job mapping is removed, and idempotent reuse of the original study ID.
Keep this test opt-in because its annual GTEP and monthly nodal PCM solves are too
expensive for every pull request.

The normal MCP unit suite includes a synchronized fake-process state-machine
test. It covers process identity, orphan recovery, stable reconnect semantics,
invalid YAML and manifest handling, checkout compatibility, and equivalent case
identifier normalization without launching Julia.

The first role-separated multi-agent test uses the restricted Maryland pair and
the public prepare, launch, status, and audit tools:

```powershell
.\scripts\run_holistic_multi_agent_integration.ps1 -Solver gurobi
```

This is intentionally a protocol test around the existing deterministic
GTEP-to-PCM transaction. It checks coordinator, executor, and auditor receipts,
source-drift rejection, durable reconnect, artifact scoping, and independent
acceptance. It does not yet split the three numerical stages into independently
restartable services or evaluate an LLM's scientific reasoning.

## Working on a new issue

We try to keep a linear history in this repo, so it is important to keep your branches up-to-date.

1. Fetch from the remote and fast-forward your local `main`

   ```bash
   git fetch upstream
   git switch main
   git merge --ff-only upstream/main
   ```

2. Branch from `main` to address the issue (see below for naming)

   ```bash
   git switch -c 42-add-answer-universe
   ```

3. Push the new local branch to your personal remote repository

   ```bash
   git push -u origin 42-add-answer-universe
   ```

4. Create a pull request targeting `main`.

### Branch naming

- If there is an associated issue, add the issue number.
- If there is no associated issue, **and the changes are small**, add a prefix such as "typo", "hotfix", "small-refactor", according to the type of update.
- If the changes are not small and there is no associated issue, then create the issue first, so we can properly discuss the changes.
- Use dash separated imperative wording related to the issue (e.g., `14-add-tests`, `15-fix-model`, `16-remove-obsolete-files`).

### Commit message

- Use imperative or present tense, for instance: *Add feature* or *Fix bug*.
- Have informative titles.
- When necessary, add a body with details.
- If there are breaking changes, add the information to the commit message.

### Before creating a pull request

!!! tip "Atomic git commits"
    Try to create "atomic git commits" (recommended reading: The Utopic Git History by Carlos Martinez Ortiz, Netherlands eScience Center).

- Make sure the tests pass.
- Make sure the pre-commit tests pass.
- Fetch any `main` updates from upstream and rebase your branch, if necessary:

  ```bash
  git fetch upstream
  git rebase upstream/main BRANCH_NAME
  ```

- Then you can open a pull request and work with the reviewer to address any issues.

## Building and viewing the documentation locally

Following the latest suggestions, we recommend using `LiveServer` to build the documentation.
Here is how you do it:

1. Run `julia --project=docs` to open Julia in the environment of the docs.
1. If this is the first time building the docs
   1. Press `]` to enter `pkg` mode
   1. Run `pkg> dev .` to use the development version of your package
   1. Press backspace to leave `pkg` mode
1. Run `julia> using LiveServer`
1. Run `julia> servedocs()`

## Making a new release

- Create a branch `release-x.y.z` from `main`
- Update `version` in `Project.toml`
- Update release notes or changelog material if you are maintaining one for the release.
- Create a release PR targeting `main`.
- Verify test, lint, and docs workflows on that PR.
- Merge only after the release branch strategy, docs deployment branch, and badges all agree.

### Initial registration in General

HOPE's existing GitHub tags predate registration in Julia's General registry.
The first registry submission is therefore a new-package registration, not a
new-version registration.

After the final release commit is reviewed and merged to `main`:

1. Confirm that the JuliaRegistrator GitHub App is installed for this
   repository. Only a repository collaborator or a public member of the owning
   organization can trigger it.
2. Open the final commit on GitHub and add this comment:

   ```text
   @JuliaRegistrator register

   Release notes:

   HOPE 2.0 adds the DART SCUC/SCED and settlement APIs, EREC postprocessing,
   representative-day and resource-aggregation workflows, and the holistic
   GTEP-to-PCM handoff. This is a breaking release: transmission cases must
   replace `Capacity (MW)` with `Forward Capacity (MW)` and
   `Reverse Capacity (MW)`; see CHANGELOG.md.
   ```

3. On the General registration pull request, explain that HOPE is the
   established, published name for the Holistic Optimization Program for
   Electricity. Its four-letter uppercase acronym and repository URL without a
   `.jl` suffix do not satisfy the conservative automatic-name checks, so the
   initial registration needs manual review. Do not change the package UUID.
4. Wait for the required new-package review period and address RegistryCI or
   maintainer feedback. Registration is permanent; do not merge around a
   substantive unresolved concern.
5. After the General pull request merges, let TagBot create `v2.0.0` and the
   GitHub release. Confirm that the `DOCUMENTER_KEY` secret contains the
   private half of a write-enabled deploy key so the tag-triggered docs workflow
   can run. Do not create the release tag before registration.

If the GitHub App cannot be installed, use Registrator's JuliaHub web interface
with the same final commit and release notes.
