## Overview

The generation and transmission expansion planning (GTEP) model co-optimizes investment and operations under policy constraints.

The model jointly decides:

- investment/retirement decisions for generators, transmission, and storage;
- hourly operations (generation, transmission flows, storage charging/discharging, and optional demand response);
- policy compliance under RPS/REC trading and carbon-policy modes.

Temporal structure supports either full-year hourly chronology or representative-day compression with weighted periods.
Planning reserve adequacy can be enforced at system or zonal level, and operating reserve is modeled as SPIN in the current GTEP implementation.

Model class by configuration:

- `inv_dcs_bin = 1`: MILP (binary build/retire decisions)
- `inv_dcs_bin = 0`: relaxed LP

If a MILP is solved and `write_shadow_prices = 1`, HOPE performs a fixed-LP re-solve to recover dual values (for example, zonal power-balance prices).

## Active Mode Switches

- `planning_reserve_mode`:
  - `0`: off
  - `1`: system RA
  - `2`: zonal RA
- `operation_reserve_mode`:
  - `0`: off
  - `1`: SPIN reserve only
- `clean_energy_policy`:
  - `0`: RPS off
  - `1`: RPS with REC trading
  - `2`: local RPS without REC trading
- `carbon_policy`:
  - `0`: off
  - `1`: state emissions cap with slack penalty
  - `2`: state allowance balance with slack penalty
- `flexible_demand`:
  - `0`: DR off
  - `1`: DR backlog formulation on

# Problem Formulation

## Objective

Minimize total annual system cost:

```math
\min \; C^{inv}_{gen} + C^{inv}_{line} + C^{inv}_{sto}
      + C^{op}_{gen} + C^{op}_{sto}
      + C^{DR} + C^{LS} + C^{RPS\_pen} + C^{CO2\_pen}
```

Expanded form:

```math
\begin{aligned}
\min \Gamma =\;
&\sum_{g\in G^+} \tilde I_g\,x_g
+ \sum_{l\in L^+} \tilde I_l\,y_l
+ \sum_{s\in S^+} \tilde I_s\,z_s \\
&+ \sum_{g\in G,t\in T} VCG_g\,N_t \sum_{h\in H_t} p_{g,h}
+ \sum_{s\in S,t\in T} VCS_s\,N_t \sum_{h\in H_t}(c_{s,h}+dc_{s,h}) \\
&+ \sum_{i\in I,t\in T} VOLL\,N_t\sum_{h\in H_t} p^{LS}_{i,h} \\
&+ \mathbb{1}_{FD}\sum_{t\in T}N_t\sum_{i\in I}\sum_{r\in R_i}\sum_{h\in H_t}
DRC\,(dr^{DF}_{r,h}+dr^{PB}_{r,h}) \\
&+ \mathbb{1}_{RPS}\,PT^{rps}\sum_{w\in W} pt^{rps}_w
+ \mathbb{1}_{CO2}\,PT^{emis}\sum_{w\in W} em^{emis}_w
\end{aligned}
```

Decision vector:

```math
\Gamma =
\{x_g,\;x_g^{RET},\;y_l,\;z_s,\;f_{l,h},\;p_{g,h},\;p^{LS}_{i,h},\;c_{s,h},\;dc_{s,h},\;soc_{s,h},
\;pt_w^{rps},\;pw_{g,w},\;pwe_{g,w,w^\prime},\;em_w^{emis},\;a_g,\;b_{r,h},\;dr_{r,h}^{DF},\;dr_{r,h}^{PB},
\;r^{SPIN}_{g,h},\;r^{SPIN}_{s,h}\}
```

Notes:

- $DR^{opt}_{i,h}$ is an auxiliary net-shift term in zonal power balance:
  $DR^{opt}_{i,h}=\sum_{r\in R_i}(dr^{PB}_{r,h}-dr^{DF}_{r,h})$.
- $a_g$ is active only when `carbon_policy = 2`.
- $em_w^{emis}$ is active only when $carbon\_policy \in \{1,2\}$.
- Indicators $\mathbb{1}_{FD}$, $\mathbb{1}_{RPS}$, $\mathbb{1}_{CO2}\in\{0,1\}$ are controlled by `flexible_demand`, `clean_energy_policy`, and `carbon_policy`.

