using CSV
using DataFrames
using YAML

@testset "Non-mutating solver selection" begin
    @test HOPE._effective_solver_name(Dict("solver" => "HiGHS"), nothing) == "highs"
    @test HOPE._effective_solver_name(Dict("solver" => "highs"), " Gurobi ") == "gurobi"
    @test_throws ArgumentError HOPE._effective_solver_name(Dict("solver" => "highs"), " ")
end

@testset "Holistic coverage uses retained runtime metrics" begin
    result = Dict{String,Any}(
        "transfer_summary" => Dict("retired_generation_mw" => 10.0),
        "gtep_activity" => Dict("gtep_termination_status" => "OPTIMAL"),
        "pcm_activity" => Dict("pcm_termination_status" => "OPTIMAL"),
        "pcm_transfer_activity" => Dict(
            "pcm_new_generation_dispatch_mwh" => 25.0,
            "pcm_upgraded_line_flow_above_source_mw" => 5.0,
        ),
        "source_gtep_hashes_before" => Dict("a" => "1"),
        "source_gtep_hashes_after" => Dict("a" => "1"),
        "source_pcm_hashes_before" => Dict("b" => "2"),
        "source_pcm_hashes_after" => Dict("b" => "2"),
    )
    metrics = HOPE.holistic_coverage_metrics(result)
    @test metrics["pcm_new_generation_dispatch_mwh"] == 25.0
    @test metrics["pcm_upgraded_line_flow_above_source_mw"] == 5.0
    @test metrics["source_gtep_unchanged"]
    @test metrics["source_pcm_unchanged"]
end

