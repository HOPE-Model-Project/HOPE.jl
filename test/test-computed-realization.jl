using HOPE
using Test
using CSV
using DataFrames
using YAML

function _computed_test_inputs()
    plan = DataFrame(
        :Plan_Item_ID => ["GEN_SOLAR", "GEN_NGCC", "STOR_BATTERY"],
        :Resource_Kind => ["generation", "generation", "storage"],
        :Zone => ["Z1", "Z1", "Z1"],
        :Type => ["Solar", "NGCC", "Battery"],
        :Build_MW => [100.0, 80.0, 40.0],
        :Build_MWh => [0.0, 0.0, 160.0],
    )
    catalog = DataFrame(
        :Candidate_Site_ID => [
            "SOL_EXIST",
            "SOL_RESOURCE",
            "SOL_EXCLUDED",
            "NG_EXIST",
            "NG_GREEN",
            "BAT_EXIST",
            "BAT_GREEN",
        ],
        :Site_ID => ["S1", "S2", "S3", "S4", "S5", "S6", "S7"],
        :Bus_id => ["B1", "B2", "B3", "B4", "B5", "B6", "B7"],
        :Resource_Kind => [
            "generation",
            "generation",
            "generation",
            "generation",
            "generation",
            "storage",
            "storage",
        ],
        :Zone => fill("Z1", 7),
        :Type => ["Solar", "Solar", "Solar", "NGCC", "NGCC", "Battery", "Battery"],
        :Candidate_Max_MW => [100.0, 100.0, 500.0, 50.0, 80.0, 40.0, 40.0],
        :Candidate_Max_MWh =>
            [missing, missing, missing, missing, missing, 160.0, 160.0],
        :Existing_Site => [true, false, false, true, false, true, false],
        :Site_Cost => [0.0, 10.0, 0.0, 0.0, 5.0, 0.0, 3.0],
        :Network_Stress_Score => [1.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0],
        :Resource_Quality_Score => [0.2, 1.0, 1.0, 0.5, 0.8, 0.5, 0.8],
        :Evidence_Confidence => fill(1.0, 7),
        :Eligible => [true, true, false, true, true, true, true],
        :Network_Screen_Passed => fill(true, 7),
        :Exclusion_Reason => ["", "", "protected_land", "", "", "", ""],
    )
    policy = Dict{String,Any}(
        "schema_version" => 1,
        "artifact_type" => "HOPE.realization_policy",
        "method" => "constrained_site_allocate_v1",
        "solver" => "highs",
        "tolerance_mw" => 1e-6,
        "minimum_allocation_mw" => 0.0,
        "tie_break_epsilon" => 1e-9,
        "variant_order" => [
            "balanced_baseline",
            "existing_site_priority",
            "resource_network_priority",
        ],
        "weights" => Dict(
            "site_cost" => 1.0,
            "network_stress" => 1.0,
            "resource_quality" => 1.0,
            "brownfield" => 1.0,
            "evidence_quality" => 0.0,
            "fragmentation" => 0.0,
        ),
        "variants" => Dict(
            "balanced_baseline" => Dict{String,Any}(),
            "existing_site_priority" => Dict(
                "weights" => Dict(
                    "site_cost" => 0.0,
                    "network_stress" => 0.0,
                    "resource_quality" => 0.0,
                    "brownfield" => 10.0,
                ),
            ),
            "resource_network_priority" => Dict(
                "weights" => Dict(
                    "site_cost" => 0.0,
                    "network_stress" => 4.0,
                    "resource_quality" => 4.0,
                    "brownfield" => 0.0,
                ),
            ),
        ),
    )
    return plan, catalog, policy
end

