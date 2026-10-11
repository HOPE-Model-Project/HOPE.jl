# HOPE Documentation

```@meta
CurrentModule = HOPE
```

# Overview

The **Holistic Optimization Program for Electricity (HOPE)** model is a transparent and open-source tool for evaluating electric sector transition pathways and policy scenarios regarding power system planning, system operation, optimal power flow, and market designs. It is a highly configurable and modular tool coded in the [Julia](http://julialang.org/) language and optimization package [JuMP](http://jump.dev/).
HOPE currently provides five primary Julia workflows:

1. the `GTEP` generation and transmission expansion planning model;
2. the `PCM` production cost model;
3. the `DART` day-ahead and real-time SCUC/SCED workflow, available through standard file-backed cases and a typed in-memory API;
4. the holistic two-stage `GTEP`-to-`PCM` workflow; and
5. the `EREC` postprocessing workflow.

An OPF formulation is planned for future development. The GTEP, PCM, and DART optimization models can be solved with open-source packages such as [HiGHS](https://github.com/jump-dev/HiGHS.jl), [Cbc](https://github.com/coin-or/Cbc), [GLPK](https://github.com/jump-dev/GLPK.jl), and [Clp](https://github.com/coin-or/Clp), or optional commercial packages such as [Gurobi](https://www.gurobi.com/) and [CPLEX](https://www.ibm.com/products/ilog-cplex-optimization-studio).

# Interactive Dashboards

Explore HOPE results interactively — no installation required:

| Dashboard | Description | Link |
| :-- | :-- | :-- |
| **PCM Dashboard** | Hourly nodal LMP, congestion, and line analytics | [▶ Open](https://huggingface.co/spaces/HOPE-Model-Project/hope-pcm-dashboard) |
| **GTEP Dashboard** | Capacity expansion map, investment costs, and technology mix | [▶ Open](https://huggingface.co/spaces/HOPE-Model-Project/hope-gtep-dashboard) |

Both dashboards can also be run locally — see [Run a Case in HOPE](@ref) for instructions.

# Model Cases Library

Input data and configuration files for running HOPE are maintained in a separate repository: [HOPEModelCases](https://github.com/HOPE-Model-Project/HOPEModelCases). It includes cases spanning a range of test systems (IEEE 14/118, RTS-24, ISO-NE, PJM, Germany) and study questions including expansion planning, production cost modeling, day-ahead/real-time market operations, resource aggregation, and holistic planning runs.

See [Installation](@ref) for setup instructions.

# Contributors

The HOPE model was originally developed by a team of researchers in Prof. [Benjamin F. Hobbs's group](https://hobbsgroup.johnshopkins.edu/) at [Johns Hopkins University](https://www.jhu.edu/). The main contributors for Version 1 include Dr. [Shen Wang](https://ceepr.mit.edu/people/wang/), Dr. [Mahdi Mehrtash](https://www.mahdimehrtash.com/), and [Zoe Song](https://github.com/HOPE-Model-Project).

The current HOPE model is also maintained by researchers at [MIT](https://mit.edu/), including [Shen Wang](https://ceepr.mit.edu/people/wang/), Dr. [Juan Senga](https://ceepr.mit.edu/people/senga/), and Prof. [Christopher Knittel](https://mitsloan.mit.edu/faculty/directory/christopher-knittel).
