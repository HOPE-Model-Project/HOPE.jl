function gtep_debug_stage_log(config_set::Dict, stage::AbstractString)
    debug_stage_file = get(config_set, "debug_stage_file", nothing)
    if debug_stage_file === nothing
        return nothing
    end
    open(String(debug_stage_file), "a") do io
        println(io, "time=", time(), ", stage=", stage)
    end
    return nothing
end

function gtep_optimizer_diagnostics(optimizer)
    diagnostics = Dict{String,String}()
    diagnostics["optimizer_type"] = string(typeof(optimizer))
    diagnostics["optimizer_fields"] = join(string.(fieldnames(typeof(optimizer))), ", ")
    if hasfield(typeof(optimizer), :optimizer_constructor)
        optimizer_constructor = getfield(optimizer, :optimizer_constructor)
        diagnostics["optimizer_constructor_type"] = string(typeof(optimizer_constructor))
        diagnostics["optimizer_constructor_repr"] = repr(optimizer_constructor)
        diagnostics["optimizer_constructor_string"] = string(optimizer_constructor)
        diagnostics["optimizer_constructor_zero_arg_callable"] =
            string(applicable(optimizer_constructor))
    end
    return diagnostics
end

function gtep_optimizer_constructor_probe(optimizer)
    if !hasfield(typeof(optimizer), :optimizer_constructor)
        return Dict("has_optimizer_constructor" => "false")
    end
    optimizer_constructor = getfield(optimizer, :optimizer_constructor)
    probe = Dict{String,String}()
    probe["has_optimizer_constructor"] = "true"
    probe["optimizer_constructor_type"] = string(typeof(optimizer_constructor))
    probe["optimizer_constructor_repr"] = repr(optimizer_constructor)
    probe["optimizer_constructor_string"] = string(optimizer_constructor)
    probe["optimizer_constructor_zero_arg_callable"] =
        string(applicable(optimizer_constructor))
    try
        optimizer_instance = optimizer_constructor()
        probe["optimizer_constructor_direct_call_ok"] = "true"
        probe["optimizer_instance_type"] = string(typeof(optimizer_instance))
    catch err
        probe["optimizer_constructor_direct_call_ok"] = "false"
        probe["optimizer_constructor_direct_call_error"] = sprint(showerror, err)
    end
    return probe
end