@testset "Computed nodal realization" begin
    @testset "Screen, allocate, conserve, and diversify" begin
        plan, catalog, policy = _computed_test_inputs()
        result = HOPE.compute_nodal_realizations(plan, catalog, policy)
        allocations = result["allocations"]
        screening = result["screening"]
        summary = result["summary"]

        @test summary.Variant == policy["variant_order"]
        @test all(summary.Status .== "OPTIMAL")
        @test nrow(screening) == nrow(catalog)
        excluded = screening[screening.CandidateSiteID.=="SOL_EXCLUDED", :]
        @test nrow(excluded) == 1
        @test !excluded.ScreenedIn[1]
        @test occursin("catalog_ineligible", excluded.ScreenReason[1])
        @test occursin("protected_land", excluded.ScreenReason[1])
        @test !("SOL_EXCLUDED" in allocations.CandidateSiteID)

        for variant in summary.Variant
            rows = allocations[allocations.Variant.==variant, :]
            for item in eachrow(plan)
                item_rows = rows[rows.PlanItemID.==item.Plan_Item_ID, :]
                @test isapprox(sum(item_rows.AllocatedMW), item.Build_MW; atol = 1e-6)
                expected_mwh = item.Resource_Kind == "storage" ? item.Build_MWh : 0.0
                @test isapprox(sum(item_rows.AllocatedMWh), expected_mwh; atol = 1e-6)
            end
        end

        existing = allocations[
            (allocations.Variant.=="existing_site_priority").&(allocations.PlanItemID.=="GEN_SOLAR"),
            :,
        ]
        resource = allocations[
            (allocations.Variant.=="resource_network_priority").&(allocations.PlanItemID.=="GEN_SOLAR"),
            :,
        ]
        @test existing.CandidateSiteID == ["SOL_EXIST"]
        @test resource.CandidateSiteID == ["SOL_RESOURCE"]

        repeated = HOPE.compute_nodal_realizations(plan, catalog, policy)
        @test isequal(result["allocations"], repeated["allocations"])
        @test isequal(result["summary"], repeated["summary"])
    end

    @testset "Shared site and storage limits are hard constraints" begin
        plan = DataFrame(
            :Plan_Item_ID => ["S_A", "S_B"],
            :Resource_Kind => ["storage", "storage"],
            :Zone => ["Z1", "Z1"],
            :Type => ["BatteryA", "BatteryB"],
            :Build_MW => [30.0, 30.0],
            :Build_MWh => [120.0, 120.0],
        )
        catalog = DataFrame(
            :Candidate_Site_ID => ["A_SHARED", "A_ALT", "B_SHARED", "B_ALT"],
            :Site_ID => ["SHARED", "A_ALT", "SHARED", "B_ALT"],
            :Bus_id => ["B1", "B2", "B1", "B3"],
            :Resource_Kind => fill("storage", 4),
            :Zone => fill("Z1", 4),
            :Type => ["BatteryA", "BatteryA", "BatteryB", "BatteryB"],
            :Candidate_Max_MW => fill(30.0, 4),
            :Candidate_Max_MWh => fill(120.0, 4),
            :Site_Max_MW => [40.0, 30.0, 40.0, 30.0],
            :Site_Cost => [0.0, 1.0, 0.0, 1.0],
        )
        _, _, policy = _computed_test_inputs()
        policy["variant_order"] = ["balanced_baseline"]
        policy["variants"] = Dict("balanced_baseline" => Dict{String,Any}())
        result = HOPE.compute_nodal_realizations(plan, catalog, policy)
        shared = result["allocations"][result["allocations"].SiteID.=="SHARED", :]
        @test sum(shared.AllocatedMW) <= 40.0 + 1e-6
    end

    @testset "Discrete project mode selects whole, unique, screened projects" begin
        plan = DataFrame(
            :Plan_Item_ID => ["SOLAR_BLOCK_1", "SOLAR_BLOCK_2", "BATTERY_BLOCK"],
            :Resource_Kind => ["generation", "generation", "storage"],
            :Zone => fill("Z1", 3),
            :Type => ["Solar", "Solar", "Battery"],
            :Build_MW => [100.0, 100.0, 50.0],
            :Build_MWh => [0.0, 0.0, 200.0],
        )
        catalog = DataFrame(
            :Candidate_Site_ID =>
                ["SOL_A", "SOL_B", "SOL_ENV", "SOL_GRID", "BAT_A", "BAT_SHORT"],
            :Site_ID => ["A", "B", "C", "D", "E", "F"],
            :Bus_id => ["B1", "B2", "B3", "B4", "B5", "B6"],
            :Resource_Kind => [
                "generation",
                "generation",
                "generation",
                "generation",
                "storage",
                "storage",
            ],
            :Zone => fill("Z1", 6),
            :Type => ["Solar", "Solar", "Solar", "Solar", "Battery", "Battery"],
            :Candidate_Max_MW => [100.0, 100.0, 100.0, 100.0, 50.0, 50.0],
            :Candidate_Max_MWh => [missing, missing, missing, missing, 200.0, 100.0],
            :Site_Cost => [0.0, 1.0, 2.0, 3.0, 0.0, 1.0],
            :Environmental_Eligible => [true, true, false, true, true, true],
            :Interconnection_Headroom_MW => [100.0, 100.0, 100.0, 50.0, 50.0, 50.0],
            :Permit_Status => [
                "approved",
                "conditional",
                "approved",
                "approved",
                "approved",
                "approved",
            ],
            :Community_Review_Required => [false, true, false, false, false, false],
        )
        _, _, policy = _computed_test_inputs()
        policy["allocation_mode"] = "discrete_project"
        policy["project_size_tolerance_mw"] = 1e-6
        policy["max_sites_per_plan_item"] = 1
        policy["variant_order"] = ["balanced_baseline"]
        policy["variants"] = Dict("balanced_baseline" => Dict{String,Any}())
        result = HOPE.compute_nodal_realizations(plan, catalog, policy)
        allocations = result["allocations"]
        screening = result["screening"]

        @test nrow(allocations) == 3
        @test length(unique(allocations.CandidateSiteID)) == 3
        @test Set(allocations.CandidateSiteID) == Set(["SOL_A", "SOL_B", "BAT_A"])
        @test sort(allocations.AllocatedMW) == [50.0, 100.0, 100.0]
        @test allocations.ReviewRequired[allocations.CandidateSiteID.=="SOL_B"] == [true]
        @test occursin(
            "environmental_screen_failed",
            only(screening.ScreenReason[screening.CandidateSiteID.=="SOL_ENV"]),
        )
        @test occursin(
            "insufficient_interconnection_headroom",
            only(screening.ScreenReason[screening.CandidateSiteID.=="SOL_GRID"]),
        )
        @test !("BAT_SHORT" in allocations.CandidateSiteID)
    end

    @testset "Infeasible plans and invalid policies fail closed" begin
        plan, catalog, policy = _computed_test_inputs()
        catalog = catalog[catalog.Candidate_Site_ID.!="SOL_RESOURCE", :]
        catalog[catalog.Candidate_Site_ID.=="SOL_EXIST", :Candidate_Max_MW] .= 20.0
        @test_throws ArgumentError HOPE.compute_nodal_realizations(plan, catalog, policy)

        _, catalog, policy = _computed_test_inputs()
        bad_policy = copy(policy)
        bad_policy["method"] = "unknown"
        @test_throws ArgumentError HOPE.compute_nodal_realizations(
            _computed_test_inputs()[1],
            catalog,
            bad_policy,
        )
    end

    @testset "Artifact package contains hashes and audit tables" begin
        plan, catalog, policy = _computed_test_inputs()
        mktempdir() do directory
            plan_path = joinpath(directory, "capacity_plan.csv")
            catalog_path = joinpath(directory, "candidate_site_catalog.csv")
            policy_path = joinpath(directory, "realization_policy.yml")
            output_path = joinpath(directory, "output")
            CSV.write(plan_path, plan)
            CSV.write(catalog_path, catalog)
            YAML.write_file(policy_path, policy)
            result = HOPE.write_computed_realization_set(
                plan_path,
                catalog_path,
                policy_path,
                output_path,
            )
            @test all(isfile, values(result["paths"]))
            manifest = YAML.load_file(result["paths"]["manifest"])
            @test manifest["artifact_type"] == "HOPE.realization_set"
            @test manifest["method"] == "constrained_site_allocate_v1"
            @test length(manifest["variants"]) == 3
            @test all(length(value) == 64 for value in values(manifest["outputs"]))
            @test nrow(CSV.read(result["paths"]["allocations"], DataFrame)) > 0
            @test_throws ArgumentError HOPE.write_computed_realization_set(
                plan_path,
                catalog_path,
                policy_path,
                output_path,
            )
        end
    end

    @testset "Schemas describe implemented version" begin
        catalog_schema = YAML.load_file(
            joinpath(@__DIR__, "..", "schemas", "candidate_site_catalog_v1.yml"),
        )
        plan_schema =
            YAML.load_file(joinpath(@__DIR__, "..", "schemas", "capacity_plan_v1.yml"))
        policy_schema =
            YAML.load_file(joinpath(@__DIR__, "..", "schemas", "realization_policy_v1.yml"))
        @test catalog_schema["artifact_type"] == "HOPE.candidate_site_catalog"
        @test plan_schema["artifact_type"] == "HOPE.capacity_plan"
        @test policy_schema["artifact_type"] == "HOPE.realization_policy"
        @test policy_schema["required_top_level"]["method"]["value"] ==
              "constrained_site_allocate_v1"
    end
end
