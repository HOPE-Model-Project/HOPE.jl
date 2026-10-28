using HOPE
using Test
using CSV
using DataFrames
using YAML

function _computed_handoff_fixture()
    generation = DataFrame(
        :Candidate_ID => ["GEN_SOLAR", "GEN_NGCC"],
        :Planning_Zone => ["Z1", "Z1"],
        :Zone => ["Z1", "Z1"],
        :Type => ["SolarPV", "NGCC"],
        :Bus_id => ["B1", "B1"],
        :Operational_Template_ID => ["SOLAR_TEMPLATE", "NGCC_TEMPLATE"],
        Symbol("Pmax (MW)") => [100.0, 80.0],
        Symbol("Pmin (MW)") => [0.0, 16.0],
        :Flag_thermal => [0, 1],
        :Flag_UC => [0, 1],
    )
    storage = DataFrame(
        :Candidate_ID => ["STOR_BATTERY"],
        :Planning_Zone => ["Z1"],
        :Zone => ["Z1"],
        :Type => ["Battery"],
        :Bus_id => ["B1"],
        :Operational_Template_ID => ["BATTERY_TEMPLATE"],
        Symbol("Max Power (MW)") => [40.0],
        Symbol("Capacity (MWh)") => [160.0],
    )
    gtep_input =
        Dict("Gendata_candidate" => generation, "Estoragedata_candidate" => storage)
    capacity = DataFrame(
        :Technology => ["Existing", "SolarPV", "NGCC"],
        :Zone => ["Z1", "Z1", "Z1"],
        :EC_Category => ["Existing", "Candidate", "Candidate"],
        :New_Build => [false, true, true],
        Symbol("Capacity_INI (MW)") => [25.0, 0.0, 0.0],
        Symbol("Capacity_RET (MW)") => [0.0, 0.0, 0.0],
        Symbol("Capacity_FIN (MW)") => [25.0, 100.0, 80.0],
        :Candidate_ID => [missing, "GEN_SOLAR", "GEN_NGCC"],
    )
    es_capacity = DataFrame(
        :Technology => ["Battery"],
        :Zone => ["Z1"],
        :EC_Category => ["Candidate"],
        :New_Build => [true],
        Symbol("Capacity (MW)") => [40.0],
        Symbol("EnergyCapacity (MWh)") => [160.0],
        :Candidate_ID => ["STOR_BATTERY"],
    )
    gtep_output = Dict("capacity" => capacity, "es_capacity" => es_capacity)
    return gtep_output, gtep_input
end

function _computed_contract_test_policy()
    return Dict{String,Any}(
        "schema_version" => 1,
        "artifact_type" => "HOPE.realization_policy",
        "method" => "constrained_site_allocate_v1",
        "solver" => "highs",
        "tolerance_mw" => 1e-6,
        "minimum_allocation_mw" => 0.0,
        "tie_break_epsilon" => 1e-9,
        "variant_order" => ["balanced_baseline"],
        "weights" => Dict(
            "site_cost" => 1.0,
            "network_stress" => 1.0,
            "resource_quality" => 1.0,
            "brownfield" => 1.0,
            "evidence_quality" => 0.0,
            "fragmentation" => 0.0,
        ),
        "variants" => Dict("balanced_baseline" => Dict{String,Any}()),
    )
end