"""
    create_GTEP_model(
        config_set::Dict,
        input_data::Dict,
        OPTIMIZER::MOI.OptimizerWithAttributes,
    ) -> Model

Build a JuMP model for the Generation and Transmission Expansion Planning (GTEP) problem.

`config_set` is the parsed settings dictionary; `input_data` is the dictionary returned
by `load_data`; `OPTIMIZER` is the solver handle returned by `initiate_solver`.

The model captures investment decisions for generators, energy storage, and transmission
lines subject to capacity adequacy, carbon policy, and network constraints.  Returns the
un-solved `JuMP.Model`.
"""
function create_GTEP_model(
    config_set::Dict,
    input_data::Dict,
    OPTIMIZER::MOI.OptimizerWithAttributes,
)
    model_mode = config_set["model_mode"]
    if model_mode == "PCM"
        return "ModeError: Please use function 'create_PCM_model' or set model mode to be 'GTEP'!"
    elseif model_mode == "GTEP"
        gtep_debug_stage_log(config_set, "create_gtep_model_start")
        #network
        Zonedata = input_data["Zonedata"]
        Linedata = input_data["Linedata"]
        #technology
        Gendata = input_data["Gendata"]
        Storagedata = input_data["Storagedata"]
        Gencostdata = input_data["Gendata"][:, Symbol("Cost (\$/MWh)")]
        #reservedata=
        #time series
        AFdata = input_data["AFdata"] #Generator-level hourly availability factors
        Loaddata = input_data["Loaddata"]
        NIdata = input_data["NIdata"]
        #candidate
        Estoragedata_candidate = input_data["Estoragedata_candidate"]
        Linedata_candidate = input_data["Linedata_candidate"]
        Gendata_candidate = input_data["Gendata_candidate"]
        # Availability factor defaults (backward compatible):
        # if AF is omitted, assume AF = 1.0.
        if !("AF" in names(Gendata))
            Gendata[!, "AF"] = fill(1.0, nrow(Gendata))
        end
        if !("AF" in names(Gendata_candidate))
            Gendata_candidate[!, "AF"] = fill(1.0, nrow(Gendata_candidate))
        end
        #policies
        CBPdata = input_data["CBPdata"]
        CBP_state_data =
            combine(groupby(CBPdata, :State), Symbol("Allowance (tons)") => sum)
        #rpspolicydata=
        RPSdata = input_data["RPSdata"]
        #penalty_cost, investment budgets, planning reserve margins etc. single parameters
        SinglePardata = input_data["Singlepar"]
        # Carbon policy switch:
        # 0 = no carbon policy
        # 1 = Option A (state emission cap with slack penalty)
        # 2 = Option B (cap-and-trade style allowance + slack penalty)
        carbon_policy_raw = get(config_set, "carbon_policy", 1)
        carbon_policy =
            carbon_policy_raw isa Integer ? Int(carbon_policy_raw) :
            parse(Int, string(carbon_policy_raw))
        if !(carbon_policy in [0, 1, 2])
            throw(
                ArgumentError(
                    "Invalid carbon_policy=$(carbon_policy). Expected 0, 1, or 2.",
                ),
            )
        end
        # Clean energy policy switch:
        # 0 = turn RPS off
        # 1 = RPS with renewable-credit trading
        # 2 = local RPS without renewable-credit trading
        clean_energy_policy_raw = get(config_set, "clean_energy_policy", 1)
        clean_energy_policy =
            clean_energy_policy_raw isa Integer ? Int(clean_energy_policy_raw) :
            parse(Int, string(clean_energy_policy_raw))
        if !(clean_energy_policy in [0, 1, 2])
            throw(
                ArgumentError(
                    "Invalid clean_energy_policy=$(clean_energy_policy). Expected 0, 1, or 2.",
                ),
            )
        end
        # Planning reserve mode switch:
        # 0 = off
        # 1 = system-level planning reserve
        # 2 = zonal-level planning reserve
        planning_reserve_mode_raw = get(config_set, "planning_reserve_mode", 1)
        planning_reserve_mode =
            planning_reserve_mode_raw isa Integer ? Int(planning_reserve_mode_raw) :
            parse(Int, string(planning_reserve_mode_raw))
        if !(planning_reserve_mode in [0, 1, 2])
            throw(
                ArgumentError(
                    "Invalid planning_reserve_mode=$(planning_reserve_mode). Expected 0, 1, or 2.",
                ),
            )
        end
        # Operation reserve mode switch (GTEP models SPIN only):
        # 0 = off
        # 1 = on
        operation_reserve_mode_raw = get(config_set, "operation_reserve_mode", 0)
        operation_reserve_mode =
            operation_reserve_mode_raw isa Integer ? Int(operation_reserve_mode_raw) :
            parse(Int, string(operation_reserve_mode_raw))
        if !(operation_reserve_mode in [0, 1])
            throw(
                ArgumentError(
                    "Invalid operation_reserve_mode=$(operation_reserve_mode). Expected 0 or 1.",
                ),
            )
        end
        # Transmission expansion switch:
        # 0 = force all candidate transmission builds off
        # 1 = allow candidate transmission expansion (subject to budgets/constraints)
        transmission_expansion_raw = get(config_set, "transmission_expansion", 1)
        transmission_expansion =
            transmission_expansion_raw isa Integer ? Int(transmission_expansion_raw) :
            parse(Int, string(transmission_expansion_raw))
        if !(transmission_expansion in [0, 1])
            throw(
                ArgumentError(
                    "Invalid transmission_expansion=$(transmission_expansion). Expected 0 or 1.",
                ),
            )
        end
        # Transmission loss switch:
        # 0 = lossless transport
        # 1 = piecewise-linear loss approximation using |flow|
        transmission_loss_raw = get(config_set, "transmission_loss", 0)
        transmission_loss =
            transmission_loss_raw isa Integer ? Int(transmission_loss_raw) :
            parse(Int, string(transmission_loss_raw))
        if !(transmission_loss in [0, 1])
            throw(
                ArgumentError(
                    "Invalid transmission_loss=$(transmission_loss). Expected 0 or 1.",
                ),
            )
        end
        flexible_demand_raw = get(config_set, "flexible_demand", 0)
        flexible_demand =
            flexible_demand_raw isa Integer ? Int(flexible_demand_raw) :
            parse(Int, string(flexible_demand_raw))
        if !(flexible_demand in [0, 1])
            throw(
                ArgumentError(
                    "Invalid flexible_demand=$(flexible_demand). Expected 0 or 1.",
                ),
            )
        end
        endogenous_rep_day, external_rep_day, representative_day_mode =
            resolve_rep_day_mode(config_set; context = "GTEP")

        #Calculate number of elements of input data
        Num_bus = size(Zonedata, 1)
        Num_gen = size(Gendata, 1)
        Num_load = size(Zonedata, 1) #to revise, consider nodal
        Num_Eline = size(Linedata, 1)
        Num_zone = length(Zonedata[:, "Zone_id"])
        Num_sto = size(Storagedata, 1)
        Num_Csto = size(Estoragedata_candidate, 1)
        Num_Cgen = size(Gendata_candidate, 1)
        Num_Cline = size(Linedata_candidate, 1)

        #Index-Zone Mapping dict
        Idx_zone_dict = Dict(zip([i for i = 1:Num_zone], Zonedata[:, "Zone_id"]))
        Zone_idx_dict = Dict(zip(Zonedata[:, "Zone_id"], [i for i = 1:Num_zone]))
        #Ordered zone
        Ordered_zone_nm = [Idx_zone_dict[i] for i = 1:Num_zone]
        #Ordered generator labels for generator-level availability input
        Ordered_gen_nm = ["G$(g)" for g = 1:(Num_gen+Num_Cgen)]
        required_af_time_cols = ["Time Period", "Hours"]
        missing_af_time_cols = setdiff(required_af_time_cols, names(AFdata))
        if !isempty(missing_af_time_cols)
            throw(
                ArgumentError(
                    "Missing required time columns in generator availability input: $(collect(missing_af_time_cols)). Expected at least Time Period and Hours.",
                ),
            )
        end
        af_time_cols =
            vcat([c for c in ["Month", "Day"] if c in names(AFdata)], required_af_time_cols)
        validate_aligned_time_columns!(Loaddata, AFdata, "gen_availability_timeseries")
        AF_g_static_prefill = [
            Float64(coalesce(v, 1.0)) for
            v in [Gendata[:, "AF"]; Gendata_candidate[:, "AF"]]
        ]
        FOR_g = vcat(
            ("FOR" in names(Gendata)) ?
            [Float64(coalesce(v, 0.0)) for v in Gendata[:, "FOR"]] :
            fill(0.0, nrow(Gendata)),
            ("FOR" in names(Gendata_candidate)) ?
            [Float64(coalesce(v, 0.0)) for v in Gendata_candidate[:, "FOR"]] :
            fill(0.0, nrow(Gendata_candidate)),
        )
        AF_fill_map = Dict(zip(Ordered_gen_nm, AF_g_static_prefill))
        # Allow sparse AF columns: missing generator columns fallback to static AF (default 1.0).
        provided_af_cols = Set(String.(intersect(names(AFdata), Ordered_gen_nm)))
        missing_gen_af_cols = setdiff(Ordered_gen_nm, names(AFdata))
        if !isempty(missing_gen_af_cols)
            for col in missing_gen_af_cols
                AFdata[!, col] = fill(AF_fill_map[col], nrow(AFdata))
            end
            println(
                "Info: $(length(missing_gen_af_cols)) generators are missing hourly AF columns; static AF fallback will be used.",
            )
        end
        AFdata = select(AFdata, vcat(af_time_cols, Ordered_gen_nm))

        # DR related (resource-indexed)
        R = Int[]
        R_i = [Int[] for _ = 1:Num_zone]
        DR_zone_idx = Int[]
        DRC_r = Float64[]
        DR_MAX = Float64[]
        DR_CC = Float64[]
        DR_shift_eff = Float64[]
        DR_max_defer_hours = Float64[]
        if flexible_demand == 1
            DRdata = input_data["DRdata"]
            DRtsdata = input_data["DRtsdata"]
            Num_dr = nrow(DRdata)
            if Num_dr == 0
                throw(
                    ArgumentError(
                        "flexible_demand=1 but DRdata is empty. Provide at least one DR resource row in flexddata.",
                    ),
                )
            end
            R = collect(1:Num_dr)
            DR_to_float(x) = x isa Number ? Float64(x) : parse(Float64, string(x))
            zone_to_idx_str = Dict(string(k) => v for (k, v) in Zone_idx_dict)
            DR_zone_idx = Vector{Int}(undef, Num_dr)
            for r in R
                zone_label = string(DRdata[r, "Zone"])
                if !haskey(zone_to_idx_str, zone_label)
                    throw(
                        ArgumentError(
                            "DR resource row $(r) uses unknown Zone='$(zone_label)'.",
                        ),
                    )
                end
                DR_zone_idx[r] = zone_to_idx_str[zone_label]
                push!(R_i[DR_zone_idx[r]], r)
            end
            DRC_r = [DR_to_float(DRdata[r, "Cost (\$/MW)"]) for r in R]
            DR_MAX = [DR_to_float(DRdata[r, "Max Power (MW)"]) for r in R]
            DR_CC = ones(Float64, Num_dr)
            DR_shift_eff = fill(1.0, Num_dr)        # default demand shifting efficiency
            DR_max_defer_hours = fill(24.0, Num_dr) # default max defer window (hours)
            if "CC" in names(DRdata)
                DR_CC .= [DR_to_float(DRdata[r, "CC"]) for r in R]
            end
            if "Shift_Efficiency" in names(DRdata)
                DR_shift_eff .= [DR_to_float(DRdata[r, "Shift_Efficiency"]) for r in R]
            elseif "Payback_Efficiency" in names(DRdata)
                # backward compatibility
                DR_shift_eff .= [DR_to_float(DRdata[r, "Payback_Efficiency"]) for r in R]
            end
            if "Max_Defer_Hours" in names(DRdata)
                DR_max_defer_hours .= [DR_to_float(DRdata[r, "Max_Defer_Hours"]) for r in R]
            elseif "Backlog_Multiplier" in names(DRdata)
                # backward compatibility
                DR_max_defer_hours .=
                    [DR_to_float(DRdata[r, "Backlog_Multiplier"]) for r in R]
            end
            missing_dr_cols = setdiff(Ordered_zone_nm, names(DRtsdata))
            if !isempty(missing_dr_cols)
                throw(
                    ArgumentError(
                        "DR timeseries is missing zone columns: $(collect(missing_dr_cols)).",
                    ),
                )
            end
            validate_aligned_time_columns!(Loaddata, DRtsdata, "dr_timeseries_regional")
        end

        input_T, input_H_t, input_H_T, has_custom_time_periods =
            build_time_period_hours(Loaddata)
        if representative_day_mode == 0
            validate_full_chronological_time_periods(input_T)
        end
        if representative_day_mode == 1 && external_rep_day == 0 && has_custom_time_periods
            throw(
                ArgumentError(
                    "Input timeseries defines multiple Time Periods. This is only allowed when external_rep_day = 1.",
                ),
            )
        end

        # representative-day preprocessing:
        # - endogenous_rep_day=1: HOPE clusters by time_periods
        # - external_rep_day=1: use user-provided representative periods + weights
        N_external = Dict{Int,Float64}()
        rep_period_data = nothing
        storage_linkage = nothing
        if representative_day_mode == 1
            if external_rep_day == 1
                if !haskey(input_data, "RepWeightData")
                    throw(
                        ArgumentError(
                            "external_rep_day=1 requires rep_period_weights.csv (or sheet rep_period_weights).",
                        ),
                    )
                end
                rep_weight_df = input_data["RepWeightData"]
                N_external = validate_external_rep_day_inputs(
                    Loaddata,
                    AFdata,
                    rep_weight_df;
                    drtsdata = (flexible_demand == 1 ? DRtsdata : nothing),
                )
                t_vals = sort(collect(keys(N_external)))
                load_cols =
                    ("NI" in names(Loaddata)) ? [Ordered_zone_nm; "NI"] : Ordered_zone_nm
                Load_rep = Dict{Int,DataFrame}()
                AF_rep = Dict{Int,DataFrame}()
                if flexible_demand == 1
                    DR_rep = Dict{Int,DataFrame}()
                end
                for t in t_vals
                    idx_t = findall(Int.(Loaddata[!, "Time Period"]) .== t)
                    if length(idx_t) != 24
                        throw(
                            ArgumentError(
                                "Each external representative Time Period must contain exactly 24 rows. Found $(length(idx_t)) rows for Time Period=$t.",
                            ),
                        )
                    end
                    hours_t = Int.(Loaddata[idx_t, "Hours"])
                    if sort(hours_t) != collect(1:24)
                        throw(
                            ArgumentError(
                                "Hours for external representative Time Period=$t must be 1..24 exactly once. Found $(sort(hours_t)).",
                            ),
                        )
                    end
                    idx_sorted = idx_t[sortperm(hours_t)]
                    Load_rep[t] = select(Loaddata[idx_sorted, :], load_cols)
                    AF_rep[t] = select(AFdata[idx_sorted, :], Ordered_gen_nm)
                    if flexible_demand == 1
                        DR_rep[t] = select(DRtsdata[idx_sorted, :], Ordered_zone_nm)
                    end
                end
            else
                rep_period_data = build_endogenous_rep_periods(
                    Loaddata,
                    AFdata,
                    Ordered_zone_nm,
                    Ordered_gen_nm,
                    config_set;
                    drtsdata = (flexible_demand == 1 ? DRtsdata : nothing),
                    generator_data = Gendata,
                    candidate_generator_data = Gendata_candidate,
                )
                Load_rep = rep_period_data["Load_rep"]
                AF_rep = rep_period_data["AF_rep"]
                storage_linkage = get(rep_period_data, "storage_linkage", nothing)
                if flexible_demand == 1
                    DR_rep = rep_period_data["DR_rep"]
                end
            end
        else
            Load_rep = Loaddata
            if flexible_demand == 1
                DR_rep = select(DRtsdata, Ordered_zone_nm)
            end
        end
        gtep_debug_stage_log(config_set, "create_gtep_model_rep_periods_ready")

        #Sets--------------------------------------------------
        D = [d for d = 1:Num_load] #Set of demand, index d
        G = [g for g = 1:(Num_gen+Num_Cgen)]#Set of all types of generating units, index g
        K = unique(Gendata[:, "Type"]) #Set of technology types, index k
        total_hours_available = nrow(Loaddata)
        H = [h for h = 1:total_hours_available]#Set of hours, index h
        if representative_day_mode == 0 && total_hours_available != 8760
            throw(
                ArgumentError(
                    "Full chronological mode requires 8760 rows in load_timeseries_regional. Found $total_hours_available rows.",
                ),
            )
        end
        if representative_day_mode == 1
            if external_rep_day == 1
                T = sort(collect(keys(N_external)))
            else
                T = rep_period_data["T"]#Set of representative periods built from seasonal windows, index t
            end
        else
            T = input_T
        end
        S = [s for s = 1:(Num_sto+Num_Csto)]#Set of storage units, index s
        I = [i for i = 1:Num_zone]#Set of zones, index i
        # Set of DR resources R and subset mapping R_i are built from DRdata when flexible_demand=1
        J = I#Set of zones, index j
        L = [l for l = 1:(Num_Eline+Num_Cline)]#Set of transmission corridors, index l
        W = unique(Zonedata[:, "State"])#Set of states, index w/w’
        W_prime = W#Set of states, index w/w’
        # W_RPS=unique(vcat(RPSdata[:, "From_state"],RPSdata[:, "To_state"]))    #Set of states participate in RPS trading, not needed

        #SubSets------------------------------------------------
        D_i = [[d] for d in D]#Set of demand connected to zone i, a subset of D
        G_PV_E = findall(Gendata[:, "Type"] .== "SolarPV")#Set of existingsolar, subsets of G
        G_PV_C = findall(Gendata_candidate[:, "Type"] .== "SolarPV") .+ Num_gen#Set of candidate solar, subsets of G
        G_PV = [G_PV_E; G_PV_C]#Set of all solar, subsets of G
        G_W_E = findall(x -> x in ["WindOn", "WindOff"], Gendata[:, "Type"])#Set of existing wind, subsets of G
        G_W_C =
            findall(x -> x in ["WindOn", "WindOff"], Gendata_candidate[:, "Type"]) .+
            Num_gen#Set of candidate wind, subsets of G
        G_W = [G_W_E; G_W_C]                                               #Set of all wind, subsets of G
        G_VRE_E = [G_PV_E; G_W_E]
        G_VRE_C = [G_PV_C; G_W_C]
        G_VRE = [G_VRE_E; G_VRE_C]
        #G_F_E=findall(x -> x in ["Coal", "Oil", "NGCT", "NuC", "MSW", "Bio", "Landfill_NG", "NGCC"], Gendata[:,"Type"])
        #G_F_C=findall(x -> x in ["Coal", "Oil", "NGCT", "NuC", "MSW", "Bio", "Landfill_NG", "NGCC"], Gendata_candidate[:,"Type"]).+Num_gen
        G_F_E = findall(x -> x in [1], Gendata[:, "Flag_thermal"])
        G_F_C = findall(x -> x in [1], Gendata_candidate[:, "Flag_thermal"]) .+ Num_gen
        G_MR_E = findall(x -> x in [1], Gendata[:, "Flag_mustrun"])
        G_MR_C = findall(x -> x in [1], Gendata_candidate[:, "Flag_mustrun"]) .+ Num_gen
        G_F = [G_F_E; G_F_C]#Set of dispatchable generators, subsets of G
        G_MR = [G_MR_E; G_MR_C]
        if !("Flag_RPS" in names(Gendata)) || !("Flag_RPS" in names(Gendata_candidate))
            throw(
                ArgumentError(
                    "Missing required column 'Flag_RPS' in gendata/gendata_candidate for RPS eligibility.",
                ),
            )
        end
        # legacy type-based reference:
        # G_RPS_E = findall(x -> x in ["Hydro", "MSW", "Bio", "Landfill_NG", "Nuc", "NuC", "WindOn", "WindOff", "SolarPV"], Gendata[:,"Type"])
        # G_RPS_C = findall(x -> x in ["Hydro", "MSW", "Bio", "Landfill_NG", "Nuc", "NuC", "WindOn", "WindOff", "SolarPV"], Gendata_candidate[:,"Type"]).+Num_gen
        G_RPS_E = findall(x -> x in [1], Gendata[:, "Flag_RPS"])
        G_RPS_C = findall(x -> x in [1], Gendata_candidate[:, "Flag_RPS"]) .+ Num_gen
        G_RPS = [G_RPS_E; G_RPS_C]#Set of generation units providing RPS credits, index g, subset of G
        missing_vre_in_rps = setdiff(G_VRE, G_RPS)
        if !isempty(missing_vre_in_rps)
            println(
                "Warning: enforcing G_VRE ⊆ G_RPS by adding $(length(missing_vre_in_rps)) VRE units into G_RPS.",
            )
            G_RPS = sort(unique(vcat(G_RPS, missing_vre_in_rps)))
        end
        missing_vre_profile_cols =
            [Ordered_gen_nm[g] for g in G_VRE if !(Ordered_gen_nm[g] in provided_af_cols)]
        if !isempty(missing_vre_profile_cols)
            println(
                "Warning: AF timeseries missing for $(length(missing_vre_profile_cols)) VRE generators; static AF fallback will be used.",
            )
        end
        G_exist = [g for g = 1:Num_gen]#Set of existing generation units, index g, subset of G
        G_RET_raw = findall(x -> x in [1], Gendata[:, "Flag_RET"])#Set of existing generation units marked as retirement-eligible, index g, subset of G
        G_RET_conflict = intersect(G_RET_raw, G_MR_E)
        if !isempty(G_RET_conflict)
            println(
                "Warning: removing $(length(G_RET_conflict)) must-run generators from retirement set (MR units cannot be retired).",
            )
        end
        G_RET = setdiff(G_RET_raw, G_MR_E)#Set of existing generation units available for retirement, excluding must-run units
        G_new = [g for g = (Num_gen+1):(Num_gen+Num_Cgen)]#Set of candidate generation units, index g, subset of G
        G_i = [
            [
                findall(Gendata[:, "Zone"] .== Idx_zone_dict[i])
                (findall(Gendata_candidate[:, "Zone"] .== Idx_zone_dict[i]) .+ Num_gen)
            ] for i in I
        ]#Set of generating units connected to zone i, subset of G
        HD = [h for h = 1:24]
        H_D = [h for h = 0:24:total_hours_available]
        if representative_day_mode == 1#Set of hours in one day, index h, subset of H
            H_t = [collect((1+24*(t-1)):(24+24*(t-1))) for t in T]#Set of hours in time period (day) t, index h, subset of H
            H_T = collect(unique(reduce(vcat, H_t)))#Set of unique hours in time period, index h, subset of H
        else
            H_t = input_H_t
            H_T = input_H_T
        end

        S_exist = [s for s = 1:Num_sto]#Set of existing storage units, subset of S
        S_new = [s for s = (Num_sto+1):(Num_sto+Num_Csto)]#Set of candidate storage units, subset of S
        S_i = [
            [
                findall(Storagedata[:, "Zone"] .== Idx_zone_dict[i])
                (
                    findall(Estoragedata_candidate[:, "Zone"] .== Idx_zone_dict[i]) .+
                    Num_sto
                )
            ] for i in I
        ]#Set of storage units connected to zone i, subset of S
        S_new_i = [
            (findall(Estoragedata_candidate[:, "Zone"] .== Idx_zone_dict[i]) .+ Num_sto) for i in I
        ]#Set of storage units connected to zone i, subset of S
        L_exist = [l for l = 1:Num_Eline]#Set of existing transmission corridors
        L_new = [l for l = (Num_Eline+1):(Num_Eline+Num_Cline)]#Set of candidate transmission corridors
        LS_i = [
            [
                findall(Linedata[:, "From_zone"] .== Idx_zone_dict[i])
                (
                    findall(Linedata_candidate[:, "From_zone"] .== Idx_zone_dict[i]) .+
                    Num_Eline
                )
            ] for i in I
        ]#Set of sending transmission corridors of zone i, subset of L
        LR_i = [
            [
                findall(Linedata[:, "To_zone"] .== Idx_zone_dict[i])
                (
                    findall(Linedata_candidate[:, "To_zone"] .== Idx_zone_dict[i]) .+
                    Num_Eline
                )
            ] for i in I
        ]#Set of receiving transmission corridors of zone i， subset of L
        line_from_zone_idx = vcat(
            [Int(Zone_idx_dict[string(x)]) for x in Linedata[:, "From_zone"]],
            [Int(Zone_idx_dict[string(x)]) for x in Linedata_candidate[:, "From_zone"]],
        )
        line_to_zone_idx = vcat(
            [Int(Zone_idx_dict[string(x)]) for x in Linedata[:, "To_zone"]],
            [Int(Zone_idx_dict[string(x)]) for x in Linedata_candidate[:, "To_zone"]],
        )
        IL_l = Dict(
            zip(L, [[line_from_zone_idx[l], line_to_zone_idx[l]] for l in eachindex(L)]),
        )
        I_w = Dict(zip(W, [findall(Zonedata[:, "State"] .== w) for w in W]))#Set of zones in state w, subset of I
        WER_w = Dict{Any,Vector{Any}}() #Set of states that state w can export renewable credits to (excludes w itself), subset of W
        WIR_w = Dict{Any,Vector{Any}}() #Set of states that state w can import renewable credits from (excludes w itself), subset of W
        W_set = Set(W)
        for w in W
            export_targets = unique(RPSdata[RPSdata[:, "From_state"].==w, "To_state"])
            import_sources = unique(RPSdata[RPSdata[:, "To_state"].==w, "From_state"])
            WER_w[w] = [
                w_prime for
                w_prime in export_targets if (w_prime in W_set) && (w_prime != w)
            ]
            WIR_w[w] = [
                w_prime for
                w_prime in import_sources if (w_prime in W_set) && (w_prime != w)
            ]
        end

        G_L = Dict(zip([l for l in L], [G_i[i] for l in L for i in IL_l[l]]))#Set of generation units that linked to line l, index g, subset of G
        gtep_debug_stage_log(config_set, "create_gtep_model_sets_ready")

        #Parameters--------------------------------------------
        ALW = Dict(
            (Int(row["Time Period"]), row["State"]) => Float64(row["Allowance (tons)"])
            for row in eachrow(CBPdata)
        )#(t,w)														#Total carbon allowance in time period t in state w, ton
        for w in W, t in T
            if !haskey(ALW, (t, w))
                if haskey(ALW, (1, w))
                    ALW[(t, w)] = ALW[(1, w)]
                else
                    ALW[(t, w)] = 0.0
                end
            end
        end
        # Hourly generator availability AF_{g,h} (generator-level time series; fallback to static AF).
        BM = SinglePardata[1, "BigM"]#big M penalty
        CC_g = [Gendata[:, "CC"]; Gendata_candidate[:, "CC"]]#g       		#Capacity credit of generating units, unitless
        CC_s = [Storagedata[:, "CC"]; Estoragedata_candidate[:, "CC"]]#s   #Capacity credit of storage units, unitless
        AF_g_static = [
            Float64(coalesce(v, 1.0)) for
            v in [Gendata[:, "AF"]; Gendata_candidate[:, "AF"]]
        ] #Fallback static availability factor (non-VRE)
        #CP=29#g $/ton													#Carbon price of generation g〖∈G〗^F, M$/t (∑_(g∈G^F,t∈T)〖〖CP〗_g  .N_t.∑_(h∈H_t)p_(g,h) 〗)
        EF = [Gendata[:, "EF"]; Gendata_candidate[:, "EF"]]#g				#Carbon emission factor of generator g, t/MWh
        ELMT =
            Dict(zip(CBP_state_data[!, "State"], CBP_state_data[!, "Allowance (tons)_sum"]))#w							#Carbon emission limits at state w, t
        ALW_state =
            Dict(zip(CBP_state_data[!, "State"], CBP_state_data[!, "Allowance (tons)_sum"])) #w				#Total annual carbon allowances by state
        F_forward_exist, F_reverse_exist =
            parse_directional_line_limits(Linedata; context = "linedata")
        F_forward_new, F_reverse_new = parse_directional_line_limits(
            Linedata_candidate;
            context = "linedata_candidate",
        )
        F_forward = [F_forward_exist; F_forward_new]#l #Maximum positive flow from From_zone to To_zone, MW
        F_reverse = [F_reverse_exist; F_reverse_new]#l #Maximum negative-flow magnitude from To_zone to From_zone, MW
        F_abs_max = max.(F_forward, F_reverse)#l #Safe upper bound for absolute-flow loss auxiliaries
        line_loss_rate =
            [parse_line_loss_rates(Linedata); parse_line_loss_rates(Linedata_candidate)]#l
        INV_g = Dict(zip(G_new, Gendata_candidate[:, Symbol("Cost (\$/MW/yr)")])) #g						#Investment cost of candidate generator g, M$
        INV_l = Dict(zip(L_new, Linedata_candidate[:, Symbol("Cost (M\$)")]))#l						#Investment cost of transmission line l, M$
        INV_s = Dict(zip(S_new, Estoragedata_candidate[:, Symbol("Cost (\$/MW/yr)")])) #s				#Investment cost of storage unit s, M$
        IBG = SinglePardata[1, "Inv_bugt_gen"]#Total investment budget for generators
        IBL = SinglePardata[1, "Inv_bugt_line"]#Total investment budget for transmission lines
        IBS = SinglePardata[1, "Inv_bugt_storage"]#Total investment budget for storages

        NI = Dict([
            (h, i) =>
                NIdata[h] *
                (Zonedata[:, "Demand (MW)"][i] / sum(Zonedata[:, "Demand (MW)"])) for
            i in I for h in H
        ])#IH	#Net imports in zone i in h, MWh
        #NI_t = Dict([t => Dict([(i,h) =>Load_rep[t][!,"NI"][h]*(Zonedata[:,"Demand (MW)"][i]/sum(Zonedata[:,"Demand (MW)"])) for i in I for h in H_t[t]]) for t in T]) #tih
        #P=Dict([(d,h) => Loaddata[:,Idx_zone_dict[d]][h] for d in D for h in H])#d,h			#Active power demand of d in hour h, MW
        PK = Zonedata[:, "Demand (MW)"]#d												#Zone reference demand (used with per-unit load profile), MW
        PT_rps = SinglePardata[1, "PT_RPS"]#RPS volitation penalty, $/MWh
        PT_emis = SinglePardata[1, "PT_emis"]#Carbon emission volitation penalty, $/t
        singlepar_cols = Set(string.(names(SinglePardata)))
        alpha_storage_anchor =
            ("alpha_storage_anchor" in singlepar_cols) ?
            Float64(SinglePardata[1, "alpha_storage_anchor"]) : 0.5
        if !(0.0 <= alpha_storage_anchor <= 1.0)
            throw(
                ArgumentError(
                    "Invalid alpha_storage_anchor=$(alpha_storage_anchor). Expected value in [0, 1].",
                ),
            )
        end
        spin_requirement =
            ("spin_requirement" in singlepar_cols) ?
            Float64(SinglePardata[1, "spin_requirement"]) : 0.03
        if spin_requirement < 0
            throw(
                ArgumentError(
                    "Invalid spin_requirement=$(spin_requirement). Expected non-negative value (fraction of hourly load).",
                ),
            )
        end
        delta_spin =
            ("delta_spin" in singlepar_cols) ? Float64(SinglePardata[1, "delta_spin"]) :
            (10.0 / 60.0)
        if delta_spin < 0
            throw(
                ArgumentError(
                    "Invalid delta_spin=$(delta_spin). Expected non-negative value in hours.",
                ),
            )
        end
        P_min = [Gendata[:, "Pmin (MW)"]; Gendata_candidate[:, "Pmin (MW)"]]#g						#Minimum power generation of unit g, MW
        P_max = [Gendata[:, "Pmax (MW)"]; Gendata_candidate[:, "Pmax (MW)"]]#g						#Maximum power generation of unit g, MW
        to_float(x) = x isa Number ? Float64(x) : parse(Float64, string(x))
        RPS = Dict{Any,Float64}()  #w								#Renewable portfolio standard in state w, unitless
        for w in W
            rps_vals =
                unique([to_float(v) for v in RPSdata[RPSdata[:, "From_state"].==w, "RPS"]])
            if isempty(rps_vals)
                RPS[w] = 0.0
            elseif length(rps_vals) == 1
                RPS[w] = rps_vals[1]
            else
                throw(
                    ArgumentError(
                        "Inconsistent RPS values for state $(w) in RPSdata From_state rows: $(rps_vals).",
                    ),
                )
            end
        end
        if !("planning_reserve_margin" in names(SinglePardata))
            throw(
                ArgumentError(
                    "Missing planning reserve margin in single_parameter input. Expected column 'planning_reserve_margin'.",
                ),
            )
        end
        PRM = SinglePardata[1, "planning_reserve_margin"]#												#System-level planning reserve margin, unitless
        if !("Zonal PRM" in names(Zonedata))
            PRM_i = Dict(i => PRM for i in I) # fallback: zonal PRM defaults to system PRM
        else
            PRM_i = Dict(i => Float64(Zonedata[i, "Zonal PRM"]) for i in I)
        end
        SECAP = [
            Storagedata[:, "Capacity (MWh)"]
            Estoragedata_candidate[:, "Capacity (MWh)"]
        ]#s		#Maximum energy capacity of storage unit s, MWh
        SCAP =
            [Storagedata[:, "Max Power (MW)"]; Estoragedata_candidate[:, "Max Power (MW)"]]#s		#Maximum capacity of storage unit s, MWh
        SC = [Storagedata[:, "Charging Rate"]; Estoragedata_candidate[:, "Charging Rate"]]#s									#The maximum rates of charging, unitless
        SD = [
            Storagedata[:, "Discharging Rate"]
            Estoragedata_candidate[:, "Discharging Rate"]
        ]#s									#The maximum rates of discharging, unitless
        VCG = [Gencostdata; Gendata_candidate[:, Symbol("Cost (\$/MWh)")]]#g						#Variable cost of generation unit g, $/MWh
        VCS = [
            Storagedata[:, Symbol("Cost (\$/MWh)")]
            Estoragedata_candidate[:, Symbol("Cost (\$/MWh)")]
        ]#s						#Variable (degradation) cost of storage unit s, $/MWh
        VOLL = SinglePardata[1, "VOLL"]#d										#Value of loss of load d, $/MWh
        e_ch = [
            Storagedata[:, "Charging efficiency"]
            Estoragedata_candidate[:, "Charging efficiency"]
        ]#s				#Charging efficiency of storage unit s, unitless
        e_dis = [
            Storagedata[:, "Discharging efficiency"]
            Estoragedata_candidate[:, "Discharging efficiency"]
        ]#s			#Discharging efficiency of storage unit s, unitless
        # Storage duration subsets (hours = energy capacity / power capacity):
        # S_SD: short-duration storage, representative-day 50% anchoring.
        # S_LD: long-duration storage, representative-day inter-period SOC linkage.
        storage_ld_duration_hours_raw = get(config_set, "storage_ld_duration_hours", 12.0)
        storage_ld_duration_hours =
            storage_ld_duration_hours_raw isa Number ?
            Float64(storage_ld_duration_hours_raw) :
            parse(Float64, string(storage_ld_duration_hours_raw))
        if storage_ld_duration_hours < 0
            throw(
                ArgumentError(
                    "Invalid storage_ld_duration_hours=$(storage_ld_duration_hours). Expected non-negative value in hours.",
                ),
            )
        end
        StorageDurationHours =
            Dict(s => (SCAP[s] > 0 ? SECAP[s] / SCAP[s] : 0.0) for s in S)
        S_LD = [s for s in S if StorageDurationHours[s] >= storage_ld_duration_hours]
        S_SD = setdiff(S, S_LD)
        S_SD_exist = intersect(S_SD, S_exist)
        S_SD_new = intersect(S_SD, S_new)
        S_LD_exist = intersect(S_LD, S_exist)
        S_LD_new = intersect(S_LD, S_new)

        #for multiple time period, we need to use following TS parameters
        if representative_day_mode == 1
            if external_rep_day == 1
                N = N_external
            else
                N = rep_period_data["N"] #t	  #Number of time periods (days) represented by representative period t per year
            end
            #NI_t = Dict([t => Dict([(h,i) =>-Load_rep[t][!,"NI"][h]*(Zonedata[:,"Demand (MW)"][i]/sum(Zonedata[:,"Demand (MW)"])) for i in I for h in H_t[t]]) for t in T]) #tih
            NI_hi = Dict([
                (h, i) =>
                    -Load_rep[t][!, "NI"][h-24*(t-1)] *
                    (Zonedata[:, "Demand (MW)"][i] / sum(Zonedata[:, "Demand (MW)"]))
                for i in I for t in T for h in H_t[t]
            ])
            #P_t = Load_rep #thd P_t[t][h,d]*PK[d] for d in D_i[i]
            P_hd = Dict([
                (h, d) => Load_rep[t][h-24*(t-1), d] for i in I for d in D_i[i] for
                t in T for h in H_t[t]
            ])
            if flexible_demand == 1
                # DR profile is zonal in input; each resource r uses the profile of its connected zone.
                DR_hd = Dict(
                    (h, r) => DR_rep[t][h-24*(t-1), DR_zone_idx[r]] for r in R for
                    t in T for h in H_t[t]
                )
            end
            AF_gh = Dict{Tuple{Int,Int},Float64}()
            for t in T, g in G, h in H_t[t]
                v = AF_rep[t][h-24*(t-1), Ordered_gen_nm[g]]
                base_af = ismissing(v) ? AF_g_static[g] : Float64(v)
                AF_gh[(g, h)] = clamp(base_af * (1.0 - clamp(FOR_g[g], 0.0, 1.0)), 0.0, 1.0)
            end
        else
            N = Dict{Int,Float64}(t => 1.0 for t in T)
            if haskey(input_data, "RepWeightData")
                println(
                    "Info: rep_period_weights is ignored because endogenous_rep_day=0 and external_rep_day=0 (full chronology mode).",
                )
            end
            #NI_t = Dict(1=> NI)
            NI_hi = NI
            P_hd = Dict(
                (h, d) => Float64(Loaddata[h, Idx_zone_dict[d]]) for d in D for h in H_T
            )
            if flexible_demand == 1
                DR_hd = Dict((h, r) => DR_rep[h, DR_zone_idx[r]] for r in R for h in H_T)
            end
            AF_gh = Dict{Tuple{Int,Int},Float64}()
            for t in T, g in G, h in H_t[t]
                v = AFdata[h, Ordered_gen_nm[g]]
                base_af = ismissing(v) ? AF_g_static[g] : Float64(v)
                AF_gh[(g, h)] = clamp(base_af * (1.0 - clamp(FOR_g[g], 0.0, 1.0)), 0.0, 1.0)
            end
        end
        if flexible_demand == 1
            DR_DF_max = Dict((h, r) => DR_hd[h, r] * DR_MAX[r] for r in R for h in H_T)
            DR_PB_max = Dict((h, r) => DR_hd[h, r] * DR_MAX[r] for r in R for h in H_T)
            DR_DF_peak = Dict(r => maximum(DR_DF_max[h, r] for h in H_T) for r in R)
        end
        # Peak demand definitions used in planning reserve constraints
        PK_i = Dict(
            i => maximum(sum(P_hd[h, d] * PK[d] for d in D_i[i]) for h in H_T) for i in I
        )
        PK_system =
            maximum(sum(sum(P_hd[h, d] * PK[d] for d in D_i[i]) for i in I) for h in H_T)
        unit_converter = 10^6
        gtep_debug_stage_log(config_set, "create_gtep_model_parameters_ready")

        #Relax of integer variable:
        inv_dcs_bin = config_set["inv_dcs_bin"]

        local model
        try
            model = instantiate_jump_model(OPTIMIZER)
        catch err
            constructor_probe = gtep_optimizer_constructor_probe(OPTIMIZER)
            @error(
                "Failed to initialize JuMP model in create_GTEP_model",
                optimizer_diagnostics = gtep_optimizer_diagnostics(OPTIMIZER),
                optimizer_constructor_probe = constructor_probe,
                optimizer_type =
                    get(gtep_optimizer_diagnostics(OPTIMIZER), "optimizer_type", "missing"),
                optimizer_fields = get(
                    gtep_optimizer_diagnostics(OPTIMIZER),
                    "optimizer_fields",
                    "missing",
                ),
                optimizer_constructor_type =
                    get(constructor_probe, "optimizer_constructor_type", "missing"),
                optimizer_constructor_repr =
                    get(constructor_probe, "optimizer_constructor_repr", "missing"),
                optimizer_constructor_string =
                    get(constructor_probe, "optimizer_constructor_string", "missing"),
                optimizer_constructor_zero_arg_callable = get(
                    constructor_probe,
                    "optimizer_constructor_zero_arg_callable",
                    "missing",
                ),
                optimizer_constructor_direct_call_ok = get(
                    constructor_probe,
                    "optimizer_constructor_direct_call_ok",
                    "missing",
                ),
                optimizer_constructor_direct_call_error =
                    get(constructor_probe, "optimizer_constructor_direct_call_error", ""),
                exception = (err, catch_backtrace()),
            )
            rethrow()
        end
        #Variables---------------------------------------------
        if carbon_policy == 2
            @variable(model, a[G] >= 0) #Bidding carbon allowance of unit g, ton
        end
        @variable(model, f[L, H_T])#Active power in transmission corridor/line l in h from resrource g, MW
        if transmission_loss == 1
            @variable(model, f_abs[L, H_T] >= 0)#Absolute line flow used in piecewise-linear transmission loss approximation
        end
        if carbon_policy != 0
            @variable(model, em_emis[W] >= 0)#Carbon emission slack in state w, ton (active only when carbon policy is on)
        end
        @variable(model, p[G, H_T] >= 0)#Active power generation of unit g in hour h, MW
        @variable(model, p_LS[I, H_T] >= 0)#Load shedding of demand d in hour h, MW
        if clean_energy_policy == 1
            @variable(model, pw[G, W] >= 0)#Total renewable generation of unit g in state w, MWh
            @variable(model, pt_rps[W] >= 0)#Amount of energy violated RPS policy in state w, MWh
            @variable(model, pwe[G, W, W_prime] >= 0)#Renewable credits generated by unit g in state w and exported from w to w' annually, MWh
        elseif clean_energy_policy == 2
            @variable(model, pt_rps[W] >= 0)#Amount of energy violated local RPS policy in state w, MWh
        else
            @expression(model, pt_rps[w in W], 0.0)
        end
        if operation_reserve_mode == 1
            @variable(model, r_G_SPIN[G, H_T] >= 0)#SPIN reserve provided by generator g in hour h, MW
            @variable(model, r_S_SPIN[S, H_T] >= 0)#SPIN reserve provided by storage s in hour h, MW
        else
            # Keep the downstream algebra uniform without allocating one
            # reserve variable and one zero-fixing constraint per resource-hour.
            @expression(model, r_G_SPIN[g in G, h in H_T], 0.0)
            @expression(model, r_S_SPIN[s in S, h in H_T], 0.0)
        end
        if inv_dcs_bin == 1
            @variable(model, x[G_new], Bin)#Decision variable for candidate generator g, binary
            @variable(model, y[L_new], Bin)#Decision variable for candidate line l, binary
            @variable(model, z[S_new], Bin)#Decision variable for candidate storage s, binary
            @variable(model, x_RET[G_RET], Bin)#Decision variable for generator g eligible for retirement, binary
        elseif inv_dcs_bin == 0
            @variable(model, 0 <= x[G_new] <= 1)#Decision variable for candidate generator g, relax to scale 0-1
            @variable(model, 0 <= y[L_new] <= 1)#Decision variable for candidate line l, relax to scale 0-1
            @variable(model, 0 <= z[S_new] <= 1)#Decision variable for candidate storage s, relax to scale 0-1
            @variable(model, 0 <= x_RET[G_RET] <= 1)#Decision variable for generator g eligible for retirement, relax to scale 0-1
        end
        if flexible_demand == 1
            @variable(model, dr_DF[R, H_T] >= 0)#Deferred demand (load shifted out) by DR resource r, MW
            @variable(model, dr_PB[R, H_T] >= 0)#Payback demand (load shifted back) by DR resource r, MW
            @variable(model, b_DR[R, H_T] >= 0)#Backlog state variable of DR resource r, MWh
        end
        @variable(model, soc[S, H_T] >= 0)#State of charge level of storage s in hour h, MWh
        @variable(model, c[S, H_T] >= 0)#Charging power of storage s from grid in hour h, MW
        @variable(model, dc[S, H_T] >= 0)#Discharging power of storage s into grid in hour h, MW
        gtep_debug_stage_log(config_set, "create_gtep_model_variables_ready")
        #@variable(model, slack_pos[T,H_T,I]>=0)					#Slack varbale for debuging
        #@variable(model, slack_neg[T,H_T,I]>=0)					#Slack varbale for debuging
        #unregister(model, :p)

        #Temporaty constraint for debugging
        #@constraint(model, [g in G_new], x[g]==0);
        #@constraint(model, [l in L_new], y[l]==0);
        #@constraint(model, [s in S_new], z[s]==0);
        if transmission_expansion == 0 && !isempty(L_new)
            # User-facing switch to disable transmission expansion without changing line candidate data.
            @constraint(model, TxExp_off_con[l in L_new], y[l] == 0)
        end

        # Constraints --------------------------------------------
        # Constraint-ID map (aligned with docs/src/GTEP.md and Word formulation):
        # [GTEP-C1] Investment budgets (Word (2)-(4))
        # [GTEP-C2] Zonal power balance (Word (5))
        # [GTEP-C3] Transmission flow limits (Word (6)-(7))
        # [GTEP-C4] Generator operating limits + SPIN headroom (Word (8)-(12))
        # [GTEP-C5] Storage operation block (Word (13)-(21), with full-year vs representative-day variants)
        # [GTEP-C6] Planning reserve adequacy block (Word (22), mode-dependent system/zonal/off)
        # [GTEP-C7] Operating reserve block (SPIN only in GTEP; mode on/off)
        # [GTEP-C8] RPS + REC trading block using pwe (Word (23)-(26), mode-dependent on/off)
        # [GTEP-C9A/C9B/C9O] Carbon policy block (Option A / Option B / Off)
        # [GTEP-C10] Flexible demand backlog block (mode on/off)
        # [GTEP-C1] Generator investment budget
        IBG_con = @constraint(
            model,
            sum(INV_g[g] * x[g] * P_max[g] for g in G_new) <= IBG,
            base_name = "IBG_con"
        )

        # [GTEP-C1] Transmission investment budget
        IBL_con = @constraint(
            model,
            sum(unit_converter * INV_l[l] * y[l] for l in L_new) <= IBL,
            base_name = "IBL_con"
        )

        # [GTEP-C1] Storage investment budget
        IBS_con = @constraint(
            model,
            sum(INV_s[s] * z[s] * SCAP[s] for s in S_new) <= IBS,
            base_name = "IBS_con"
        )

        # [GTEP-C2] Zonal power balance (includes NI and optional DR shift term)
        if flexible_demand != 0
            @expression(
                model,
                DR_OPT[i in I, t in T, h in H_t[t]],
                sum(dr_PB[r, h] - dr_DF[r, h] for r in R_i[i])
            )
        else
            @expression(model, DR_OPT[i in I, t in T, h in H_t[t]], 0)
        end
        if transmission_loss == 1
            @expression(
                model,
                LineLoss[l in L, h in H_T],
                line_loss_rate[l] * model[:f_abs][l, h]
            )
            @expression(
                model,
                ZoneLineLoss[i in I, h in H_T],
                0.5 * sum(model[:LineLoss][l, h] for l in vcat(LS_i[i], LR_i[i]))
            )
        else
            @expression(model, ZoneLineLoss[i in I, h in H_T], 0.0)
        end
        @constraint(
            model,
            PB_con[i in I, t in T, h in H_t[t]],
            sum(p[g, h] for g in G_i[i]) + sum(dc[s, h] - c[s, h] for s in S_i[i]) -
            sum(f[l, h] for l in LS_i[i])#LS
            +
            sum(f[l, h] for l in LR_i[i])#LR
            #+ NI_t[t][h,i]
            +
            NI_hi[h, i] #net import
            #+ slack_pos[t,h,i]-slack_neg[t,h,i]
            ==
            sum(P_hd[h, d] * PK[d] for d in D_i[i]) + DR_OPT[i, t, h] - p_LS[i, h] +
            model[:ZoneLineLoss][i, h],
            base_name = "PB_con"
        )
        @expression(model, Load_system[h in H_T], sum(P_hd[h, d] * PK[d] for d in D))
        @expression(model, SPIN_requirement[h in H_T], spin_requirement * Load_system[h])
        if operation_reserve_mode == 1
            # [GTEP-C7] SPIN requirement active
            SPIN_req_con = @constraint(
                model,
                [h in H_T],
                sum(r_G_SPIN[g, h] for g in G) + sum(r_S_SPIN[s, h] for s in S) >=
                SPIN_requirement[h],
                base_name = "SPIN_req_con"
            )
        else
            println(
                "Operating reserve constraints are disabled " *
                "(operation_reserve_mode = 0); reserve variables were not created.",
            )
        end

        # [GTEP-C3] Existing line flow limits
        TLe_con = @constraint(
            model,
            [l in L_exist, t in T, h in H_t[t]],
            -F_reverse[l] <= f[l, h] <= F_forward[l],
            base_name = "TLe_con"
        )

        # [GTEP-C3] Candidate line flow limits with investment coupling
        TLn_LB_con = @constraint(
            model,
            [l in L_new, t in T, h in H_t[t]],
            -F_reverse[l] * y[l] <= f[l, h],
            base_name = "TLn_LB_con"
        )
        TLn_UB_con = @constraint(
            model,
            [l in L_new, t in T, h in H_t[t]],
            f[l, h] <= F_forward[l] * y[l],
            base_name = "TLn_UB_con"
        )
        if transmission_loss == 1
            TLAbsPos_con = @constraint(
                model,
                [l in L, h in H_T],
                model[:f_abs][l, h] >= f[l, h],
                base_name = "TLAbsPos_con"
            )
            TLAbsNeg_con = @constraint(
                model,
                [l in L, h in H_T],
                model[:f_abs][l, h] >= -f[l, h],
                base_name = "TLAbsNeg_con"
            )
            TLAbsUbExist_con = @constraint(
                model,
                [l in L_exist, h in H_T],
                model[:f_abs][l, h] <= F_abs_max[l],
                base_name = "TLAbsUbExist_con"
            )
            TLAbsUbNew_con = @constraint(
                model,
                [l in L_new, h in H_T],
                model[:f_abs][l, h] <= F_abs_max[l] * y[l],
                base_name = "TLAbsUbNew_con"
            )
        end

        # [GTEP-C4] Existing generator operating limits. Minimum output applies
        # to energy dispatch; SPIN consumes only upper-bound headroom.
        CLe_LB_con = @constraint(
            model,
            [g in setdiff(G_exist, G_RET), t in T, h in H_t[t]],
            P_min[g] <= p[g, h],
            base_name = "CLe_LB_con"
        )
        CLe_UP_con = @constraint(
            model,
            [g in setdiff(G_exist, G_RET), t in T, h in H_t[t]],
            p[g, h] + r_G_SPIN[g, h] <= P_max[g] * AF_gh[g, h],
            base_name = "CLe_UP_con"
        )
        CLe_RET_LB_con = @constraint(
            model,
            [g in G_RET, t in T, h in H_t[t]],
            P_min[g] - P_min[g] * x_RET[g] <= p[g, h],
            base_name = "CLe_RET_LB_con"
        )
        CLe_RET_UP_con = @constraint(
            model,
            [g in G_RET, t in T, h in H_t[t]],
            p[g, h] + r_G_SPIN[g, h] <=
            AF_gh[g, h] * P_max[g] - AF_gh[g, h] * P_max[g] * x_RET[g],
            base_name = "CLe_RET_UP_con"
        )
        CLe_MR_con = @constraint(
            model,
            [g in intersect(G_exist, G_MR), t in T, h in H_t[t]],
            p[g, h] == P_max[g] * AF_gh[g, h],
            base_name = "CLe_MR_con"
        )

        # [GTEP-C4] Candidate generator operating limits (energy + SPIN headroom), with must-run variant
        CLn_LB_con = @constraint(
            model,
            [g in G_new, t in T, h in H_t[t]],
            P_min[g] * x[g] <= p[g, h],
            base_name = "CLn_LB_con"
        )
        CLn_UB_con = @constraint(
            model,
            [g in G_new, t in T, h in H_t[t]],
            p[g, h] + r_G_SPIN[g, h] <= P_max[g] * x[g] * AF_gh[g, h],
            base_name = "CLn_UB_con"
        )
        CLn_MR_con = @constraint(
            model,
            [g in intersect(G_new, G_MR), t in T, h in H_t[t]],
            p[g, h] == P_max[g] * x[g] * AF_gh[g, h],
            base_name = "CLn_MR_con"
        )
        # [GTEP-C2] Load shedding bound
        LS_con = @constraint(
            model,
            [i in I, t in T, h in H_t[t]],
            0 <= p_LS[i, h] <= sum(P_hd[h, d] * PK[d] for d in D_i[i]),
            base_name = "LS_con"
        )

        ##############
        ##Renewbales##
        ##############
        # [GTEP-C4] Existing RPS-eligible generation availability
        ReAe_con = @constraint(
            model,
            [g in intersect(G_exist, G_RPS), t in T, h in H_t[t]],
            p[g, h] <= AF_gh[g, h] * P_max[g],
            base_name = "ReAe_con"
        )
        ReAe_MR_con = @constraint(
            model,
            [g in intersect(intersect(G_exist, G_MR), G_RPS), t in T, h in H_t[t]],
            p[g, h] == AF_gh[g, h] * P_max[g],
            base_name = "ReAe_MR_con"
        )
        @expression(
            model,
            RenewableCurtailExist[g in intersect(G_exist, G_RPS), t in T, h in H_t[t]],
            AF_gh[g, h] * P_max[g] - p[g, h]
        )

        # [GTEP-C4] Candidate RPS-eligible generation availability
        ReAn_con = @constraint(
            model,
            [g in intersect(G_new, G_RPS), t in T, h in H_t[t]],
            p[g, h] <= x[g] * AF_gh[g, h] * P_max[g],
            base_name = "ReAn_con"
        )
        ReAn_MR_con = @constraint(
            model,
            [g in intersect(intersect(G_new, G_MR), G_RPS), t in T, h in H_t[t]],
            p[g, h] == x[g] * AF_gh[g, h] * P_max[g],
            base_name = "ReAn_MR_con"
        )
        @expression(
            model,
            RenewableCurtailNew[g in intersect(G_new, G_RPS), t in T, h in H_t[t]],
            x[g] * AF_gh[g, h] * P_max[g] - p[g, h]
        )

        ##############
        ###Storages###
        ##############
        # [GTEP-C5] Existing storage charge limit
        ChLe_con = @constraint(
            model,
            [t in T, h in H_t[t], s in S_exist],
            c[s, h] / SC[s] <= SCAP[s],
            base_name = "ChLe_con"
        )

        # [GTEP-C5] Existing storage discharge + SPIN co-limit
        DChLe_con = @constraint(
            model,
            [t in T, h in H_t[t], s in S_exist],
            dc[s, h] + r_S_SPIN[s, h] <= SD[s] * SCAP[s],
            base_name = "DChLe_con"
        )

        # [GTEP-C5] Candidate storage charge limit
        ChLn_con = @constraint(
            model,
            [t in T, h in H_t[t], s in S_new],
            c[s, h] / SC[s] <= z[s] * SCAP[s],
            base_name = "ChLn_con"
        )

        # [GTEP-C5] Candidate storage discharge + SPIN co-limit
        DChLn_con = @constraint(
            model,
            [t in T, h in H_t[t], s in S_new],
            dc[s, h] + r_S_SPIN[s, h] <= z[s] * SD[s] * SCAP[s],
            base_name = "DChLn_con"
        )

        # [GTEP-C5] Storage SPIN deliverability over response window delta_spin
        SR_Deliver_con = @constraint(
            model,
            [t in T, h in H_t[t], s in S],
            r_S_SPIN[s, h] * delta_spin <= soc[s, h],
            base_name = "SR_Deliver_con"
        )

        # [GTEP-C5] Existing storage SOC bound
        SoCLe_con = @constraint(
            model,
            [t in T, h in H_t[t], s in S_exist],
            0 <= soc[s, h] <= SECAP[s],
            base_name = "SoCLe_con"
        )

        # [GTEP-C5] Candidate storage SOC bound
        SoCLn_ub_con = @constraint(
            model,
            [t in T, h in H_t[t], s in S_new],
            soc[s, h] <= z[s] * SECAP[s],
            base_name = "SoCLn_ub_con"
        )
        SoCLn_lb_con = @constraint(
            model,
            [t in T, h in H_t[t], s in S_new],
            0 <= soc[s, h],
            base_name = "SoCLn_lb_con"
        )
        #Stroage investment lower bound for MD
        #S_lb_con = @constraint(model, [w in ["MD"]], sum(sum(z[s]*SCAP[s] for s in S_new_i[i]) for i in I_w[w])>= 3000, base_name="S_lb_con")

        # [GTEP-C5] Storage SOC transition
        SoC_con = @constraint(
            model,
            [t in T, h in setdiff(H_t[t], [H_t[t][1]]), s in S],
            soc[s, h] == soc[s, h-1] + e_ch[s] * c[s, h] - dc[s, h] / e_dis[s],
            base_name = "SoC_con"
        )

        # [GTEP-C5] Storage boundary conditions
        if representative_day_mode == 0
            # [GTEP-C5.FY] Full-year mode: cyclic SOC wrap from last modeled hour to first hour.
            last_h = H_t[1][end]
            first_h = H_t[1][1]
            SDBe_st_con = @constraint(
                model,
                [t in T, s in S_exist, h in [last_h]],
                soc[s, first_h] ==
                soc[s, last_h] + e_ch[s] * c[s, first_h] - dc[s, first_h] / e_dis[s],
                base_name = "SDBe_st_con"
            )
            SDBn_st_con = @constraint(
                model,
                [t in T, s in S_new, h in [last_h]],
                soc[s, first_h] ==
                soc[s, last_h] + e_ch[s] * c[s, first_h] - dc[s, first_h] / e_dis[s],
                base_name = "SDBn_st_con"
            )
        else
            # [GTEP-C5.RD] Representative-day mode:
            # - S_SD: daily start/end SOC anchors at alpha_storage_anchor.
            # - S_LD: inter-period SOC linkage with wrap, no daily anchor.
            SDBe_st_con = @constraint(
                model,
                [t in T, s in S_SD_exist],
                soc[s, H_t[t][1]] == alpha_storage_anchor * SECAP[s],
                base_name = "SDBe_st_con"
            )
            SDBe_ed_con = @constraint(
                model,
                [t in T, s in S_SD_exist],
                soc[s, H_t[t][end]] == alpha_storage_anchor * SECAP[s],
                base_name = "SDBe_ed_con"
            )
            SDBn_st_con = @constraint(
                model,
                [t in T, s in S_SD_new],
                soc[s, H_t[t][1]] == alpha_storage_anchor * z[s] * SECAP[s],
                base_name = "SDBn_st_con"
            )
            SDBn_ed_con = @constraint(
                model,
                [t in T, s in S_SD_new],
                soc[s, H_t[t][end]] == alpha_storage_anchor * z[s] * SECAP[s],
                base_name = "SDBn_ed_con"
            )
            use_storage_linkage =
                storage_linkage !== nothing &&
                haskey(storage_linkage, "predecessors") &&
                !isempty(storage_linkage["predecessors"])
            if use_storage_linkage
                storage_predecessors = storage_linkage["predecessors"]
                storage_predecessor_weight = storage_linkage["predecessor_weight"]
                SDBe_ld_linked_con = @constraint(
                    model,
                    [t in T, s in S_LD_exist],
                    soc[s, H_t[t][1]] ==
                    sum(
                        storage_predecessor_weight[(tp, t)] * soc[s, H_t[tp][end]] for
                        tp in storage_predecessors[t]
                    ) + e_ch[s] * c[s, H_t[t][1]] - dc[s, H_t[t][1]] / e_dis[s],
                    base_name = "SDBe_ld_linked_con"
                )
                SDBn_ld_linked_con = @constraint(
                    model,
                    [t in T, s in S_LD_new],
                    soc[s, H_t[t][1]] ==
                    sum(
                        storage_predecessor_weight[(tp, t)] * soc[s, H_t[tp][end]] for
                        tp in storage_predecessors[t]
                    ) + e_ch[s] * c[s, H_t[t][1]] - dc[s, H_t[t][1]] / e_dis[s],
                    base_name = "SDBn_ld_linked_con"
                )
            else
                T_first = T[1]
                T_last = T[end]
                T_follow = length(T) > 1 ? T[2:end] : Int[]
                SDBe_ld_wrap_con = @constraint(
                    model,
                    [s in S_LD_exist],
                    soc[s, H_t[T_first][1]] ==
                    soc[s, H_t[T_last][end]] + e_ch[s] * c[s, H_t[T_first][1]] -
                    dc[s, H_t[T_first][1]] / e_dis[s],
                    base_name = "SDBe_ld_wrap_con"
                )
                SDBe_ld_link_con = @constraint(
                    model,
                    [t in T_follow, s in S_LD_exist],
                    soc[s, H_t[t][1]] ==
                    soc[s, H_t[t-1][end]] + e_ch[s] * c[s, H_t[t][1]] -
                    dc[s, H_t[t][1]] / e_dis[s],
                    base_name = "SDBe_ld_link_con"
                )
                SDBn_ld_wrap_con = @constraint(
                    model,
                    [s in S_LD_new],
                    soc[s, H_t[T_first][1]] ==
                    soc[s, H_t[T_last][end]] + e_ch[s] * c[s, H_t[T_first][1]] -
                    dc[s, H_t[T_first][1]] / e_dis[s],
                    base_name = "SDBn_ld_wrap_con"
                )
                SDBn_ld_link_con = @constraint(
                    model,
                    [t in T_follow, s in S_LD_new],
                    soc[s, H_t[t][1]] ==
                    soc[s, H_t[t-1][end]] + e_ch[s] * c[s, H_t[t][1]] -
                    dc[s, H_t[t][1]] / e_dis[s],
                    base_name = "SDBn_ld_link_con"
                )
            end
        end



        ##############
        #Planning Rsv#
        ##############
        # [GTEP-C6] Planning reserve adequacy (mode switch)
        # planning_reserve_mode:
        # 0 -> disable planning reserve constraints
        # 1 -> enforce one system-level reserve adequacy constraint
        # 2 -> enforce zonal reserve adequacy constraints
        if flexible_demand == 1
            @expression(
                model,
                DR_RA_i[i in I],
                sum(DR_CC[r] * DR_DF_peak[r] for r in R_i[i])
            )
        else
            @expression(model, DR_RA_i[i in I], 0)
        end
        @expression(model, DR_RA_system, sum(DR_RA_i[i] for i in I))
        if planning_reserve_mode == 1
            # [GTEP-C6.A] System-level adequacy
            RA_con = @constraint(
                model,
                sum(CC_g[g] * P_max[g] for g in setdiff(G_exist, G_RET)) +
                sum(CC_g[g] * P_max[g] * (1 - x_RET[g]) for g in G_RET) +
                sum(CC_g[g] * P_max[g] * x[g] for g in G_new) +
                sum(CC_s[s] * SCAP[s] for s in S_exist) +
                sum(CC_s[s] * SCAP[s] * z[s] for s in S_new) +
                DR_RA_system >= (1 + PRM) * PK_system,
                base_name = "RA_con"
            )
        elseif planning_reserve_mode == 2
            # [GTEP-C6.B] Zonal adequacy
            RA_zone_con = @constraint(
                model,
                [i in I],
                sum(
                    CC_g[g] * P_max[g] for g in setdiff(intersect(G_exist, G_i[i]), G_RET)
                ) +
                sum(CC_g[g] * P_max[g] * (1 - x_RET[g]) for g in intersect(G_RET, G_i[i])) +
                sum(CC_g[g] * P_max[g] * x[g] for g in intersect(G_new, G_i[i])) +
                sum(CC_s[s] * SCAP[s] for s in intersect(S_exist, S_i[i])) +
                sum(CC_s[s] * SCAP[s] * z[s] for s in intersect(S_new, S_i[i])) +
                DR_RA_i[i] >= (1 + PRM_i[i]) * PK_i[i],
                base_name = "RA_zone_con"
            )
        else
            println(
                "Planning reserve constraints are disabled (planning_reserve_mode = 0).",
            )
        end
        ##############
        ##RPSPolicies##
        ##############
        if clean_energy_policy == 1
            # [GTEP-C8.1] State-level renewable generation accounting
            RPS_pw_con = @constraint(
                model,
                [w in W, g in intersect(union([G_i[i] for i in I_w[w]]...), G_RPS)],
                pw[g, w] == sum(N[t] * sum(p[g, h] for h in H_t[t]) for t in T),
                base_name = "RPS_pw_con"
            )


            # [GTEP-C8.2] REC export feasibility (pwe from w to w')
            RPS_expt_con = @constraint(
                model,
                [w in W, g in intersect(union([G_i[i] for i in I_w[w]]...), G_RPS)],
                pw[g, w] >= sum(pwe[g, w, w_prime] for w_prime in WER_w[w]),
                base_name = "RPS_expt_con"
            )

            # [GTEP-C8.3] REC import feasibility (pwe from w' to w)
            RPS_impt_con = @constraint(
                model,
                [
                    w in W,
                    w_prime in WIR_w[w],
                    g in intersect(union([G_i[i] for i in I_w[w_prime]]...), G_RPS),
                ],
                pw[g, w_prime] >= pwe[g, w_prime, w],
                base_name = "RPS_impt_con"
            )

            # [GTEP-C8.4] State RPS balance with REC trading and slack
            RPS_con = @constraint(
                model,
                [w in W],
                sum(
                    pw[g, w] for g in intersect(union([G_i[i] for i in I_w[w]]...), G_RPS)
                ) + sum(
                    pwe[g, w_prime, w] for w_prime in WIR_w[w] for
                    g in intersect(union([G_i[i] for i in I_w[w_prime]]...), G_RPS)
                ) - sum(
                    pwe[g, w, w_prime] for w_prime in WER_w[w] for
                    g in intersect(union([G_i[i] for i in I_w[w]]...), G_RPS)
                ) + pt_rps[w] >= sum(
                    N[t] * sum(
                        sum(P_hd[h, d] * PK[d] * RPS[w] for d in D_i[i]) for i in I_w[w] for
                        h in H_t[t]
                    ) for t in T
                ),
                base_name = "RPS_con"
            )
        elseif clean_energy_policy == 2
            # [GTEP-C8L] Local annual RPS without REC-trading variables.
            RPS_local_con = @constraint(
                model,
                [w in W],
                sum(
                    N[t] * sum(p[g, h] for h in H_t[t]) for
                    g in intersect(union([G_i[i] for i in I_w[w]]...), G_RPS) for t in T
                ) + pt_rps[w] >= sum(
                    N[t] * sum(
                        sum(P_hd[h, d] * PK[d] * RPS[w] for d in D_i[i]) for i in I_w[w] for
                        h in H_t[t]
                    ) for t in T
                ),
                base_name = "RPS_local_con"
            )
        else
            println(
                "Clean-energy policy constraints are disabled " *
                "(clean_energy_policy = 0); RPS variables were not created.",
            )
        end

        ###############
        #CarbonPolicies#
        ###############
        @expression(
            model,
            StateCarbonEmission[w in W],
            sum(
                sum(
                    N[t] *
                    sum(EF[g] * p[g, h] for g in intersect(G_F, G_i[i]) for h in H_t[t]) for
                    t in T
                ) for i in I_w[w]
            )
        )
        if carbon_policy == 2
            # [GTEP-C9B.1] Option B: state allowance cap
            SCAL_con = @constraint(
                model,
                [w in W],
                sum(a[g] for g in intersect(union([G_i[i] for i in I_w[w]]...), G_F)) <= get(ALW_state, w, 0.0),
                base_name = "SCAL_con"
            )
            # [GTEP-C9B.2] Option B: allowances + slack cover annual emissions
            BAL_con = @constraint(
                model,
                [w in W],
                StateCarbonEmission[w] <=
                sum(a[g] for g in intersect(union([G_i[i] for i in I_w[w]]...), G_F)) + em_emis[w],
                base_name = "BAL_con"
            )
        elseif carbon_policy == 1
            # [GTEP-C9A] Option A: state annual emission cap with slack
            CL_con = @constraint(
                model,
                [w in W],
                StateCarbonEmission[w] <= ELMT[w] + em_emis[w],
                base_name = "CL_con"
            )
        else
            # [GTEP-C9O] Carbon policy off: no carbon-policy constraints
            println("Carbon policy constraints are disabled (carbon_policy = 0).")
        end

        if flexible_demand == 1
            # [GTEP-C10] Flexible demand backlog formulation
            DR_backlog_con = @constraint(
                model,
                [r in R, t in T, h in setdiff(H_t[t], [H_t[t][1]])],
                b_DR[r, h] == b_DR[r, h-1] + dr_DF[r, h] - DR_shift_eff[r] * dr_PB[r, h],
                base_name = "DR_backlog_con"
            )
            DR_backlog_start_con = @constraint(
                model,
                [r in R, t in T],
                b_DR[r, H_t[t][1]] == 0,
                base_name = "DR_backlog_start_con"
            )
            DR_backlog_end_con = @constraint(
                model,
                [r in R, t in T],
                b_DR[r, H_t[t][end]] == 0,
                base_name = "DR_backlog_end_con"
            )
            DR_df_con = @constraint(
                model,
                [r in R, t in T, h in H_t[t]],
                dr_DF[r, h] <= DR_DF_max[h, r],
                base_name = "DR_df_con"
            )
            DR_pb_con = @constraint(
                model,
                [r in R, t in T, h in H_t[t]],
                dr_PB[r, h] <= DR_PB_max[h, r],
                base_name = "DR_pb_con"
            )
            DR_backlog_cap_con = @constraint(
                model,
                [r in R, h in H_T],
                b_DR[r, h] <= DR_max_defer_hours[r] * DR_DF_peak[r],
                base_name = "DR_backlog_cap_con"
            )
        end
        gtep_debug_stage_log(config_set, "create_gtep_model_constraints_ready")
        #Objective function and solve--------------------------
        #Investment cost of generator, lines, and storages
        @expression(
            model,
            INVCost,
            sum(INV_g[g] * x[g] * P_max[g] for g in G_new) +
            sum(unit_converter * INV_l[l] * y[l] for l in L_new) +
            sum(INV_s[s] * z[s] * SCAP[s] for s in S_new)
        )
        @expression(model, INVCost_gen, sum(INV_g[g] * x[g] * P_max[g] for g in G_new))
        @expression(
            model,
            INVCost_line,
            sum(unit_converter * INV_l[l] * y[l] for l in L_new)
        )
        @expression(model, INVCost_storage, sum(INV_s[s] * z[s] * SCAP[s] for s in S_new))

        #Operation cost of generator and storages
        @expression(
            model,
            OPCost,
            sum(VCG[g] * N[t] * sum(p[g, h] for h in H_t[t]) for g in G for t in T) + sum(
                VCS[s] * N[t] * sum(c[s, h] + dc[s, h] for h in H_t[t]) for s in S for
                t in T
            )
        )
        #Loss of load penalty
        @expression(
            model,
            LoadShedding,
            sum(VOLL * N[t] * sum(p_LS[i, h] for h in H_t[t]) for i in I for t in T)
        )

        #RPS volitation penalty
        if clean_energy_policy in [1, 2]
            @expression(model, RPSPenalty, PT_rps * sum(pt_rps[w] for w in W))
        else
            @expression(model, RPSPenalty, 0)
        end
        #VRE curtailments
        VRE_CT = @expression(
            model,
            [g in G_VRE, t in T, h in H_t[t]],
            (g in G_new ? x[g] : 1.0) * AF_gh[g, h] * P_max[g] - p[g, h]
        )

        #Carbon cap volitation penalty
        if carbon_policy == 0
            @expression(model, CarbonCapPenalty, 0)
        else
            @expression(model, CarbonCapPenalty, PT_emis * sum(em_emis[w] for w in W))
        end
        @expression(
            model,
            CarbonEmission[w in W],
            sum(
                N[t] * EF[g] * p[g, h] for
                g in intersect(union([G_i[i] for i in I_w[w]]...), G_F) for t in T for
                h in H_t[t]
            )
        )
        #Slack variable penalty
        #@expression(model, SlackPenalty, sum(BM * N[t]*sum(slack_pos[t,h,i]+slack_neg[t,h,i] for h in H_t[t] for i in I) for t in T))

        #Minmize objective fuction: INVCost + OPCost + RPSPenalty + CarbonCapPenalty + SlackPenalty
        if flexible_demand != 0
            @expression(
                model,
                DR_OPcost,
                sum(
                    N[t] *
                    sum(DRC_r[r] * (dr_DF[r, h] + dr_PB[r, h]) for h in H_t[t] for r in R)
                    for t in T
                )
            )
        else
            @expression(model, DR_OPcost, 0)
        end
        @objective(
            model,
            Min,
            INVCost + OPCost + DR_OPcost + LoadShedding + RPSPenalty + CarbonCapPenalty
        )#+ SlackPenalty
        gtep_debug_stage_log(config_set, "create_gtep_model_objective_ready")
        return model
    end
end
