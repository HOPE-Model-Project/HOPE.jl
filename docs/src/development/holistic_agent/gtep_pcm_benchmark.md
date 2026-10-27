# Internal GTEP-to-PCM benchmark evidence

!!! warning "Development validation asset"
    This benchmark supports HOPE holistic-linkage and agent-system development.
    It is not an end-user model case or a claim that the synthetic Maryland
    network is suitable for production planning decisions.

The GTEP-to-PCM benchmark is a deterministic evidence test, not another model
formulation. It answers four separate questions from one published run:

1. What capacity did GTEP select?
2. Where did each selected candidate become a physical PCM asset?
3. Did MW, MWh, identity, and operating parameters survive the handoff?
4. Did PCM actually use the transferred assets without load shedding or policy
   slack during the evaluation period?

HOPE generates the evidence directly from the run manifest, handoff contract,
transfer-reconciliation tables, realized PCM inputs, and hourly PCM outputs.
This avoids relying on values copied manually into a report.

## Canonical Maryland result

The reference result uses the
`MD_GTEP_RPS20_4zone_full8760_public_case` planning case and the
`MD_PCM_RPS20_transmission_full8760_public_case` operating case. GTEP solves
all 8,760 chronological hours. PCM solves 48 preceding June warm-up hours and
all 744 July evaluation hours on 656 buses and 838 branches.

The validated run used Gurobi and passed all 51 checks: 28 internal workflow
and conservation checks plus 23 pinned reference-value regression checks.

| Quantity | Solved or delivered value |
| --- | ---: |
| GTEP annual planning objective | 4,112,707,606.34 USD |
| New generation transferred | 26,394.534 MW |
| New storage power transferred | 6,011.078 MW |
| New storage energy transferred | 24,044.311 MWh |
| PCM complete-horizon objective | 158,130,773.90 USD |
| July variable generation cost | 151,027,749.62 USD |
| July dispatch from transferred generation | 5,939,408.18 MWh |
| July storage charge | 504,986.93 MWh |
| July storage discharge | 430,991.92 MWh |
| July emissions | 1,515,662.53 tons |
| July load shedding | 0.0 MWh |
| PCM RPS slack | 0.0 MWh |

No generator retirement or transmission expansion was selected in this solve.
Those mappings are configured, but this result does not claim that the two
paths were exercised.

## What “physical realization” means here

GTEP chooses capacity at the planning-zone level. The versioned physical
realization contract maps each candidate to a predefined PCM bus and creates a
stable realized asset ID. For this benchmark, each zone's generation and
storage candidates map to the following host bus:

| Planning zone | PCM transmission bus | Candidate siting basis |
| --- | --- | --- |
| APS_MD | `OSM_S73877825_500` | assumed largest existing generation bus in zone |
| BGE | `OSM_S1262049321_115` | assumed largest existing generation bus in zone |
| DPL_MD | `OSM_S849494456_500` | assumed largest existing generation bus in zone |
| PEPCO | `OSM_S66794233_500` | assumed largest existing generation bus in zone |

The network is a geographically grounded synthetic reconstruction. OpenStreetMap
provides transmission topology and geography; line ratings, reactance,
transformer details, external interfaces, and candidate siting are documented
model assumptions. The benchmark therefore proves deterministic realization
and data conservation, not that the assumed sites are actual interconnection
locations or that this is an official PJM network.

This case does not solve a general zonal-to-nodal downscaling problem. It avoids
that ambiguity by pre-siting every GTEP candidate: the candidate input already
contains a `Bus_id` consistent with its `Planning_Zone`. GTEP decides the built
MW at that fixed candidate location, and the linkage carries the same bus into
PCM. A study that supplies only zonal candidates would need an additional,
explicit siting allocation method before it could create a defensible nodal PCM
case.

### Planned downscaling work

The current `explicit_bus` approach is an interim benchmark assumption, not the
intended general solution for translating zonal planning decisions into nodal
assets. A collaborating researcher is developing more formal downscaling and
siting methods. HOPE should therefore preserve a clean interface for that work
without embedding a competing allocation rule in this benchmark.

A future downscaling component should consume zonal build decisions together
with candidate-resource and physical-network information, then produce an
auditable candidate-to-bus allocation. At minimum, its output should retain the
planning zone, selected MW/MWh, assigned bus, method and method version,
assumptions or weights, and any confidence or feasibility flags. The existing
`explicit_bus` method should remain available as a deterministic option for
studies whose candidate locations are known in advance.

The proposed computed-siting inputs, multiple-realization representation,
feedback routing, agent authority, and human-approval rules are specified in
[Adaptive GTEP, Realization, and PCM Agents](@ref adaptive-gtep-pcm-agents).

For every built candidate, `physical_realization.csv` records the complete
trace:

```text
Candidate_ID -> RealizedAssetID -> planning zone -> technology
             -> PCM Bus_id -> MW/MWh -> Operational_Template_ID
```

## Operational-parameter realization

Existing generators are matched through `Asset_ID`; the PCM case remains the
owner of its detailed operating data. New GTEP candidates use the following
precedence when they become PCM resources:

1. an explicit value on the GTEP candidate row;
2. a value from the candidate's PCM-owned `Operational_Template_ID`; and
3. the legacy PCM technology/zone fleet-average or model default.

For any new thermal resource, HOPE enforces `Flag_UC = 1`. In this Maryland
case, each NGCC candidate references `HOPE_NGCC_DEFAULT`. Candidate values such
as `FOR = 0.05` and `RU = RD = 1.0` retain precedence. The template supplies the
otherwise missing `Flag_UC = 1`, two-hour minimum up/down times, and
15 USD/MW startup cost. `operational_parameters_audit.csv` records the source
used for each realized parameter.

The template registry is the preferred practical default mechanism: users do
not need to put PCM-only UC assumptions into the GTEP formulation, but the PCM
case must declare which technology template applies. A universal hidden UC
default would make studies harder to interpret. Legacy cases without a template
remain supported, but their fleet-average/zero fallback should be treated as a
compatibility path rather than a calibrated operational assumption.

## What must match

The benchmark treats the following as strict handoff invariants:

- source-case fingerprints and immutability;
- stable candidate and realized-asset identities;
- candidate-to-bus resolution;
- selected and realized generation MW;
- selected and realized storage MW and MWh;
- selected line additions and retirements;
- realized generator operating bounds; and
- the published handoff, transfer, and coverage status.

It reports GTEP and PCM costs, dispatch, and emissions but does **not** compare
them for equality. The stages solve different mathematical problems and time
horizons: annual zonal planning versus a warm-started monthly nodal unit-
commitment simulation with more detailed reserves. Equality would be an
incorrect consistency criterion.

## Generate the evidence bundle

After an MCP-managed run reaches `PUBLISHED`, run:

```powershell
julia --project=. tools/repo_utils/report_holistic_benchmark.jl `
  <run-workspace> `
  <report-output-directory> `
  <validation-slice.yml> `
  test/benchmarks/md_rps20_annual_gtep_july_pcm.yml
```

The third argument is optional when `validation_slice.yml` is already in the
run workspace. Supplying it is important for a warm-up run because it prevents
warm-up hours from being counted as July evaluation results.

The fourth argument is an optional reference baseline. It adds regression
checks for the source fingerprints, dimensions, investment decisions, and
solved values. Internal conservation checks answer “was this run linked
correctly?”; reference checks separately answer “did this run reproduce the
accepted benchmark within tolerance?” A deliberate model or data change should
update the baseline only after its new result is reviewed.

The output directory contains:

- `benchmark_report.md`: readable solved-value and delivery report;
- `benchmark_summary.yml`: compact machine-readable metrics and provenance;
- `benchmark_checks.csv`: every consistency assertion and its evidence;
- `build_decisions.csv`: GTEP decisions summarized by resource, zone, and type;
- `physical_realization.csv`: candidate-to-asset-to-bus trace;
- `retirements.csv`: selected asset-level retirement realization; and
- `transmission_builds.csv`: selected corridor-to-branch capacity additions.

The command exits with an error when any required check fails, making it usable
as a release gate before an LLM or multi-agent workflow is tested.

## Separate transfer-coverage benchmark

The canonical benchmark remains unchanged and still represents the stable
annual-GTEP-to-July-PCM reference. A separate internal derived benchmark now
exercises the paths that its economic solution did not select. It is generated
by `tools/repo_utils/build_md_transfer_coverage_benchmark.py`; it is not a
published ModelCase or an end-user planning case.

The derived benchmark preserves 8,760 GTEP hours, 48 June warm-up hours, all
744 July PCM evaluation hours, 656 buses, and 838 branches. It adds two
explicitly test-only assumptions:

- retirement-eligible asset `G1149` must produce its 2 MW rating whenever it is
  retained, making its retirement decision observable; and
- mapped corridor `OSM_L62255589` has a derived 500 MW pre-upgrade PCM rating,
  while the 1,000 MW GTEP candidate receives a -0.001 million USD test credit
  so the optimizer deterministically selects the transfer path.

These assumptions test realization mechanics and must not be interpreted as a
Maryland retirement recommendation, an authoritative branch rating, or a
planning-cost assumption. The successful Gurobi run selected and delivered a
2 MW retirement and 1,000 MW in each direction on the corridor. PCM carried a
maximum 936.409 MW on the upgraded corridor, including 436.409 MW above the
derived pre-upgrade rating, with zero load shedding and zero RPS slack. The
evidence bundle passed 53 of 53 workflow, conservation, operational, and pinned
numerical checks.

Reproduce the isolated workspace and report with:

```powershell
python tools/repo_utils/build_md_transfer_coverage_benchmark.py
julia --project=. artifacts/benchmarks/md-rps20-transfer-coverage/run_workspace/run_pair.jl
julia --project=. tools/repo_utils/report_holistic_benchmark.jl `
  artifacts/benchmarks/md-rps20-transfer-coverage/run_workspace `
  artifacts/benchmarks/md-rps20-transfer-coverage/evidence `
  artifacts/benchmarks/md-rps20-transfer-coverage/run_workspace/validation_slice.yml `
  test/benchmarks/md_rps20_transfer_coverage.yml
```
