```@meta
CurrentModule = HOPE
```

# Run a Case in HOPE

## Using VS Code to Run a Case (Recommended)

Install Visual Studio Code: download [VS Code](https://code.visualstudio.com/) and [install](https://code.visualstudio.com/docs/setup/setup-overview) it. A short video tutorial on how to install VS Code and add Julia to it can be found [here](https://www.youtube.com/watch?v=oi5dZxPGNlk).

**(1)** Open VS Code, click `File -> Open Folder...`, and navigate to your local `HOPE` repository directory.

**(2)** In the VS Code terminal, type `julia` and press Enter. Julia will open as below:

   ![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/5fc3a8c9-23f8-44a3-92ab-135c4dbdc118)

**(3)** Type `]` to enter Julia package mode, then run `activate .` from the repository root. You should see the prompt change from `(@v1.x) pkg>` to `(HOPE) pkg>`, which means the HOPE project is activated successfully.

   ![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/2a0c259d-060e-4799-a044-8dedb8e5cc4d)

**(4)** Type `instantiate` at the `(HOPE) pkg>` prompt.

This installs the default HOPE environment and the bundled open-source solvers. It does
**not** install commercial solver packages automatically.

**(5)** Type `st` to check that the dependencies have been installed. Type `up` if you want to update package versions. (This step may take some time when you install HOPE for the first time. After HOPE is installed successfully, you can usually skip it.)

![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/1eddf81c-97e4-4334-85ee-44958fcf8c2f)

**(6)** If there is no error in the above processes, the **HOPE** model has been installed successfully. Then press `Backspace` to return to the Julia prompt. To run an example case (for example, the default Maryland PCM case), type `using HOPE`, then run:

```julia
HOPE.run_hope("ModelCases/MD_PCM_Excel_case/")
```

You will see **HOPE** start running:

![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/33fa4fbc-6109-45ce-ac41-f41a29885525)

The results will be saved in `HOPE/ModelCases/MD_PCM_Excel_case/output`.

![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/af68d3a7-4fe7-4d9c-97f5-6d8898e2c522)

Note:

- `HOPE.run_hope(...)` accepts normalized case paths. For example, these are all valid:
  - `HOPE.run_hope("ModelCases/MD_PCM_Excel_case/")`
  - `HOPE.run_hope("MD_PCM_Excel_case/")`
  - `HOPE.run_hope("HOPE/ModelCases/MD_PCM_Excel_case/")`
- Some older screenshots in this page still show the historical `HOPE/ModelCases/...` style. The newer shorter form is recommended.

**(7)** For future runs, you can usually skip steps 4 and 5 and just follow steps 1, 2, 3, and 6.

## Using System Terminal to Run a Case

You can use a system terminal either on Windows or macOS to run a test case. See details below.

### Windows users

**(1)** Open **Command Prompt** from Windows **Start** and navigate to your local `HOPE` repository directory.

**(2)** Type `julia`. Julia will be opened as below:

![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/6c61bed1-bf8e-4186-bea2-22413fd1328e)

**(3)** Type `]` to enter Julia package mode, then run `activate .`. You should see the prompt change from `(@v1.x) pkg>` to `(HOPE) pkg>`, which means the HOPE project is activated successfully.

**(4)** Type `instantiate` in the `(HOPE) pkg>` prompt. (After HOPE is installed successfully, you can skip this step.)

This installs the default HOPE environment and the bundled open-source solvers. It does
**not** install commercial solver packages automatically.

**(5)** Type `st` to check that the dependencies have been installed. Type `up` if you want to update package versions. (This step may take some time when you install HOPE for the first time. After HOPE is installed successfully, you can usually skip it.)

![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/66ce1ea1-1b06-43d0-9f2b-542c473797aa)

**(6)** If there is no error in the above processes, the **HOPE** model has been installed successfully. Then click `Backspace` to return to the Julia prompt. To run an example case (for example, the default Maryland PCM case), type `using HOPE`, then run:

```julia
HOPE.run_hope("ModelCases/MD_PCM_Excel_case/")
```

You will see **HOPE** start running:

![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/c36c6384-7e04-450d-921a-784c3b13f8bd)

The results will be saved in `HOPE/ModelCases/MD_PCM_Excel_case/output`.

![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/7a760912-b8f2-4d5c-aea0-b85b6eb00bf4)

Note:

- `HOPE.run_hope(...)` accepts normalized case paths. For example, these are all valid:
  - `HOPE.run_hope("ModelCases/MD_PCM_Excel_case/")`
  - `HOPE.run_hope("MD_PCM_Excel_case/")`
  - `HOPE.run_hope("HOPE/ModelCases/MD_PCM_Excel_case/")`
- Some older screenshots in this page still show the historical `HOPE/ModelCases/...` style. The newer shorter form is recommended.

**(7)** For future runs, you can usually skip steps 4 and 5 and just follow steps 1, 2, 3, and 6.

## Run a DART Case

DART uses the same top-level API and settings filename as GTEP and PCM:

```julia
using HOPE

case_path = "ModelCases/RTS24_DART_case"
validation = HOPE.validate_hope(case_path)
results = HOPE.run_hope(case_path)
```

`validate_hope` checks the manifest, stable IDs, input hashes, installed
network, native real-time chronology, initial state, settings compatibility,
and enabled constraint families without solving or writing output.

DART writes separate day-ahead and real-time dispatch, flow, storage, and
solver-status CSVs together with `acceptance_summary.csv`,
`constraint_coverage.csv`, and `settlement_summary.csv`.

See [DART](@ref), [DART Input Data](@ref dart-inputs), and
[RTS24 DART Case](@ref).

## Reuse a Saved Baseline for EREC

For `GTEP` studies, you can ask HOPE to save a machine-readable baseline snapshot together with the normal run outputs. Add this line in `Settings/HOPE_model_settings.yml`:

```yaml
save_postprocess_snapshot: 1       #Int, 0 do not save; 1 save minimal snapshot for later postprocessing such as EREC; 2 save full snapshot with additional solved-run details
```

Then run the case normally:

```julia
using HOPE
res = HOPE.run_hope("ModelCases/my_case/")
```

HOPE will save the snapshot under:

```text
ModelCases/my_case/output/postprocess_snapshot/
```

Later, you can calculate `EREC` from the saved output without re-solving the baseline expansion model:

```julia
using HOPE
erec = HOPE.calculate_erec_from_output("ModelCases/my_case/output")
```

If you already have the solved results in memory from the current Julia session, you can also reuse them directly:

```julia
using HOPE
res = HOPE.run_hope("ModelCases/my_case/")
erec = HOPE.calculate_erec(res)
```

See [EREC Postprocessing](EREC.md) for the recommended `HOPE_erec_settings.yml` workflow.

## Holistic GTEP -> PCM Runs

HOPE supports a two-stage `GTEP -> PCM` workflow through two related entry points:

- `HOPE.run_hope_holistic(gtep_case, pcm_case)` runs the paired cases while treating both source input folders as read-only.
- `HOPE.run_hope_holistic_fresh(gtep_case, pcm_case)` first creates fresh case clones, skips old `output/` trees, and then runs the same two-stage workflow on those clones.

For most repeatable workflows, `HOPE.run_hope_holistic_fresh(...)` remains useful because it gives each run an isolated workspace and avoids stale output trees. The direct workflow also preserves the original input CSV files; it writes only normal model outputs and handoff artifacts.

Example:

```julia
using HOPE

result = HOPE.run_hope_holistic_fresh(
  "ModelCases/MD_GTEP_holistic_full8760_case_v20260406g",
  "ModelCases/MD_PCM_holistic_full8760_case_v20260406g",
)
```

For a validation run, select a faster installed solver without editing either
source case:

```julia
result = HOPE.run_hope_holistic(
    "ModelCases/MD_GTEP_RPS20_4zone_public_case",
    "ModelCases/MD_PCM_RPS20_transmission_public_case";
    solver_override = "gurobi",
)
```

`gtep_solver_override` and `pcm_solver_override` may be supplied separately when
the stages need different solvers. The override exists only in the returned run
configuration; `Settings/HOPE_model_settings.yml` is not modified. The same
non-mutating `solver_override` keyword is available on standalone `run_hope`.

Key requirements:

- The `GTEP` and `PCM` cases must use the same resolved spatial topology. The default `holistic_spatial_basis: zone` requires matching `zonedata.Zone_id` and zonal `linedata` corridors. A GTEP case may select `bus`, where each physical bus is represented as a GTEP zone and PCM is validated through `busdata`, `branchdata`, `Bus_id`, and `load_timeseries_nodal`. Set PCM to `holistic_spatial_basis: auto` when one nodal PCM case should inherit either resolution from different paired GTEP cases.
- `GTEP` is the expansion stage and `PCM` is the dispatch stage. HOPE first solves `GTEP`, then realizes new builds, retirements, storage additions, and transmission expansion in a copy of the paired `PCM` inputs before running chronological dispatch.

If the pair is not topology-matched, HOPE stops before the `GTEP` solve and reports the mismatch directly. This is preferable to an implicit zone remap because the holistic workflow is intended to dispatch the same system that the expansion model planned.

No new columns or settings are required for an existing compatible case. HOPE
validates the historical row-based mapping before using it and can fall back to
an unambiguous aggregate resource mapping. For stronger identity guarantees,
cases may optionally provide:

- `Asset_ID` on existing GTEP and PCM generator rows;
- `Candidate_ID` on candidate generator and storage rows; and
- `Corridor_ID` on candidate and realized transmission rows.

When IDs are supplied, they must be nonblank and unique in their table. New
generator and storage builds first inherit operating parameters from their
candidate rows. A PCM case may also provide
`operational_resource_templates.csv`; `Operational_Template_ID` fills missing
new-resource values before the existing PCM fleet-average/default fallback.
New thermal builds are always unit committed, while existing PCM resources are
left unchanged. Parallel zonal corridors share an expansion in proportion to
their existing directional ratings; ambiguous multi-branch nodal mappings stop
with an error unless `Corridor_ID` resolves the target.

After a successful PCM solve, HOPE writes the realized handoff under
`output_holistic/realized_inputs/` (or the actual timestamped backup output
selected by the standard output writer). It contains `gendata.csv`,
`storagedata.csv`, `linedata.csv`, optional nodal `branchdata.csv`, mapping audit
CSVs including `operational_parameters_audit.csv`, and `handoff_manifest.yml`
with source hashes and transfer totals.

A case may opt into strict physical-realization validation by adding
`Settings/HOPE_physical_realization.yml`. The holistic runner discovers this
versioned contract automatically, validates candidate buses, planning zones,
branch targets, identities, topology counts, and provenance before solving, and
then verifies SHA-256 fingerprints for every source data file after the run.
The resulting `handoff_contract.yml` and `handoff_contract_checks.csv` are
written beside the realized inputs. See [Holistic Handoff and Physical-Realization Contracts](@ref).

If you want to validate a pair before solving, you can also use the generic audit helper:

```powershell
julia --project=. tools/repo_utils/audit_holistic_case_pair.jl <GTEP_case> <PCM_case>
```
