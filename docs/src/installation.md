```@meta
CurrentModule = HOPE
```

# Installation

## 1. Install Julia

Install [Julia](http://julialang.org/) language. Julia 1.9 or later is required for the current HOPE package setup. A short video tutorial on how to download and install Julia is provided [here](https://www.youtube.com/watch?v=t67TGcf4SmM).

## 2. Install the registered HOPE release (recommended for most users)

At the Julia prompt, install HOPE from Julia's General registry:

```julia
import Pkg
Pkg.add("HOPE")
using HOPE
```

This installs the latest compatible registered release. To update to a newer
registered release later, run:

```julia
import Pkg
Pkg.update("HOPE")
```

Package installation does not download model cases, start dashboards or MCP
services, install Python, or require a commercial solver license.

## 3. Get model cases

Model cases are maintained in the separate [HOPEModelCases](https://github.com/HOPE-Model-Project/HOPEModelCases) repository. Clone them to a user-selected location:

```bash
git clone https://github.com/HOPE-Model-Project/HOPEModelCases /path/to/HOPEModelCases
```

Model-case downloads are explicit and separate from package installation. Set `HOPE_MODELCASES_PATH` to that location before running a file-based case:

- **Linux / macOS:** `export HOPE_MODELCASES_PATH=/path/to/HOPEModelCases`
- **Windows (PowerShell):** `$env:HOPE_MODELCASES_PATH = "C:\path\to\HOPEModelCases"`

## 4. Install the latest development version

Developers and users who intentionally want the most recent, unreleased changes
should clone the `main` branch. The destination directory is named `HOPE` below
to match the example workflows in this documentation:

```bash
git clone https://github.com/HOPE-Model-Project/HOPE.jl.git HOPE
cd HOPE
julia --project=.
```

Then instantiate the checked-out project at the Julia prompt:

```julia
import Pkg
Pkg.instantiate()
using HOPE
```

The `main` branch may contain changes that have not yet been included in a
registered release. To update an existing checkout, run `git pull` in the HOPE
directory and then run `Pkg.instantiate()` again.

## 5. Solvers

A normal package installation includes the open-source solvers
[HiGHS](https://github.com/jump-dev/HiGHS.jl), [Cbc](https://github.com/coin-or/Cbc),
[GLPK](https://github.com/jump-dev/GLPK.jl), and
[Clp](https://github.com/jump-dev/Clp.jl). No commercial license is required.

Commercial solver packages such as [Gurobi](https://www.gurobi.com/),
[SCIP](https://scipopt.org/), and
[CPLEX](https://www.ibm.com/products/ilog-cplex-optimization-studio) are **not**
installed by `Pkg.instantiate()` by default. If needed, add them manually while the HOPE
project is active:

```julia
import Pkg
Pkg.activate(".")
Pkg.add("Gurobi")   # or "SCIP" / "CPLEX"
```

When you do this from an active HOPE environment, the commercial solver package is added
to the **HOPE project environment**, not just Julia's global default environment.

## 6. Minimal self-contained example

This one-bus DART SCUC example uses only package dependencies and creates no files:

```julia
using HOPE

data = DARTSystemData(
    generators = [
        DARTGenerator(
            name = "unit",
            bus = "bus",
            pmax_mw = 100.0,
            variable_cost_per_mwh = 25.0,
            commitment_required = false,
        ),
    ],
    network = DARTNetwork(bus_names = ["bus"]),
)
forecast = DARTForecast(
    interval_hours = 1.0,
    load_mw = reshape([40.0], 1, 1),
    availability = ones(1, 1),
)
result = solve_dart_scuc(data, forecast, default_dart_state(data))

result.generation_mw
```

The expected dispatch is 40 MW. Larger GTEP, PCM, holistic, and EREC examples
are maintained separately in
[HOPEModelCases](https://github.com/HOPE-Model-Project/HOPEModelCases).