@testset "Computed realization GTEP/PCM handoff" begin
    gtep_output, gtep_input = _computed_handoff_fixture()

    @testset "Solved GTEP output becomes a capacity plan" begin
        plan = HOPE.capacity_plan_from_gtep(gtep_output, gtep_input)
        @test plan.Plan_Item_ID == ["GEN_NGCC", "GEN_SOLAR", "STOR_BATTERY"]
        @test sum(plan.Build_MW) == 220.0
        @test sum(plan.Build_MWh) == 160.0
        @test plan[plan.Plan_Item_ID.=="STOR_BATTERY", :].Resource_Kind == ["storage"]
    end

    @testset "Candidate catalog uses reviewed topology proxies" begin
        pcm_generation = DataFrame(
            :Zone => ["Z1", "Z1"],
            :Bus_id => ["B1", "B2"],
            Symbol("Pmax (MW)") => [120.0, 60.0],
        )
        busdata = DataFrame(
            :Bus_id => ["B1", "B2", "B3"],
            :Zone_id => ["Z1", "Z1", "Z1"],
            :Latitude => [39.0, 39.1, 39.2],
            :Longitude => [-77.0, -77.1, -77.2],
        )
        branches = DataFrame(
            :from_bus => ["B1", "B2"],
            :to_bus => ["B2", "B3"],
            Symbol("Forward Capacity (MW)") => [500.0, 200.0],
            Symbol("Reverse Capacity (MW)") => [500.0, 200.0],
        )
        catalog = HOPE.build_candidate_site_catalog_from_pcm(
            gtep_input["Gendata_candidate"],
            gtep_input["Estoragedata_candidate"],
            pcm_generation,
            busdata;
            branchdata = branches,
            sites_per_zone = 2,
        )
        @test nrow(catalog) == 6
        @test Set(catalog.Bus_id) == Set(["B1", "B2"])
        @test all(catalog.Network_Screen_Passed)
        @test all(catalog.Resource_Quality_Score .== 0.5)
        @test all(occursin.("topology screen", catalog.Evidence_Source))
        @test allunique(catalog.Candidate_Site_ID)
    end

    @testset "Selected allocation materializes into the existing handoff" begin
        plan = HOPE.capacity_plan_from_gtep(gtep_output, gtep_input)
        catalog = DataFrame(
            Candidate_Site_ID = ["NG_B1", "NG_B2", "SOL_B1", "SOL_B2", "BAT_B1", "BAT_B2"],
            Site_ID = ["B1", "B2", "B1", "B2", "B1", "B2"],
            Bus_id = ["B1", "B2", "B1", "B2", "B1", "B2"],
            Resource_Kind = [
                "generation",
                "generation",
                "generation",
                "generation",
                "storage",
                "storage",
            ],
            Zone = fill("Z1", 6),
            Type = ["NGCC", "NGCC", "SolarPV", "SolarPV", "Battery", "Battery"],
            Candidate_Max_MW = [40.0, 80.0, 60.0, 100.0, 20.0, 40.0],
            Candidate_Max_MWh = [missing, missing, missing, missing, 80.0, 160.0],
            Site_Cost = [0.0, 1.0, 0.0, 1.0, 0.0, 1.0],
            Network_Stress_Score = zeros(6),
            Resource_Quality_Score = fill(0.5, 6),
            Existing_Site = [true, false, true, false, true, false],
        )
        policy = Dict{String,Any}(
            "schema_version" => 1,
            "artifact_type" => "HOPE.realization_policy",
            "method" => "constrained_site_allocate_v1",
            "solver" => "highs",
            "tolerance_mw" => 1e-6,
            "minimum_allocation_mw" => 0.0,
            "tie_break_epsilon" => 1e-9,
            "variant_order" => ["balanced_baseline"],
            "weights" => Dict(
                "site_cost" => 1.0,
                "network_stress" => 1.0,
                "resource_quality" => 1.0,
                "brownfield" => 1.0,
                "evidence_quality" => 0.0,
                "fragmentation" => 0.0,
            ),
            "variants" => Dict("balanced_baseline" => Dict{String,Any}()),
        )
        realization = HOPE.compute_nodal_realizations(plan, catalog, policy)
        materialized = HOPE.materialize_computed_realization_handoff(
            gtep_output,
            gtep_input,
            realization["allocations"];
            variant = "balanced_baseline",
        )
        adapted_input = materialized["gtep_input"]
        adapted_output = materialized["gtep_output"]
        @test nrow(adapted_input["Gendata_candidate"]) == 4
        @test nrow(adapted_input["Estoragedata_candidate"]) == 2
        @test sum(
            adapted_output["capacity"][
                adapted_output["capacity"].EC_Category.=="Candidate",
                Symbol("Capacity_FIN (MW)"),
            ],
        ) == 180.0
        @test sum(adapted_output["es_capacity"][!, Symbol("Capacity (MW)")]) == 40.0
        @test sum(adapted_output["es_capacity"][!, Symbol("EnergyCapacity (MWh)")]) == 160.0
        @test allunique(materialized["audit"].MaterializedCandidateID)

        pcm_generation = DataFrame(
            :Zone => ["Z1"],
            :Type => ["NGCC"],
            :Bus_id => ["B1"],
            :Asset_ID => ["EXISTING"],
            Symbol("Pmax (MW)") => [10.0],
            Symbol("Pmin (MW)") => [0.0],
        )
        realized_generation, generation_audit = HOPE.realize_generation_builds(
            adapted_output["capacity"],
            adapted_input["Gendata_candidate"],
            pcm_generation,
        )
        pcm_storage = DataFrame(
            :Zone => String[],
            :Type => String[],
            :Bus_id => String[],
            :Asset_ID => String[],
            Symbol("Capacity (MWh)") => Float64[],
            Symbol("Max Power (MW)") => Float64[],
        )
        realized_storage, storage_audit = HOPE.realize_storage_builds(
            adapted_output["es_capacity"],
            adapted_input["Estoragedata_candidate"],
            pcm_storage,
        )
        @test isapprox(sum(realized_generation[!, Symbol("Pmax (MW)")]), 180.0)
        @test isapprox(sum(realized_storage[!, Symbol("Max Power (MW)")]), 40.0)
        @test isapprox(sum(realized_storage[!, Symbol("Capacity (MWh)")]), 160.0)
        @test sum(generation_audit.BuiltMW) == 180.0
        @test sum(storage_audit.BuiltPowerMW) == 40.0
    end

    @testset "Contract activation and pre-PCM fast screens" begin
        plan = HOPE.capacity_plan_from_gtep(gtep_output, gtep_input)
        catalog = DataFrame(
            Candidate_Site_ID = ["NG_B1", "SOL_B1", "BAT_B1"],
            Site_ID = fill("B1", 3),
            Bus_id = fill("B1", 3),
            Resource_Kind = ["generation", "generation", "storage"],
            Zone = fill("Z1", 3),
            Type = ["NGCC", "SolarPV", "Battery"],
            Candidate_Max_MW = [80.0, 100.0, 40.0],
            Candidate_Max_MWh = [missing, missing, 160.0],
            Existing_Site = fill(true, 3),
            Network_Stress_Score = zeros(3),
            Resource_Quality_Score = fill(0.5, 3),
            Site_Cost = zeros(3),
        )
        pcm_input = Dict(
            "Busdata" => DataFrame(Bus_id = ["B1"], Zone_id = ["Z1"]),
            "Branchdata" => DataFrame(
                :from_bus => ["B1"],
                :to_bus => ["B2"],
                Symbol("Forward Capacity (MW)") => [500.0],
                Symbol("Reverse Capacity (MW)") => [500.0],
            ),
        )
        mktempdir() do directory
            catalog_path = joinpath(directory, "catalog.csv")
            policy_path = joinpath(directory, "policy.yml")
            CSV.write(catalog_path, catalog)
            YAML.write_file(policy_path, _computed_contract_test_policy())
            contract = Dict{String,Any}(
                "resource_siting" => Dict(
                    "generation" => Dict("method" => "computed_allocation"),
                    "storage" => Dict("method" => "computed_allocation"),
                ),
                "computed_realization" => Dict(
                    "candidate_site_catalog" => basename(catalog_path),
                    "realization_policy" => basename(policy_path),
                    "selected_variant" => "balanced_baseline",
                    "fast_screen" => Dict("require_pass" => true),
                ),
            )
            bundle = HOPE.build_computed_realization_handoff_from_contract(
                gtep_output,
                gtep_input,
                pcm_input,
                contract,
                directory,
            )
            @test bundle["active"]
            @test bundle["fast_screen"]["valid"]
            @test nrow(bundle["fast_screen"]["checks"]) == 4
            @test bundle["fast_screen"]["summary"]["allocated_mw"] == sum(plan.Build_MW)
            strict = HOPE.screen_computed_realization(
                bundle["realization"]["allocations"],
                pcm_input;
                variant = "balanced_baseline",
                max_allocation_to_incident_rating_ratio = 0.1,
            )
            @test !strict["valid"]
            @test any(
                (strict["checks"].Check .== "allocation_to_incident_rating") .&
                .!strict["checks"].Passed,
            )
            updated = Dict{String,Any}(
                "Gendata" => DataFrame(),
                "Storagedata" => DataFrame(),
                "Linedata" => DataFrame(),
                "LinkageAudit" => Dict{String,Any}(
                    "computed_realization" => bundle["materialization_audit"],
                    "computed_fast_screen" => bundle["fast_screen"]["checks"],
                ),
                "ComputedRealization" => Dict{String,Any}(
                    "specification" => bundle["specification"],
                    "capacity_plan" => bundle["capacity_plan"],
                    "allocations" => bundle["realization"]["allocations"],
                    "screening" => bundle["realization"]["screening"],
                    "summary" => bundle["realization"]["summary"],
                    "fast_screen" => bundle["fast_screen"],
                ),
            )
            output_directory = joinpath(directory, "persisted")
            paths = HOPE.persist_realized_pcm_inputs_for_holistic(
                output_directory,
                Dict("resource_aggregation" => 0, "DataCase" => "Data"),
                updated,
            )
            @test isfile(paths["computed_capacity_plan"])
            @test isfile(paths["computed_nodal_allocations"])
            @test YAML.load_file(paths["computed_realization"])["fast_screen_valid"]
        end
    end
end
