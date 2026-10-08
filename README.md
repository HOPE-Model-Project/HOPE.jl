# HOPE - Holistic Optimization Program for Electricity

[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://hope-model-project.github.io/HOPE.jl/dev/)
[![Build Status](https://github.com/HOPE-Model-Project/HOPE.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/HOPE-Model-Project/HOPE.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/HOPE-Model-Project/HOPE.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/HOPE-Model-Project/HOPE.jl)

![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/ec1e57fe-c65e-4e41-a128-43d2bbc3963c)

## How to cite HOPE?

Please cite the HOPE software repository:

```
Wang, S., Looney, A., Zhang, Q., Song, Z., Huang, Z., Senga, J., Mehrtash, M., Xie, L., Knittel, C., & Hobbs, B. F. (2026). HOPE - Holistic Optimization Program for Electricity (Version 2.0.0) [Computer software]. https://github.com/HOPE-Model-Project/HOPE.jl
```

Please also cite the foundational paper:

```
Wang, S., Song, Z., Mehrtash, M., & Hobbs, B. F. (2025). HOPE: Holistic Optimization Program for Electricity. SoftwareX, 29, 101982. https://doi.org/10.1016/j.softx.2024.101982
```

See the repository [`CITATION.cff`](CITATION.cff) and the full [Citation](#citation)
section below for citation metadata and BibTeX entries.

# Overview

The **Holistic Optimization Program for Electricity (HOPE)** is a transparent and open-source platform for evaluating electric sector transition pathways and policy scenarios across power system planning, operation, optimal power flow, and market design. It is a highly configurable and modular platform written in the [Julia](http://julialang.org/) language with the [JuMP](http://jump.dev/) optimization package. HOPE's current and planned top-level modes and modules include:

1. `GTEP`: a generation and transmission expansion planning mode for evaluating long-term investment and policy pathways;
2. `PCM`: a production cost modeling mode for simulating power system operations and dispatch;
3. `DART`: a module for individual-generator day-ahead and real-time SCUC/SCED, market operations, and settlement modeling;
4. `OPF`: an optimal power flow mode, under development, that will support network-constrained power flow and related analyses; and
5. `HOPE-AI`: an AI-agent module, under active development, envisioned as a multi-agent coordination layer that connects HOPE's planning, operations, markets, policy, data, and analytical capabilities into accessible modeling workflows. The current framework is powered by [PowerAgent](https://github.com/Power-Agent), with more specialized agents under development.

Users can select the workflow appropriate for their research needs. The GTEP, PCM, and DART optimization models can be solved with open-source packages such as [HiGHS](https://github.com/jump-dev/HiGHS.jl), [Cbc](https://github.com/coin-or/Cbc), [GLPK](https://github.com/jump-dev/GLPK.jl), and [Clp](https://github.com/coin-or/Clp), or optional commercial packages such as [Gurobi](https://www.gurobi.com/) and [CPLEX](https://www.ibm.com/products/ilog-cplex-optimization-studio).

The HOPE model was originally developed by a team of researchers in Prof. [Benjamin F. Hobbs's group](https://hobbsgroup.johnshopkins.edu/) at [Johns Hopkins University](https://www.jhu.edu/). The main contributors for Version 1 include Dr. [Shen Wang](https://ceepr.mit.edu/people/wang/), Dr. [Mahdi Mehrtash](https://www.mahdimehrtash.com/), and [Zoe Song](https://pwrlab.org/team.html). The current developers include [Ziting Huang](https://hobbsgroup.johnshopkins.edu/members.html), etc.

The current HOPE model is also maintained by researchers at MIT, including Shen Wang, Dr. [Juan Senga](https://ceepr.mit.edu/people/senga/) and Prof. [Christopher Knittel](https://mitsloan.mit.edu/faculty/directory/christopher-knittel).

The `DART` module development is led by [Aidan Looney](https://www.linkedin.com/in/aidan-looney-3142582b8/) at Harvard University.
The HOPE-AI module is developed in collaboration with [Qian Zhang](https://seas.harvard.edu/person/qian-zhang) and Prof. [Le Xie](https://seas.harvard.edu/person/le-xie) at Harvard University.

> **Looking for the legacy Maryland-focused version?** The pre-v2 codebase is archived at [HOPE-MD](https://github.com/HOPE-Model-Project/HOPE-MD).

# Installation

## 1. Install Julia

Install [Julia](http://julialang.org/) language (Julia 1.9 or later is required for the current HOPE package setup). A short video tutorial on how to download and install Julia is provided [here](https://www.youtube.com/watch?v=t67TGcf4SmM).

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

Installation requires neither model cases nor commercial solver licenses.

HOPE installs HiGHS, GLPK, Clp, and Cbc as its open-source solver stack.
Gurobi, SCIP, and CPLEX are optional extensions: install the corresponding Julia
package and solver license only when you choose to use one of them. Dashboards
and the MCP server under `tools/` are separate Python applications and are not
started or installed with the Julia package.

## 3. Get model cases

Model cases are maintained separately in [HOPEModelCases](https://github.com/HOPE-Model-Project/HOPEModelCases). Clone them explicitly to a user-selected path:

```bash
git clone https://github.com/HOPE-Model-Project/HOPEModelCases /path/to/HOPEModelCases
```

Set `HOPE_MODELCASES_PATH` to that directory before running file-based GTEP,
PCM, holistic, or EREC examples. In a source checkout, cloning to
`HOPE/ModelCases` also enables automatic discovery. Package installation never
downloads or modifies the model-case repository.

> [!TIP]
> If you installed HOPE with `Pkg.add("HOPE")`, your setup is now complete.
> Continue to [Quick run with the registered package](#quick-run-with-the-registered-package).

## 4. Optional alternative: Install the latest development version

> [!NOTE]
> This optional workflow replaces Steps 2 and 3. Use it only if you are
> contributing to HOPE, testing unreleased changes, or developing
> repository-based tools such as HOPE-AI, dashboards, or the MCP server. Most
> users should skip this step.

Developers and users who intentionally want the most recent, unreleased changes
should clone the `main` branch. The destination directory is named `HOPE` below
to match the detailed example workflows in this README. The model cases are
cloned inside the source checkout so those workflows use the expected paths:

```bash
git clone https://github.com/HOPE-Model-Project/HOPE.jl.git HOPE
git clone https://github.com/HOPE-Model-Project/HOPEModelCases HOPE/ModelCases
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

> [!TIP]
> Continue to the [Detailed source-checkout workflow](#detailed-source-checkout-workflow).
> It expands this setup into screenshot-based instructions for first-time users.

# Run a Case in HOPE

## Quick run with the registered package

After completing Steps 1 through 3, start Julia in the environment where you
installed HOPE and pass the selected case directory to `run_hope`. For example:

```julia
using HOPE

case_path = "/absolute/path/to/HOPEModelCases/MD_GTEP_clean_case"
HOPE.run_hope(case_path)
```

Replace `case_path` with the location where you cloned HOPEModelCases. Results
are written to the case's `output` directory; HOPE does not write into its
installed package directory.

## Detailed source-checkout workflow

The screenshot-based instructions below expand optional Step 4 into a complete
first-time workflow. They intentionally repeat project activation and
instantiation so contributors can follow the process from the beginning.

> [!NOTE]
> These instructions assume that HOPE is cloned as `HOPE` and HOPEModelCases is
> cloned into `HOPE/ModelCases`, as shown in Step 4.

### Using VS Code to Run a Case (Recommended)

Install Visual Studio Code: Download [VS Code](https://code.visualstudio.com/) and [install](https://code.visualstudio.com/docs/setup/setup-overview) it. A short video tutorial on how to install VS Code and add Julia to it can be found [here](https://www.youtube.com/watch?v=oi5dZxPGNlk).

**(1)** Open the VScode, click the 'File' tab, select 'Open Folder...', and navigate to your home working directory:`/yourpath/home`

>[!NOTE]
>The `home` directory could be any folder where you save your HOPE project. The `home` directory in the example below is named `Maryland-Electric-Sector-Transition`.

![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/c8acf95d-909d-44e2-8ded-61635367dc53)

**(2)** In the VScode TERMINAL, type `Julia` and press the "Enter" button. Julia will be opened as below:

   ![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/5fc3a8c9-23f8-44a3-92ab-135c4dbdc118)

In Julia, you can use `pwd()` to check if your current working directory is your `home` directory, if it is not, you can use `cd("/yourpath/home")` to change your working directory, as the picture is shown below.

![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/a35268e3-b6ca-4d43-ad62-e5d0a67b0e8b)

**(3)** Make sure you are in the right working directory. Then, type `]` into the Julia package mode, and type `activate HOPE` (if you are in your `home` directory) or `activate yourpath/home/HOPE` (if you are not in your `home` directory), you will see prompt `(HOPE) pkg>`, which means the HOPE project is activated successfully.

   ![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/2a0c259d-060e-4799-a044-8dedb8e5cc4d)

**(4)** Type `instantiate` in the (HOPE) pkg prompt (make sure you are in your `home` directory, not the `home/HOPE` directory!).

This installs the default HOPE environment and the bundled open-source solvers. It does
**not** install commercial solver packages automatically.

**(5)** Type `st` to check that the dependencies (packages that HOPE needs) have been installed. Type `up` to update the version of dependencies (packages). (This step may take some time when you install HOPE for the first time. After the HOPE is successfully installed, you can skip this step)

![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/1eddf81c-97e4-4334-85ee-44958fcf8c2f)

**(6)** If there is no error in the above processes, the **HOPE** model has been successfully installed! Then, press `Backspace` button to return to the Juila prompt. To run an example case (e.g., default Maryland 2035 100% clean case with the `GTEP` model), type `using HOPE`, and type `HOPE.run_hope("HOPE/ModelCases/MD_GTEP_clean_case/")`, you will see the **HOPE** is running:
![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/519de1bf-03d0-4bad-8e69-a8a4fe2ad682)
The results will be saved in `yourpath/home/HOPE/ModelCases/MD_GTEP_clean_case/output`. An example of a successful run in Julia prompt can be seen below.
![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/99790827-4337-4991-a320-85ae2bd10be2)

**(7)** For future runs with this workflow, you can skip workflow steps (4) and
(5), and repeat steps (1), (2), (3), and (6).

### Using System Terminal to Run a Case

You can use a system terminal on Windows or macOS to run a test case. See the
platform-specific instructions below.

#### Windows users

**(1)** Open **Command Prompt** from Windows **Start** and navigate to your home path:`/yourpath/home`.

**(2)** Type `julia`. Julia will be opened as below:

![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/6c61bed1-bf8e-4186-bea2-22413fd1328e)

**(3)** Type `]` into the Julia package mode, and type `activate HOPE` (if you are in your `home` directory), you will see prompt `(HOPE) pkg>`, which means the HOPE project is activated successfully.

**(4)** Type `instantiate` in the (HOPE) pkg prompt. ( After the HOPE is successfully installed, you can skip this step)

This installs the default HOPE environment and the bundled open-source solvers. It does
**not** install commercial solver packages automatically.

**(5)** Type `st` to check that the dependencies (packages that HOPE needs) have been installed. Type `up` to update the version of dependencies (packages). (This step may take some time when you install HOPE for the first time. After the HOPE is successfully installed, you can skip this step)
![ccf1c53042925fcfb13ee232c13210e](https://github.com/HOPE-Model-Project/HOPE.jl/assets/144710777/6efb4646-8c81-4f4b-bcfc-6daabbdeb615)

**(6)** If there is no error in the above processes, the **HOPE** model has been successfully installed. Then, click `Backspace` to return to the Juila prompt. To run an example case (e.g., default Maryland 2035 100% clean case with the `GTEP` model), type `using HOPE`, and type `HOPE.run_hope("HOPE/ModelCases/MD_GTEP_clean_case/")`, you will see the **HOPE** is running:

![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/519de1bf-03d0-4bad-8e69-a8a4fe2ad682)

The results will be saved in `yourpath/home/HOPE/ModelCases/MD_GTEP_clean_case/output`.

![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/99790827-4337-4991-a320-85ae2bd10be2)

**(7)** For future runs with this workflow, you can skip workflow steps (4) and
(5), and repeat steps (1), (2), (3), and (6).

#### macOS users

**Run your case:** Follow these steps:
![image](https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/bc0ef4d9-b9b1-468a-a9a0-a0b2aa3d4340)

# Solvers

## Free Solvers

HOPE bundles the following open-source solvers and no extra installation is needed:
**HiGHS** (default), **GLPK**, **Clp**, **Cbc**.

Set `solver: highs` (or any of the above) in
`ModelCases/<case>/Settings/HOPE_model_settings.yml`.

## Commercial Solvers

**Gurobi**, **SCIP**, and **CPLEX** are supported but are *not* installed by default.
Because they require a separate license, they are optional dependencies that you add to
your own Julia environment — HOPE does not pull them in automatically. HOPE uses
Julia package extensions for these integrations, so commercial solver support
requires Julia 1.9 or later.

### Steps to enable a commercial solver

**Step 1 — Obtain a license.**

- [Gurobi Academic or Commercial License](https://www.gurobi.com/solutions/licensing/)
- [SCIP (free for academic use)](https://scipopt.org/)
- [CPLEX Academic or Commercial License](https://www.ibm.com/products/ilog-cplex-optimization-studio)

**Step 2 — Install the Julia package** in the HOPE project environment.

```julia
# start Julia in the HOPE repo root, then:
import Pkg
Pkg.activate(".")          # activate the HOPE environment
Pkg.add("Gurobi")          # or "SCIP" / "CPLEX"
```

If you activate HOPE first with `Pkg.activate(".")`, then `Pkg.add("Gurobi")` installs
`Gurobi.jl` into the **HOPE project environment**, not just the global default Julia
environment.

> [!NOTE]
> `Gurobi.jl` requires the Gurobi solver itself to be installed on your machine
> and a valid `GRB_LICENSE_FILE` environment variable. See the
> [Gurobi.jl README](https://github.com/jump-dev/Gurobi.jl) for details.

**Step 3 — Set the solver** in the case settings file.

```yaml
# ModelCases/<case>/Settings/HOPE_model_settings.yml
solver: gurobi    # or: scip / cplex
```

HOPE will load the commercial solver package automatically the first time it is
requested. If the package is not installed, a clear error message is shown.

# Documentation

Check online [Documentation](https://hope-model-project.github.io/HOPE.jl/dev/) for HOPE.

For MCP / agent setup guidance, see:

- [HOPE-AI: Running HOPE with an LLM Agent](https://hope-model-project.github.io/HOPE.jl/dev/hope_ai/)
- [Local MCP server README](tools/hope_mcp_server/README.md)

# Citation

If HOPE contributes to your work, please cite both the software release and the
foundational SoftwareX paper. The software citation credits the complete
development team, while the paper documents the original model and methodology.
GitHub's **Cite this repository** menu generates the software citation from
[`CITATION.cff`](CITATION.cff).

## HOPE software

> Wang, S., Looney, A., Zhang, Q., Song, Z., Huang, Z., Senga, J.,
> Mehrtash, M., Xie, L., Knittel, C., & Hobbs, B. F. (2026). *HOPE - Holistic
> Optimization Program for Electricity* (Version 2.0.0) [Computer software].
> <https://github.com/HOPE-Model-Project/HOPE.jl>

```bibtex
@software{hope_software_2026,
  author  = {Wang, Shen and Looney, Aidan and Zhang, Qian and
             Song, Zoe and Huang, Ziting and Senga, Juan and
             Mehrtash, Mahdi and Xie, Le and Knittel, Christopher and
             Hobbs, Benjamin F.},
  title   = {{HOPE - Holistic Optimization Program for Electricity}},
  version = {2.0.0},
  year    = {2026},
  url     = {https://github.com/HOPE-Model-Project/HOPE.jl}
}
```

## Foundational paper

> Wang, S., Song, Z., Mehrtash, M., & Hobbs, B. F. (2025). HOPE: Holistic
> Optimization Program for Electricity. *SoftwareX, 29*, 101982.
> <https://doi.org/10.1016/j.softx.2024.101982>

```bibtex
@article{wang_hope_2025,
  author  = {Wang, Shen and Song, Zoe and Mehrtash, Mahdi and
             Hobbs, Benjamin F.},
  title   = {{HOPE: Holistic Optimization Program for Electricity}},
  journal = {SoftwareX},
  volume  = {29},
  pages   = {101982},
  year    = {2025},
  doi     = {10.1016/j.softx.2024.101982}
}
```

# Research & Publication

[Energy Resilience and Efficiency in Maryland](https://mde.maryland.gov/programs/air/ClimateChange/MCCC/Doclib_ERE/EREWG%20Study%20Report%20--%20Energy%20Resilience%20and%20Efficiency%20in%20Maryland.pdf)

## Acknowledgement

This project is funded by [Maryland Energy Administration](https://energy.maryland.gov/Pages/default.aspx)

# Program Sponsors

<img src="https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/6abb8305-ca8f-4506-8e59-5f82e2893118" width="200" height="70" />
<br clear="both"/>
<img src="https://github.com/HOPE-Model-Project/HOPE.jl/assets/125523842/a0c7ee3e-1ac5-4a59-9698-d654b542d64e" width="320" height="160" />
<br clear="both"/>
<img src="https://ceepr.mit.edu/wp-content/uploads/2024/01/CEEPR_Logo_05_revised.png" width="280" alt="MIT CEEPR logo" />
<br clear="both"/>
<img src="docs/src/assets/poweragent-logo.png" width="280" alt="PowerAgent logo" />
<br clear="both"/>
<img src="docs/src/assets/pai-logo.png" width="320" alt="Power and AI Initiative at Harvard SEAS logo" />