## Constraint Blocks

Constraint IDs in code comments use the same labels below (for example, `GTEP-C5` in `src/GTEP.jl`).

### 1. [GTEP-C1] Investment budgets

```math
\sum_{g\in G^{+}} INV_g\,P^{max}_g\,x_g \le IBG
```

```math
\sum_{l\in L^{+}} \tilde I_l\,y_l \le IBL
```

```math
\sum_{s\in S^{+}} INV_s\,SCAP_s\,z_s \le IBS
```

### 2. [GTEP-C2] Power balance

For each zone and modeled hour:

```math
\sum_{g \in G_i} p_{g,h}
+ \sum_{s \in S_i} (dc_{s,h} - c_{s,h})
- \sum_{l \in LS_i} f_{l,h}
+ \sum_{l \in LR_i} f_{l,h}
+ NI_{i,h}
= Load_{i,h} + DR^{opt}_{i,h} - p^{LS}_{i,h}
```

If `flexible_demand = 0`, $DR^{opt}_{i,h}=0$.

When `transmission_loss = 1`, HOPE adds endpoint-allocated line losses to zonal balance:

```math
\mathrm{ZoneLineLoss}_{i,h} = \frac{1}{2}\sum_{l \in LS_i \cup LR_i} loss_{l,h},
\qquad
loss_{l,h} = \rho_l |f_{l,h}|
```

### 3. [GTEP-C3] Transmission limits

Positive flow follows the input row from `From_zone` to `To_zone`. For existing
lines $l\in L^{E}$:

```math
-F^{reverse}_l \le f_{l,h} \le F^{forward}_l
```

For candidate lines $l\in L^{+}$:

```math
-F^{reverse}_l\,y_l \le f_{l,h} \le F^{forward}_l\,y_l
```

The same build decision activates both ratings. Symmetric corridors are entered
with $F^{forward}_l=F^{reverse}_l$.

### 4. [GTEP-C4] Generator operating limits (with SPIN headroom)

Minimum output applies to energy dispatch. Energy and SPIN are co-limited by
available capacity, so reserve cannot substitute for a unit's minimum-energy
requirement.

For existing non-retirement units $g\in G^{E}\setminus G^{RET}$:

```math
P^{min}_g \le p_{g,h},
\qquad
p_{g,h} + r^{SPIN}_{g,h} \le P^{max}_g \cdot AF_{g,h}
```

For retirement-eligible existing units $g\in G^{RET}$:

```math
P^{min}_g(1-x^{RET}_g) \le p_{g,h},
\qquad
p_{g,h} + r^{SPIN}_{g,h} \le P^{max}_g AF_{g,h}(1-x^{RET}_g)
```

For candidate units $g\in G^{+}$:

```math
P^{min}_g x_g \le p_{g,h},
\qquad
p_{g,h} + r^{SPIN}_{g,h} \le P^{max}_g AF_{g,h} x_g
```

Must-run generators are enforced at available maximum output (with candidate/retirement status applied consistently in code).

### 5. [GTEP-C5] Storage operation

Power/energy limits and SOC dynamics:

```math
dc_{s,h} + r^{SPIN}_{s,h} \le SD_s \cdot SCAP_s
```

```math
0 \le c_{s,h} \le SC_s\cdot SCAP_s,\quad
0 \le dc_{s,h} \le SD_s\cdot SCAP_s,\quad
0 \le soc_{s,h} \le SECAP_s
```

```math
soc_{s,h} = soc_{s,h-1} + \eta^{ch}_s c_{s,h} - dc_{s,h}/\eta^{dis}_s
```

SPIN deliverability from stored energy:

```math
r^{SPIN}_{s,h} \cdot \Delta^{SPIN} \le soc_{s,h}
```

Storage chronology depends on time structure:

- Full-year mode (`endogenous_rep_day = 0` and `external_rep_day = 0`): cyclic SOC wrap from hour 8760 to hour 1.
- Representative-day mode (`endogenous_rep_day = 1` or `external_rep_day = 1`):
  - Short-duration storage ($S^{SD}$) uses start/end anchor $\alpha^{anchor}_{s,t}$ (`alpha_storage_anchor[s,t]` in code).
  - Long-duration storage ($S^{LD}$) links SOC across representative periods.
  - With Feature 6 (`link_storage_rep_days = 1` in `HOPE_rep_day_settings.yml`), endogenous representative-day mode uses predecessor weights derived from the real day-to-representative mapping rather than a simple fixed `t-1` ordering.

### 6. [GTEP-C6] Planning reserve adequacy

Activated by `planning_reserve_mode`:

System RA mode (`planning_reserve_mode = 1`):

```math
\sum_{g\in G^{E}\setminus G^{RET}} CC_gP^{max}_g
\; + \sum_{g\in G^{RET}} CC_gP^{max}_g(1-x^{RET}_g)
+\sum_{g\in G^{+}} CC_gP^{max}_g x_g
+\sum_{s\in S^{E}} CC_sSCAP_s
+\sum_{s\in S^{+}} CC_sSCAP_s z_s
+DR^{RA}_{sys}
\ge (1+PRM)\,PK_{sys}
```

Zonal RA mode (`planning_reserve_mode = 2`), for each zone $i$:

```math
\sum_{g\in (G_i\cap G^{E})\setminus G^{RET}} CC_gP^{max}_g
\; + \sum_{g\in G_i\cap G^{RET}} CC_gP^{max}_g(1-x^{RET}_g)
+\sum_{g\in G_i\cap G^{+}} CC_gP^{max}_g x_g
+\sum_{s\in S_i\cap S^{E}} CC_sSCAP_s
+\sum_{s\in S_i\cap S^{+}} CC_sSCAP_s z_s
+DR^{RA}_{i}
\ge (1+PRM_i)\,PK_i
```

RA includes DR capacity credit terms when `flexible_demand = 1`.

### 7. [GTEP-C7] Operating reserve (SPIN only)

Activated by `operation_reserve_mode = 1`:

```math
\sum_{g\in G} r^{SPIN}_{g,h} + \sum_{s\in S} r^{SPIN}_{s,h} \ge \rho^{SPIN} \cdot Load_h
```

If reserve mode is off, HOPE substitutes zero-valued reserve expressions and
does not create resource-hour reserve variables or zero-fixing constraints.

### 8. [GTEP-C8] RPS with REC trading

RPS uses $pwe_{g,w,w^\prime}$:

- Meaning: annual renewable credits generated by unit $g$ in state $w$ and exported from $w$ to $w^\prime$.
- Export and import feasibility constraints are enforced via $WER_w$ and $WIR_w$.
- State RPS balance includes in-state renewable accounting $pw_{g,w}$, net REC imports/exports, and slack $pt^{rps}_w$.

When `clean_energy_policy = 1`, the code enforces:

```math
G_w := \bigcup_{i\in I_w} G_i
```

[GTEP-C8.1] State-level renewable accounting:

```math
pw_{g,w}=\sum_{t\in T}N_t\sum_{h\in H_t} p_{g,h},
\quad g\in G^{RPS}\cap G_w
```

[GTEP-C8.2] REC export feasibility:

```math
pw_{g,w}\ge \sum_{w^\prime\in WER_w} pwe_{g,w,w^\prime}
```

[GTEP-C8.3] REC import feasibility:

```math
pw_{g,w^\prime}\ge pwe_{g,w^\prime,w},
\quad \forall w^\prime\in WIR_w
```

[GTEP-C8.4] State RPS balance with REC trading and slack:

```math
\begin{aligned}
&\sum_{g\in G^{RPS}\cap G_w} pw_{g,w}
+\sum_{w^\prime\in WIR_w}\sum_{g\in G^{RPS}\cap G_{w^\prime}} pwe_{g,w^\prime,w}
-\sum_{w^\prime\in WER_w}\sum_{g\in G^{RPS}\cap G_w} pwe_{g,w,w^\prime}
+ pt^{rps}_w \\
&\ge \sum_{t\in T}N_t\sum_{h\in H_t}\sum_{i\in I_w}\sum_{d\in D_i} P_{h,d}PK_d\,RPS_w
\end{aligned}
```

