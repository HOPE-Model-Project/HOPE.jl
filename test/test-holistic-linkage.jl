using CSV
using DataFrames

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

        logical_forward_before = lines[1, Symbol("Forward Capacity (MW)")] +
                                 lines[2, Symbol("Reverse Capacity (MW)")]
        logical_forward_after = updated[1, Symbol("Forward Capacity (MW)")] +
                                updated[2, Symbol("Reverse Capacity (MW)")]
        logical_reverse_before = lines[1, Symbol("Reverse Capacity (MW)")] +
                                 lines[2, Symbol("Forward Capacity (MW)")]
        logical_reverse_after = updated[1, Symbol("Reverse Capacity (MW)")] +
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
        @test_throws ArgumentError HOPE.apply_line_builds_with_audit!(copy(lines), missing_build)
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
        pcm_config = Dict(
            "resource_aggregation" => 0,
            "unit_commitment" => 0,
            "network_model" => 1,
        )
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
        pcm_config = Dict("model_mode" => "PCM", "holistic_spatial_basis" => "bus")
        @test isnothing(HOPE.validate_holistic_case_pair!(
            "gtep",
            gtep_config,
            gtep_input,
            "pcm",
            pcm_config,
            pcm_input,
        ))
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
            :EF => [0.4], :CC => [1.0], :AF => [1.0], :FOR => [0.05],
            :RM_SPIN => [0.1], :RU => [1.0], :RD => [1.0],
            :Flag_thermal => [1], :Flag_VRE => [0], :Flag_mustrun => [0],
        )
        candidate = DataFrame(
            :Candidate_ID => ["GEN_B2"],
            :Zone => ["B2"],
            :Bus_id => ["B2"],
            :Type => ["SolarPV"],
            Symbol("Pmax (MW)") => [100.0],
            Symbol("Pmin (MW)") => [0.0],
            Symbol("Cost (\$/MWh)") => [0.0],
            :EF => [0.0], :CC => [0.3], :AF => [1.0], :FOR => [0.0],
            :RM_SPIN => [0.0], :RU => [1.0], :RD => [1.0],
            :Flag_thermal => [0], :Flag_VRE => [1], :Flag_mustrun => [0],
        )
        empty_storage = DataFrame(
            :Zone => String[], :Bus_id => String[], :Type => String[],
            Symbol("Capacity (MWh)") => Float64[],
            Symbol("Max Power (MW)") => Float64[],
            Symbol("Charging efficiency") => Float64[],
            Symbol("Discharging efficiency") => Float64[],
            Symbol("Cost (\$/MWh)") => Float64[],
            :EF => Float64[], :CC => Float64[],
            Symbol("Charging Rate") => Float64[],
            Symbol("Discharging Rate") => Float64[],
        )
        line_candidate = DataFrame(
            :From_zone => ["B1"], :To_zone => ["B2"],
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
                :EC_Category => String[], :New_Build => Float64[],
                Symbol("Capacity (MW)") => Float64[],
                Symbol("EnergyCapacity (MWh)") => Float64[],
            ),
            "line" => DataFrame(
                :New_Build => [1.0],
                :From_zone => ["B1"], :To_zone => ["B2"],
                Symbol("Forward Capacity (MW)") => [40.0],
                Symbol("Reverse Capacity (MW)") => [20.0],
            ),
        )
        pcm_existing = copy(existing)
        pcm_existing.Zone .= "Z1"
        branch = DataFrame(
            :From_zone => ["Z1"], :To_zone => ["Z2"],
            :from_bus => ["B1"], :to_bus => ["B2"],
            Symbol("Forward Capacity (MW)") => [100.0],
            Symbol("Reverse Capacity (MW)") => [100.0],
            :Corridor_ID => ["C1"],
        )
        pcm_input = Dict{String,Any}(
            "Gendata" => pcm_existing,
            "Storagedata" => empty_storage,
            "Linedata" => DataFrame(
                :From_zone => ["Z1"], :To_zone => ["Z2"],
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
            paths = HOPE.persist_realized_pcm_inputs_for_holistic(tmpdir, pcm_config, updated)
            @test isfile(paths["branchdata"])
        end
    end
end
