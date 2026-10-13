
```@meta
CurrentModule = HOPE
```

# Solver Settings

HOPE can use several solvers to solve its LP and MILP optimisation problems.

## Built-in open-source solvers

The following solvers are installed automatically with HOPE and need no extra setup:

| Solver | Key in settings file | Notes |
| :-- | :-- | :-- |
| **HiGHS** | `highs` | Recommended default — fast LP/MILP, no license required |
| **GLPK** | `glpk` | Reliable LP/MILP baseline |
| **Clp** | `clp` | LP only |
| **Cbc** | `cbc` | LP/MILP |

Set the active solver in `Settings/HOPE_model_settings.yml`:

```yaml
solver: highs
```

## Commercial solvers (optional)

**Gurobi**, **SCIP**, and **CPLEX** are supported but are *not* installed by default.
Because they require a separate license they must be added to your Julia environment
manually — HOPE loads them on demand when a case requests them. These optional
integrations use Julia package extensions, so they require Julia 1.9 or later.

### Setup steps

**Step 1 — Obtain a license.**

- [Gurobi](https://www.gurobi.com/solutions/licensing/) — free academic license available
- [SCIP](https://scipopt.org/) — free for academic use
- [CPLEX](https://www.ibm.com/products/ilog-cplex-optimization-studio) — free academic license via IBM Academic Initiative

**Step 2 — Install the solver and its Julia package.**

For Gurobi, download and install the Gurobi solver from
[gurobi.com](https://www.gurobi.com/downloads/) and activate a valid license.
Then add both HOPE and the optional wrapper to the environment used by your
study:

```julia
import Pkg
Pkg.activate("my-study")
Pkg.add(["HOPE", "Gurobi"])   # substitute "SCIP" or "CPLEX" as needed
```

When developing from a cloned HOPE repository, keep its `Project.toml`
unchanged by installing the optional wrapper in Julia's version environment:

```julia
import Pkg
Pkg.activate()       # activates @v#.#
Pkg.add("Gurobi")
```

Julia's standard stacked `LOAD_PATH` then makes the wrapper available when the
repository is run with `julia --project=.`. The native solver installation and
the Julia wrapper are separate requirements.

**Step 3 — Set the solver** in the case settings file.

```yaml
# Settings/HOPE_model_settings.yml
solver: gurobi    # or: scip / cplex
```

HOPE will issue a clear error if the package is missing or the license is invalid.

### Solver settings files

Each solver reads its parameters from a YAML file in the case `Settings/` directory:

| File | Solver |
| :-- | :-- |
| `highs_settings.yml` | HiGHS |
| `glpk_settings.yml` | GLPK |
| `clp_settings.yml` | Clp |
| `cbc_settings.yml` | Cbc |
| `gurobi_settings.yml` | Gurobi |
| `scip_settings.yml` | SCIP |
| `cplex_settings.yml` | CPLEX |

Most users do not need to modify these files. When tuning is required, consult
the documentation for the chosen solver.