@testset "Auditable holistic linkage" begin
    @testset "Retirement transfer preserves legacy row identity" begin
        source = DataFrame(
            :Zone => ["Z1"],
            :Type => ["NGCC"],
            Symbol("Pmax (MW)") => [100.0],
            Symbol("Pmin (MW)") => [20.0],
            :Flag_RET => [1],
            :Flag_mustrun => [0],
            :Flag_VRE => [0],
            :Flag_thermal => [1],
        )
        target = copy(source)
        capacity = DataFrame(
            :Technology => ["NGCC"],
            :Zone => ["Z1"],
            :EC_Category => ["Existing"],
            Symbol("Capacity_INI (MW)") => [100.0],
            Symbol("Capacity_RET (MW)") => [40.0],
            Symbol("Capacity_FIN (MW)") => [60.0],
        )
        updated = Dict{String,Any}("Gendata" => target)
        audit = HOPE.apply_gtep_retirements!(
            updated,
            Dict("capacity" => capacity),
            Dict{String,Any}("Gendata" => source),
            Dict("resource_aggregation" => 0),
        )

        @test updated["Gendata"][1, Symbol("Pmax (MW)")] == 60.0
        @test updated["Gendata"][1, Symbol("Pmin (MW)")] == 12.0
        @test audit.MappingMode == ["validated_row"]
        @test audit.RetiredMW == [40.0]
    end

    @testset "Optional Asset_ID survives row reordering" begin
        source = DataFrame(
            :Asset_ID => ["A", "B"],
            :Zone => ["Z1", "Z1"],
            :Type => ["NGCC", "NGCT"],
            Symbol("Pmax (MW)") => [100.0, 200.0],
            Symbol("Pmin (MW)") => [20.0, 10.0],
        )
        target = source[[2, 1], :]
        capacity = DataFrame(
            :EC_Category => ["Existing", "Existing"],
            Symbol("Capacity_INI (MW)") => [100.0, 200.0],
            Symbol("Capacity_RET (MW)") => [50.0, 0.0],
            Symbol("Capacity_FIN (MW)") => [50.0, 200.0],
        )
        updated = Dict{String,Any}("Gendata" => target)
        audit = HOPE.apply_gtep_retirements!(
            updated,
            Dict("capacity" => capacity),
            Dict{String,Any}("Gendata" => source),
            Dict("resource_aggregation" => 0),
        )

        a_row = findfirst(==("A"), updated["Gendata"].Asset_ID)
        @test updated["Gendata"][a_row, Symbol("Pmax (MW)")] == 50.0
        @test audit.MappingMode == ["asset_id"]
        @test audit.AssetID == ["A"]
    end

    @testset "Candidate operating parameters are retained" begin
        candidates = DataFrame(
            :Zone => ["Z1"],
            :Type => ["NGCC"],
            Symbol("Pmax (MW)") => [100.0],
            Symbol("Pmin (MW)") => [20.0],
            :RU => [0.45],
            :RD => [0.35],
            :Flag_UC => [1],
            :Min_up_time => [4],
            :Min_down_time => [3],
            Symbol("Start_up_cost (\$/MW)") => [9.0],
            :Candidate_ID => ["GEN_C1"],
            :Operational_Template_ID => ["CC_TEMPLATE"],
        )
        output = DataFrame(
            :EC_Category => ["Candidate"],
            :New_Build => [1.0],
            Symbol("Capacity_FIN (MW)") => [50.0],
        )
        pcm = DataFrame(
            :Zone => String[],
            :Type => String[],
            Symbol("Pmax (MW)") => Float64[],
            Symbol("Pmin (MW)") => Float64[],
            :RU => Float64[],
            :RD => Float64[],
            :Flag_UC => Int[],
            :Min_up_time => Int[],
            :Min_down_time => Int[],
            Symbol("Start_up_cost (\$/MW)") => Float64[],
        )
        rows, audit = HOPE.realize_generation_builds(output, candidates, pcm)

        @test rows[1, Symbol("Pmax (MW)")] == 50.0
        @test rows[1, Symbol("Pmin (MW)")] == 10.0
        @test rows.RU == [0.45]
        @test rows.Flag_UC == [1]
        @test rows.Asset_ID == ["GEN_C1__UNIT_001"]
        @test audit.OperationalTemplateID == ["CC_TEMPLATE"]
        @test audit.RealizationMode == ["aggregate_row"]
    end

    @testset "Aggregate generation builds can become fixed physical units" begin
        candidates = DataFrame(
            :Zone => ["Z1"],
            :Type => ["NGCC"],
            Symbol("Pmax (MW)") => [100.0],
            Symbol("Pmin (MW)") => [20.0],
            :Flag_UC => [0],
            :Candidate_ID => ["GEN_FIXED"],
            :PCM_Unit_Size_MW => [100.0],
        )
        output = DataFrame(
            :EC_Category => ["Candidate"],
            :New_Build => [1.0],
            Symbol("Capacity_FIN (MW)") => [250.0],
        )
        pcm = DataFrame(
            :Asset_ID => String[],
            :Zone => String[],
            :Type => String[],
            Symbol("Pmax (MW)") => Float64[],
            Symbol("Pmin (MW)") => Float64[],
            :Flag_UC => Int[],
        )

        rows, audit = HOPE.realize_generation_builds(output, candidates, pcm)
        @test rows[!, Symbol("Pmax (MW)")] == [100.0, 100.0, 50.0]
        @test rows[!, Symbol("Pmin (MW)")] == [20.0, 20.0, 10.0]
        @test rows.Asset_ID ==
              ["GEN_FIXED__UNIT_001", "GEN_FIXED__UNIT_002", "GEN_FIXED__UNIT_003"]
        @test !("PCM_Unit_Size_MW" in names(rows))
        @test audit.RealizedUnitSequence == [1, 2, 3]
        @test all(==("fixed_unit_size"), audit.RealizationMode)
        @test sum(audit.BuiltMW) == 250.0

        candidates.Flag_UC .= 1
        @test_throws ArgumentError HOPE.realize_generation_builds(output, candidates, pcm)
        output[1, Symbol("Capacity_FIN (MW)")] = 200.0
        exact_rows, _ = HOPE.realize_generation_builds(output, candidates, pcm)
        @test exact_rows[!, Symbol("Pmax (MW)")] == [100.0, 100.0]

        pcm_with_collision = vcat(
            pcm,
            DataFrame(
                :Asset_ID => ["GEN_FIXED__UNIT_001"],
                :Zone => ["Z1"],
                :Type => ["NGCC"],
                Symbol("Pmax (MW)") => [1.0],
                Symbol("Pmin (MW)") => [0.0],
                :Flag_UC => [1],
            ),
        )
        @test_throws ArgumentError HOPE.realize_generation_builds(
            output,
            candidates,
            pcm_with_collision,
        )
    end

    @testset "Aggregate retirements use explicit physical allocation policies" begin
        raw = DataFrame(
            :Asset_ID => ["U100", "U060", "U040"],
            :Zone => fill("Z1", 3),
            :Type => fill("NGCC", 3),
            Symbol("Pmax (MW)") => [100.0, 60.0, 40.0],
            Symbol("Pmin (MW)") => [20.0, 12.0, 8.0],
            :Flag_RET => ones(Int, 3),
            :Flag_mustrun => zeros(Int, 3),
            :Flag_VRE => zeros(Int, 3),
            :Flag_thermal => ones(Int, 3),
            :Retirement_Priority => [3.0, 1.0, 2.0],
        )
        aggregate = DataFrame(
            :Asset_ID => ["AGG_NGCC"],
            :Zone => ["Z1"],
            :Type => ["NGCC"],
            Symbol("Pmax (MW)") => [200.0],
            Symbol("Pmin (MW)") => [40.0],
            :Flag_RET => [1],
            :Flag_mustrun => [0],
            :Flag_VRE => [0],
            :Flag_thermal => [1],
        )
        capacity = DataFrame(
            :EC_Category => ["Existing"],
            Symbol("Capacity_INI (MW)") => [200.0],
            Symbol("Capacity_RET (MW)") => [100.0],
            Symbol("Capacity_FIN (MW)") => [100.0],
        )
        gtep_input = Dict{String,Any}("Gendata" => aggregate, "GendataRaw" => raw)
        config = Dict("resource_aggregation" => 1)

        function realized_with(method; partial_unit_policy = "allow_capacity_reduction")
            updated =
                Dict{String,Any}("Gendata" => copy(aggregate), "GendataRaw" => copy(raw))
            audit = HOPE.apply_gtep_retirements!(
                updated,
                Dict("capacity" => capacity),
                gtep_input,
                config,
                Dict(
                    "retirement_realization" => Dict(
                        "method" => method,
                        "priority_column" => "Retirement_Priority",
                        "partial_unit_policy" => partial_unit_policy,
                    ),
                ),
            )
            return updated, audit
        end

        proportional, _ = realized_with("proportional_capacity")
        @test proportional["GendataRaw"][!, Symbol("Pmax (MW)")] == [50.0, 30.0, 20.0]

        largest, largest_audit = realized_with("largest_first")
        @test largest["GendataRaw"][!, Symbol("Pmax (MW)")] == [0.0, 60.0, 40.0]
        @test "aggregate_largest_first" in largest_audit.MappingMode

        smallest, _ = realized_with("smallest_first")
        @test smallest["GendataRaw"][!, Symbol("Pmax (MW)")] == [100.0, 0.0, 0.0]

        priority, _ = realized_with("priority")
        @test priority["GendataRaw"][!, Symbol("Pmax (MW)")] == [100.0, 0.0, 0.0]

        partial_capacity = copy(capacity)
        partial_capacity[1, Symbol("Capacity_RET (MW)")] = 50.0
        partial_capacity[1, Symbol("Capacity_FIN (MW)")] = 150.0
        @test_throws ArgumentError HOPE.apply_gtep_retirements!(
            Dict{String,Any}("Gendata" => copy(aggregate), "GendataRaw" => copy(raw)),
            Dict("capacity" => partial_capacity),
            gtep_input,
            config,
            Dict(
                "retirement_realization" =>
                    Dict("method" => "largest_first", "partial_unit_policy" => "reject"),
            ),
        )
    end

    @testset "Storage candidate parameters are retained" begin
        candidates = DataFrame(
            :Zone => ["Z1"],
            :Type => ["Battery"],
            Symbol("Capacity (MWh)") => [100.0],
            Symbol("Max Power (MW)") => [25.0],
            Symbol("Charging efficiency") => [0.91],
            Symbol("Discharging efficiency") => [0.89],
            Symbol("Charging Rate") => [0.8],
            Symbol("Discharging Rate") => [0.7],
            :Candidate_ID => ["STO_C1"],
            :Operational_Template_ID => ["BATTERY_TEMPLATE"],
        )
        output = DataFrame(
            :EC_Category => ["Candidate"],
            :New_Build => [1.0],
            Symbol("Capacity (MW)") => [15.0],
            Symbol("EnergyCapacity (MWh)") => [60.0],
        )
        pcm = DataFrame(
            :Zone => String[],
            :Type => String[],
            Symbol("Capacity (MWh)") => Float64[],
            Symbol("Max Power (MW)") => Float64[],
            Symbol("Charging efficiency") => Float64[],
            Symbol("Discharging efficiency") => Float64[],
            Symbol("Charging Rate") => Float64[],
            Symbol("Discharging Rate") => Float64[],
        )
        rows, audit = HOPE.realize_storage_builds(output, candidates, pcm)

        @test rows[1, Symbol("Capacity (MWh)")] == 60.0
        @test rows[1, Symbol("Max Power (MW)")] == 15.0
        @test rows[1, Symbol("Charging efficiency")] == 0.91
        @test rows[1, Symbol("Discharging Rate")] == 0.7
        @test rows.Asset_ID == ["STO_C1__UNIT_001"]
        @test audit.OperationalTemplateID == ["BATTERY_TEMPLATE"]
    end

    @testset "Parallel corridors are allocated without silent loss" begin
        lines = DataFrame(
            :From_zone => ["A", "B"],
            :To_zone => ["B", "A"],
            Symbol("Forward Capacity (MW)") => [100.0, 300.0],
            Symbol("Reverse Capacity (MW)") => [50.0, 150.0],
        )
        builds = DataFrame(
            :From_zone => ["A"],
            :To_zone => ["B"],
            Symbol("Forward Capacity (MW)") => [40.0],
            Symbol("Reverse Capacity (MW)") => [20.0],
        )
        updated, audit = HOPE.apply_line_builds_with_audit!(copy(lines), builds)

        logical_forward_before =
            lines[1, Symbol("Forward Capacity (MW)")] +
            lines[2, Symbol("Reverse Capacity (MW)")]
        logical_forward_after =
            updated[1, Symbol("Forward Capacity (MW)")] +
            updated[2, Symbol("Reverse Capacity (MW)")]
        logical_reverse_before =
            lines[1, Symbol("Reverse Capacity (MW)")] +
            lines[2, Symbol("Forward Capacity (MW)")]
        logical_reverse_after =
            updated[1, Symbol("Reverse Capacity (MW)")] +
            updated[2, Symbol("Forward Capacity (MW)")]
        @test logical_forward_after - logical_forward_before ≈ 40.0
        @test logical_reverse_after - logical_reverse_before ≈ 20.0
        @test nrow(audit) == 2
        @test all(audit.MappingMode .== "proportional_parallel_corridor")
        @test_throws ArgumentError HOPE.apply_line_builds_with_audit!(
            copy(lines),
            builds;
            network_model = 2,
        )
        missing_build = copy(builds)
        missing_build.From_zone .= "X"
        @test_throws ArgumentError HOPE.apply_line_builds_with_audit!(
            copy(lines),
            missing_build,
        )
    end

    @testset "Legacy cases need no new identity columns" begin
        existing = DataFrame(
            :Zone => ["Z1"],
            :Type => ["NGCC"],
            Symbol("Pmax (MW)") => [100.0],
            Symbol("Pmin (MW)") => [20.0],
            Symbol("Cost (\$/MWh)") => [30.0],
            :EF => [0.4],
            :CC => [1.0],
            :FOR => [0.05],
            :RM_SPIN => [0.1],
            :RU => [0.5],
            :RD => [0.5],
            :Flag_thermal => [1],
            :Flag_VRE => [0],
            :Flag_mustrun => [0],
        )
        candidate = DataFrame(
            :Zone => ["Z1"],
            :Type => ["SolarPV"],
            Symbol("Pmax (MW)") => [100.0],
            Symbol("Pmin (MW)") => [0.0],
            Symbol("Cost (\$/MWh)") => [0.0],
            :EF => [0.0],
            :CC => [0.3],
            :FOR => [0.0],
            :RM_SPIN => [0.0],
            :RU => [1.0],
            :RD => [1.0],
            :Flag_thermal => [0],
            :Flag_VRE => [1],
            :Flag_mustrun => [0],
        )
        empty_storage = DataFrame(
            :Zone => String[],
            :Type => String[],
            Symbol("Capacity (MWh)") => Float64[],
            Symbol("Max Power (MW)") => Float64[],
            Symbol("Charging efficiency") => Float64[],
            Symbol("Discharging efficiency") => Float64[],
            Symbol("Cost (\$/MWh)") => Float64[],
            :EF => Float64[],
            :CC => Float64[],
            Symbol("Charging Rate") => Float64[],
            Symbol("Discharging Rate") => Float64[],
        )
        empty_lines = DataFrame(
            :From_zone => String[],
            :To_zone => String[],
            Symbol("Forward Capacity (MW)") => Float64[],
            Symbol("Reverse Capacity (MW)") => Float64[],
        )
        gtep_input = Dict{String,Any}(
            "Gendata" => copy(existing),
            "Gendata_candidate" => candidate,
            "Estoragedata_candidate" => DataFrame(
                :Zone => String[],
                :Type => String[],
                Symbol("Capacity (MWh)") => Float64[],
                Symbol("Max Power (MW)") => Float64[],
            ),
            "Linedata_candidate" => copy(empty_lines),
        )
        gtep_output = Dict{String,Any}(
            "capacity" => DataFrame(
                :Technology => ["NGCC", "SolarPV"],
                :Zone => ["Z1", "Z1"],
                :EC_Category => ["Existing", "Candidate"],
                :New_Build => [0.0, 1.0],
                Symbol("Capacity_INI (MW)") => [100.0, 0.0],
                Symbol("Capacity_RET (MW)") => [20.0, 0.0],
                Symbol("Capacity_FIN (MW)") => [80.0, 50.0],
            ),
            "es_capacity" => DataFrame(
                :EC_Category => String[],
                :New_Build => Float64[],
                Symbol("Capacity (MW)") => Float64[],
                Symbol("EnergyCapacity (MWh)") => Float64[],
            ),
            "line" => DataFrame(
                :New_Build => Float64[],
                :From_zone => String[],
                :To_zone => String[],
                Symbol("Forward Capacity (MW)") => Float64[],
                Symbol("Reverse Capacity (MW)") => Float64[],
            ),
        )
        pcm_input = Dict{String,Any}(
            "Gendata" => copy(existing),
            "Storagedata" => empty_storage,
            "Linedata" => empty_lines,
        )
        pcm_config =
            Dict("resource_aggregation" => 0, "unit_commitment" => 0, "network_model" => 1)
        updated = HOPE.prepare_pcm_inputs_from_gtep_linked(
            gtep_output,
            gtep_input,
            Dict("resource_aggregation" => 0),
            pcm_input,
            pcm_config,
        )

        @test nrow(updated["Gendata"]) == 2
        @test updated["Gendata"][1, Symbol("Pmax (MW)")] == 80.0
        @test updated["Gendata"][2, Symbol("Pmax (MW)")] == 50.0
        @test haskey(updated, "LinkageAudit")

        mktempdir() do tmpdir
            paths = HOPE.persist_realized_pcm_inputs_for_holistic(
                tmpdir,
                merge(copy(pcm_config), Dict("DataCase" => "Data")),
                updated,
            )
            @test isfile(paths["gendata"])
            @test isfile(paths["retirements_audit"])
            @test isfile(paths["manifest"])
            @test occursin("GTEP-PCM", read(paths["manifest"], String))
        end
    end

    @testset "Bus-basis topology validates a nodal PCM twin" begin
        time_data = DataFrame(
            Symbol("Time Period") => [1],
            :Month => [1],
            :Day => [1],
            :Hours => [1],
            :B1 => [10.0],
            :B2 => [20.0],
        )
        gtep_input = Dict{String,Any}(
            "Zonedata" => DataFrame(:Zone_id => ["B1", "B2"]),
            "Loaddata" => copy(time_data),
            "Gendata" => DataFrame(:Zone => ["B1"]),
            "Storagedata" => DataFrame(:Zone => String[]),
            "Linedata" => DataFrame(:From_zone => ["B1"], :To_zone => ["B2"]),
        )
        pcm_input = Dict{String,Any}(
            "Zonedata" => DataFrame(:Zone_id => ["Z1", "Z2"]),
            "Busdata" => DataFrame(:Bus_id => ["B1", "B2"], :Zone_id => ["Z1", "Z2"]),
            "NodalLoaddata" => copy(time_data),
            "Gendata" => DataFrame(:Zone => ["Z1"], :Bus_id => ["B1"]),
            "Storagedata" => DataFrame(:Zone => String[], :Bus_id => String[]),
            "Linedata" => DataFrame(:From_zone => ["Z1"], :To_zone => ["Z2"]),
            "Branchdata" => DataFrame(
                :From_zone => ["Z1"],
                :To_zone => ["Z2"],
                :from_bus => ["B1"],
                :to_bus => ["B2"],
            ),
        )
        gtep_config = Dict("model_mode" => "GTEP", "holistic_spatial_basis" => "bus")
        pcm_config = Dict("model_mode" => "PCM", "holistic_spatial_basis" => "auto")
        @test isnothing(
            HOPE.validate_holistic_case_pair!(
                "gtep",
                gtep_config,
                gtep_input,
                "pcm",
                pcm_config,
                pcm_input,
            ),
        )
    end

    @testset "Nodal builds realize at buses and update branchdata" begin
        existing = DataFrame(
            :Asset_ID => ["EXISTING_1"],
            :Zone => ["B1"],
            :Bus_id => ["B1"],
            :Type => ["NGCC"],
            Symbol("Pmax (MW)") => [100.0],
            Symbol("Pmin (MW)") => [20.0],
            Symbol("Cost (\$/MWh)") => [30.0],
            :EF => [0.4],
            :CC => [1.0],
            :AF => [1.0],
            :FOR => [0.05],
            :RM_SPIN => [0.1],
            :RU => [1.0],
            :RD => [1.0],
            :Flag_thermal => [1],
            :Flag_VRE => [0],
            :Flag_mustrun => [0],
        )
        candidate = DataFrame(
            :Candidate_ID => ["GEN_B2"],
            :Zone => ["B2"],
            :Bus_id => ["B2"],
            :Type => ["SolarPV"],
            Symbol("Pmax (MW)") => [100.0],
            Symbol("Pmin (MW)") => [0.0],
            Symbol("Cost (\$/MWh)") => [0.0],
            :EF => [0.0],
            :CC => [0.3],
            :AF => [1.0],
            :FOR => [0.0],
            :RM_SPIN => [0.0],
            :RU => [1.0],
            :RD => [1.0],
            :Flag_thermal => [0],
            :Flag_VRE => [1],
            :Flag_mustrun => [0],
        )
        empty_storage = DataFrame(
            :Zone => String[],
            :Bus_id => String[],
            :Type => String[],
            Symbol("Capacity (MWh)") => Float64[],
            Symbol("Max Power (MW)") => Float64[],
            Symbol("Charging efficiency") => Float64[],
            Symbol("Discharging efficiency") => Float64[],
            Symbol("Cost (\$/MWh)") => Float64[],
            :EF => Float64[],
            :CC => Float64[],
            Symbol("Charging Rate") => Float64[],
            Symbol("Discharging Rate") => Float64[],
        )
        line_candidate = DataFrame(
            :From_zone => ["B1"],
            :To_zone => ["B2"],
            Symbol("Forward Capacity (MW)") => [40.0],
            Symbol("Reverse Capacity (MW)") => [20.0],
            :Corridor_ID => ["C1"],
        )
        gtep_input = Dict{String,Any}(
            "Gendata" => existing,
            "Gendata_candidate" => candidate,
            "Estoragedata_candidate" => empty_storage,
            "Linedata_candidate" => line_candidate,
        )
        gtep_output = Dict{String,Any}(
            "capacity" => DataFrame(
                :EC_Category => ["Existing", "Candidate"],
                :New_Build => [0.0, 1.0],
                Symbol("Capacity_INI (MW)") => [100.0, 0.0],
                Symbol("Capacity_RET (MW)") => [0.0, 0.0],
                Symbol("Capacity_FIN (MW)") => [100.0, 60.0],
            ),
            "es_capacity" => DataFrame(
                :EC_Category => String[],
                :New_Build => Float64[],
                Symbol("Capacity (MW)") => Float64[],
                Symbol("EnergyCapacity (MWh)") => Float64[],
            ),
            "line" => DataFrame(
                :New_Build => [1.0],
                :From_zone => ["B1"],
                :To_zone => ["B2"],
                Symbol("Forward Capacity (MW)") => [40.0],
                Symbol("Reverse Capacity (MW)") => [20.0],
            ),
        )
        pcm_existing = copy(existing)
        pcm_existing.Zone .= "Z1"
        branch = DataFrame(
            :From_zone => ["Z1"],
            :To_zone => ["Z2"],
            :from_bus => ["B1"],
            :to_bus => ["B2"],
            Symbol("Forward Capacity (MW)") => [100.0],
            Symbol("Reverse Capacity (MW)") => [100.0],
            :Corridor_ID => ["C1"],
        )
        pcm_input = Dict{String,Any}(
            "Gendata" => pcm_existing,
            "Storagedata" => empty_storage,
            "Linedata" => DataFrame(
                :From_zone => ["Z1"],
                :To_zone => ["Z2"],
                Symbol("Forward Capacity (MW)") => [10.0],
                Symbol("Reverse Capacity (MW)") => [10.0],
            ),
            "Branchdata" => branch,
            "Busdata" => DataFrame(:Bus_id => ["B1", "B2"], :Zone_id => ["Z1", "Z2"]),
        )
        pcm_config = Dict(
            "resource_aggregation" => 0,
            "unit_commitment" => 0,
            "network_model" => 2,
            "DataCase" => "Data",
        )
        updated = HOPE.prepare_pcm_inputs_from_gtep_linked(
            gtep_output,
            gtep_input,
            Dict("resource_aggregation" => 0),
            pcm_input,
            pcm_config,
        )
        @test updated["Gendata"][2, "Zone"] == "Z2"
        @test updated["Gendata"][2, "Bus_id"] == "B2"
        @test updated["Branchdata"][1, Symbol("Forward Capacity (MW)")] == 140.0
        @test updated["Branchdata"][1, Symbol("Reverse Capacity (MW)")] == 120.0
        @test updated["Linedata"][1, Symbol("Forward Capacity (MW)")] == 10.0
        mktempdir() do tmpdir
            paths =
                HOPE.persist_realized_pcm_inputs_for_holistic(tmpdir, pcm_config, updated)
            @test isfile(paths["branchdata"])
        end
    end

    @testset "Aggregated line decisions can target explicit PCM branches" begin
        branches = DataFrame(
            :From_zone => ["Z1"],
            :To_zone => ["Z2"],
            :from_bus => ["B1"],
            :to_bus => ["B2"],
            Symbol("Forward Capacity (MW)") => [100.0],
            Symbol("Reverse Capacity (MW)") => [80.0],
            :Corridor_ID => ["C1"],
        )
        builds = DataFrame(
            :From_zone => ["Z1"],
            :To_zone => ["Z2"],
            :PCM_from_bus => ["B1"],
            :PCM_to_bus => ["B2"],
            Symbol("Forward Capacity (MW)") => [25.0],
            Symbol("Reverse Capacity (MW)") => [15.0],
            :Corridor_ID => ["C1"],
        )
        updated, audit =
            HOPE.apply_line_builds_with_audit!(branches, builds; network_model = 2)
        @test updated[1, Symbol("Forward Capacity (MW)")] == 125.0
        @test updated[1, Symbol("Reverse Capacity (MW)")] == 95.0
        @test audit.MappingMode == ["corridor_id"]
    end

    @testset "Holistic acceptance settings and thresholds are machine readable" begin
        metrics = Dict{String,Any}(
            "retired_generation_mw" => 20.0,
            "pcm_load_shedding_mwh" => 0.0,
        )
        expectations = Dict{String,Any}(
            "required_settings" => Dict(
                "gtep" => Dict("inv_dcs_bin" => 1),
                "pcm" => Dict("network_model" => 2),
            ),
            "thresholds" => Dict(
                "retired_generation_mw" => Dict("minimum" => 19.0),
                "pcm_load_shedding_mwh" => Dict("maximum" => 1.0e-6),
            ),
        )
        checks = HOPE._holistic_acceptance_checks(
            metrics,
            Dict("inv_dcs_bin" => 1),
            Dict("network_model" => 2),
            expectations,
        )
        @test nrow(checks) == 4
        @test all(checks.Passed)
        metrics["retired_generation_mw"] = 0.0
        failed = HOPE._holistic_acceptance_checks(
            metrics,
            Dict("inv_dcs_bin" => 1),
            Dict("network_model" => 2),
            expectations,
        )
        @test !all(failed.Passed)
    end