When `clean_energy_policy = 2`, HOPE enforces the same annual RPS energy
requirement locally in each policy region:

```math
\sum_{g\in G^{RPS}\cap G_w}\sum_{t\in T}N_t\sum_{h\in H_t}p_{g,h}
+pt^{rps}_w
\ge
RPS_w\sum_{t\in T}N_t\sum_{h\in H_t}\sum_{d\in D_w}P_{h,d}PK_d.
```

Mode `2` does not create the generator-state accounting variables `pw` or the
generator-state-pair REC-trading variables `pwe`. When
`clean_energy_policy = 0`, HOPE substitutes zero-valued RPS slack expressions
and does not create RPS variables or constraints.

### 9. [GTEP-C9A/C9B/C9O] Carbon policy

Formulation by flag:

- `carbon_policy = 1`:

```math
\sum_{t\in T}N_t\sum_{h\in H_t}\sum_{g\in G_w\cap G^{F}} EF_g\,p_{g,h}
\le ELMT_w + em^{emis}_w,\quad \forall w\in W
```

- `carbon_policy = 2`:

Cap-and-trade formulation (state allowance cap + allowance-emission balance):

```math
\sum_{g\in G_w\cap G^{F}} a_g \le ALW_w,\quad \forall w\in W
```

```math
\sum_{t\in T}N_t\sum_{h\in H_t}\sum_{g\in G_w\cap G^{F}} EF_g\,p_{g,h}
\le \sum_{g\in G_w\cap G^{F}} a_g + em^{emis}_w,\quad \forall w\in W
```

If `carbon_policy = 0`, no carbon-policy constraints are imposed.

### 10. [GTEP-C10] Flexible demand (backlog form)

If enabled, DR uses deferred $dr^{DF}_{r,h}$, payback $dr^{PB}_{r,h}$, and backlog $b_{r,h}$ with:

```math
b_{r,h}=b_{r,h-1}+dr^{DF}_{r,h}-\eta^{DR}_r\,dr^{PB}_{r,h}
```

for non-first hours in each modeled period, with start/end closure:

```math
b_{r,h^{start}_t}=0,\qquad b_{r,h^{end}_t}=0
```

and bounds:

```math
dr^{DF}_{r,h}\le \overline{DR}^{DF}_{r,h},\quad
dr^{PB}_{r,h}\le \overline{DR}^{PB}_{r,h},\quad
b_{r,h}\le \tau^{DR}_r\cdot \overline{DR}^{DF,peak}_r
```

### 11. Variable domains

Binary (or relaxed to $[0,1]$ when `inv_dcs_bin = 0`):

```math
x_g,\;x_g^{RET},\;y_l,\;z_s \in \{0,1\}
```

Nonnegative variables:

```math
a_g,\;b_{r,h},\;p_{g,h},\;p^{LS}_{i,h},\;c_{s,h},\;dc_{s,h},\;soc_{s,h},\;pt_w^{rps},
\;pw_{g,w},\;pwe_{g,w,w^\prime},\;em_w^{emis},\;dr^{DF}_{r,h},\;dr^{PB}_{r,h},\;
r^{SPIN}_{g,h},\;r^{SPIN}_{s,h}\ge 0
```

## Output and Dual Notes

- Candidate capacity columns in `capacity.csv`, `es_capacity.csv`, `line.csv`, and
  `power_flow.csv` report installed capacity: the input candidate block size multiplied
  by its optimized build decision. HOPE keeps the source input tables unchanged, and
  `system_cost.csv` applies each build decision exactly once when calculating investment
  cost. This distinction matters when `inv_dcs_bin = 0` permits fractional builds.
- `power_price.csv` in GTEP requires duals of `PB_con`.
- For MILP (`inv_dcs_bin = 1`), enable `write_shadow_prices = 1` to trigger fixed-LP dual recovery before output writing.
