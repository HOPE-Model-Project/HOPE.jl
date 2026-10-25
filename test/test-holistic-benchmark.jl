using CSV
using DataFrames
using HOPE
using Test
using YAML

function write_benchmark_yaml(path, value)
    mkpath(dirname(path))
    open(path, "w") do io
        YAML.write(io, value)
    end
end

@testset "Holistic benchmark evidence" begin
    mktempdir() do workspace
        gtep_case = joinpath(workspace, "gtep_case")
        pcm_case = joinpath(workspace, "pcm_case")
        gtep_data = joinpath(gtep_case, "Data")
        pcm_data = joinpath(pcm_case, "Data")
        pcm_output = joinpath(pcm_case, "output_holistic")
        realized = joinpath(pcm_output, "realized_inputs")
        foreach(mkpath, [gtep_data, pcm_data, joinpath(pcm_output, "Analysis"), realized])

        CSV.write(
            joinpath(gtep_data, "load_timeseries_regional.csv"),
            DataFrame(Hours = 1:4, ZoneA = fill(1.0, 4)),
        )
        CSV.write(joinpath(pcm_data, "busdata.csv"), DataFrame(Bus_id = ["B1", "B2"]))
        CSV.write(
            joinpath(realized, "branchdata.csv"),
            DataFrame(From = ["B1"], To = ["B2"]),
        )
        CSV.write(
            joinpath(realized, "gendata.csv"),
            DataFrame(
                "Asset_ID" => ["existing-1", "candidate-1__UNIT_001"],
                "Bus_id" => ["B1", "B2"],
                "Latitude" => [39.0, 39.1],
                "Longitude" => [-77.0, -76.9],
                "Cost (\$/MWh)" => [10.0, 20.0],
            ),
        )
        CSV.write(
            joinpath(realized, "storagedata.csv"),
            DataFrame(
                "Asset_ID" => ["storage-1__UNIT_001"],
                "Bus_id" => ["B2"],
                "Latitude" => [39.1],
                "Longitude" => [-76.9],
            ),
        )
        CSV.write(
            joinpath(realized, "generation_builds_audit.csv"),
            DataFrame(
                CandidateID = ["candidate-1"],
                RealizedAssetID = ["candidate-1__UNIT_001"],
                Zone = ["ZoneA"],
                Type = ["NGCC"],
                BuiltMW = [50.0],
                OperationalTemplateID = ["NGCC_DEFAULT"],
                ParameterSource = ["template"],
            ),
        )
        CSV.write(
            joinpath(realized, "storage_builds_audit.csv"),
            DataFrame(
                CandidateID = ["storage-1"],
                RealizedAssetID = ["storage-1__UNIT_001"],
                Zone = ["ZoneA"],
                Type = ["Battery"],
                BuiltPowerMW = [10.0],
                BuiltEnergyMWh = [40.0],
                OperationalTemplateID = ["BATTERY_4H"],
                ParameterSource = ["template"],
            ),
        )
        CSV.write(
            joinpath(realized, "retirements_audit.csv"),
            DataFrame(
                Layer = ["raw"],
                AssetID = ["G1149"],
                Zone = ["ZoneA"],
                Type = ["Oil"],
                MappingMode = ["asset_id"],
                InitialMW = [2.0],
                RetiredMW = [2.0],
                FinalMW = [0.0],
            ),
        )
        CSV.write(
            joinpath(realized, "line_allocations_audit.csv"),
            DataFrame(
                CorridorID = ["OSM_L62255589"],
                FromZone = ["B1"],
                ToZone = ["B2"],
                MappingMode = ["corridor_id"],
                ForwardAddedMW = [1000.0],
                ReverseAddedMW = [1000.0],
            ),
        )
        CSV.write(
            joinpath(pcm_output, "power_hourly.csv"),
            DataFrame(
                EC_Category = ["Existing", "Candidate"],
                h1 = [5.0, 1.0],
                h2 = [6.0, 2.0],
                h3 = [7.0, 3.0],
            ),
        )
        CSV.write(
            joinpath(pcm_output, "Analysis", "Summary_System_Hourly.csv"),
            DataFrame(
                Hour = 1:3,
                StorageCharge_MW = [1.0, 2.0, 3.0],
                StorageDischarge_MW = [0.0, 1.0, 2.0],
                LoadShedding_MW = [0.0, 0.0, 0.0],
                Curtailment_MW = [0.0, 0.5, 0.0],
                TotalEmissions_ton = [5.0, 6.0, 7.0],
            ),
        )

        metrics = Dict(
            "gtep_termination_status" => "OPTIMAL",
            "pcm_termination_status" => "OPTIMAL",
            "source_gtep_unchanged" => true,
            "source_pcm_unchanged" => true,
            "gtep_objective_value" => 1000.0,
            "pcm_objective_value" => 200.0,
            "pcm_rps_slack_mwh" => 0.0,
            "retired_generation_mw" => 2.0,
            "line_forward_added_mw" => 1000.0,
            "line_reverse_added_mw" => 1000.0,
            "pcm_upgraded_line_max_abs_flow_mw" => 936.0,
            "pcm_upgraded_line_flow_above_source_mw" => 436.0,
        )
        write_benchmark_yaml(
            joinpath(pcm_output, "holistic_coverage.yml"),
            Dict("all_passed" => true, "metrics" => metrics),
        )
        transfer_metrics = Dict(
            "expected_new_generation_mw" => 50.0,
            "expected_new_storage_power_mw" => 10.0,
            "expected_new_storage_energy_mwh" => 40.0,
        )
        write_benchmark_yaml(
            joinpath(realized, "transfer_reconciliation.yml"),
            Dict(
                "valid" => true,
                "metrics" => transfer_metrics,
                "checks" => [
                    Dict(
                        "Check" => "table.generation_capacity_conservation",
                        "Expected" => "150.0",
                        "Actual" => "150.0",
                        "Passed" => true,
                    ),
                ],
            ),
        )
        write_benchmark_yaml(
            joinpath(realized, "handoff_contract.yml"),
            Dict(
                "valid" => true,
                "physical_realization" =>
                    Dict("topology" => Dict("planning_basis" => "zone")),
            ),
        )
        write_benchmark_yaml(
            joinpath(workspace, "run_manifest.yml"),
            Dict(
                "status" => "PUBLISHED",
                "request_id" => "fixture-run",
                "solver" => "highs",
                "gtep_source_sha256" => "gtep-hash",
                "pcm_source_sha256" => "pcm-hash",
            ),
        )
        slice_path = joinpath(workspace, "validation_slice.yml")
        write_benchmark_yaml(
            slice_path,
            Dict(
                "pcm_warmup_hours" => 1,
                "pcm_evaluation_hours" => 2,
                "pcm_evaluation_start_hour" => 2,
                "pcm_evaluation_end_hour" => 3,
                "pcm_month" => 7,
            ),
        )

        expected_path = joinpath(workspace, "expected.yml")
        write_benchmark_yaml(
            expected_path,
            Dict(
                "expected_metrics" => Dict(
                    "gtep_source_sha256" => Dict("value" => "gtep-hash"),
                    "new_generation_mw" => Dict("value" => 50.0, "atol" => 1.0e-6),
                    "evaluation_emissions_tons" =>
                        Dict("value" => 13.0, "rtol" => 1.0e-9),
                ),
            ),
        )
        result =
            HOPE.write_holistic_benchmark_report(workspace; expected_path = expected_path)
        summary = result["summary"]
        @test summary["all_passed"]
        @test summary["gtep_hours"] == 4
        @test summary["pcm_solve_hours"] == 3
        @test summary["pcm_warmup_hours"] == 1
        @test summary["pcm_evaluation_hours"] == 2
        @test summary["evaluation_new_generation_dispatch_mwh"] == 5.0
        @test summary["evaluation_storage_charge_mwh"] == 5.0
        @test summary["evaluation_storage_discharge_mwh"] == 3.0
        @test summary["evaluation_emissions_tons"] == 13.0
        @test summary["evaluation_variable_generation_cost_usd"] == 230.0
        @test summary["physical_nodes"] == 2
        @test summary["physical_branches"] == 1
        @test all(result["checks"].Passed)
        @test count(result["checks"].Stage .== "reference baseline") == 3
        for path in values(result["paths"])
            @test isfile(path)
        end
        physical_output = CSV.read(result["paths"]["physical_realization_csv"], DataFrame)
        @test nrow(physical_output) == 2
        @test Set(physical_output.BusID) == Set(["B2"])
        @test nrow(CSV.read(result["paths"]["retirements_csv"], DataFrame)) == 1
        @test nrow(CSV.read(result["paths"]["transmission_builds_csv"], DataFrame)) == 1
        report = read(result["paths"]["report_markdown"], String)
        @test occursin("candidate-1__UNIT_001", report)
        @test occursin("G1149", report)
        @test occursin("OSM_L62255589", report)
        @test occursin("Upgraded-corridor flow above source rating", report)
        @test occursin("not equality checks", report)
    end
end