end

@testset "Holistic transfer reconciliation" begin
    source_pcm = Dict{String,Any}(
        "Gendata" => DataFrame(
            :Asset_ID => ["A", "B"],
            :Zone => ["Z1", "Z1"],
            :Type => ["Thermal", "Wind"],
            Symbol("Pmax (MW)") => [100.0, 50.0],
            Symbol("Pmin (MW)") => [20.0, 0.0],
        ),
        "Storagedata" => DataFrame(
            :Asset_ID => ["S1"],
            Symbol("Max Power (MW)") => [10.0],
            Symbol("Capacity (MWh)") => [40.0],
        ),
        "Linedata" => DataFrame(
            :From_zone => ["Z1"],
            :To_zone => ["Z2"],
            Symbol("Forward Capacity (MW)") => [100.0],
            Symbol("Reverse Capacity (MW)") => [80.0],
        ),
    )
    updated_pcm = deepcopy(source_pcm)
    updated_pcm["Gendata"] = DataFrame(
        :Asset_ID => ["A", "B", "C__UNIT_001"],
        :Zone => ["Z1", "Z1", "Z2"],
        :Type => ["Thermal", "Wind", "Thermal"],
        Symbol("Pmax (MW)") => [60.0, 50.0, 30.0],
        Symbol("Pmin (MW)") => [12.0, 0.0, 6.0],
    )
    updated_pcm["Storagedata"] = DataFrame(
        :Asset_ID => ["S1", "S2__UNIT_001"],
        Symbol("Max Power (MW)") => [10.0, 5.0],
        Symbol("Capacity (MWh)") => [40.0, 20.0],
    )
    updated_pcm["Linedata"] = DataFrame(
        :From_zone => ["Z1"],
        :To_zone => ["Z2"],
        Symbol("Forward Capacity (MW)") => [110.0],
        Symbol("Reverse Capacity (MW)") => [95.0],
    )
    updated_pcm["LinkageAudit"] = Dict{String,Any}(
        "retirements" => DataFrame(Layer = ["model"], RetiredMW = [40.0]),
        "generation_builds" => DataFrame(BuiltMW = [30.0]),
        "storage_builds" => DataFrame(BuiltPowerMW = [5.0], BuiltEnergyMWh = [20.0]),
        "line_allocations" => DataFrame(
            CandidateRow = [1],
            ForwardAddedMW = [10.0],
            ReverseAddedMW = [15.0],
        ),
    )
    gtep_input = Dict{String,Any}(
        "Gendata_candidate" => DataFrame(Candidate_ID = ["C"]),
        "Estoragedata_candidate" => DataFrame(Candidate_ID = ["S2"]),
        "Linedata_candidate" => DataFrame(Corridor_ID = ["L1"]),
    )
    gtep_output = Dict{String,Any}(
        "capacity" => DataFrame(
            :EC_Category => ["Existing", "Existing", "Candidate"],
            Symbol("Capacity_INI (MW)") => [100.0, 50.0, 30.0],
            Symbol("Capacity_RET (MW)") => [40.0, 0.0, 0.0],
            Symbol("Capacity_FIN (MW)") => [60.0, 50.0, 30.0],
            :New_Build => [0.0, 0.0, 1.0],
        ),
        "es_capacity" => DataFrame(
            :EC_Category => ["Candidate"],
            :New_Build => [1.0],
            Symbol("Capacity (MW)") => [5.0],
            Symbol("EnergyCapacity (MWh)") => [20.0],
        ),
        "line" => DataFrame(
            :EC_Category => ["Candidate"],
            :New_Build => [1.0],
            Symbol("Forward Capacity (MW)") => [10.0],
            Symbol("Reverse Capacity (MW)") => [15.0],
        ),
    )
    pcm_config = Dict("network_model" => 1, "resource_aggregation" => 0)

    report = validate_holistic_transfer_reconciliation(
        gtep_output,
        gtep_input,
        source_pcm,
        updated_pcm,
        pcm_config,
    )
    @test report["valid"]
    @test all(report["checks"].Passed)
    @test report["metrics"]["realized_generation_capacity_mw"] == 140.0
    @test HOPE._holistic_numeric_total(
        DataFrame(Symbol("Max Power (MW)") => Union{Missing,Float64}[]),
        "Max Power (MW)",
    ) == 0.0

    broken = deepcopy(updated_pcm)
    broken["Gendata"][1, Symbol("Pmax (MW)")] = 61.0
    failed = validate_holistic_transfer_reconciliation(
        gtep_output,
        gtep_input,
        source_pcm,
        broken,
        pcm_config;
        require_valid = false,
    )
    @test !failed["valid"]
    @test "table.generation_capacity_conservation" in
          failed["checks"].Check[.!failed["checks"].Passed]
    @test_throws ArgumentError validate_holistic_transfer_reconciliation(
        gtep_output,
        gtep_input,
        source_pcm,
        broken,
        pcm_config,
    )

    duplicate = deepcopy(updated_pcm)
    duplicate["Gendata"][3, :Asset_ID] = "A"
    identity = validate_holistic_transfer_reconciliation(
        gtep_output,
        gtep_input,
        source_pcm,
        duplicate,
        pcm_config;
        require_valid = false,
    )
    @test !only(
        identity["checks"].Passed[identity["checks"].Check.=="identity.generator_asset_ids"],
    )

    mktempdir() do output_path
        paths = HOPE.persist_realized_pcm_inputs_for_holistic(
            output_path,
            pcm_config,
            updated_pcm;
            transfer_reconciliation = report,
        )
        @test isfile(paths["transfer_reconciliation"])
        @test isfile(paths["transfer_reconciliation_checks"])
        @test YAML.load_file(paths["transfer_reconciliation"])["valid"]
        manifest = YAML.load_file(paths["manifest"])
        @test manifest["transfer_reconciliation"]["valid"]
    end
end
