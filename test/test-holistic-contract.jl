using CSV
using DataFrames
using HOPE
using Test
using YAML

function _holistic_contract_fixture(root::AbstractString)
    gtep_case = joinpath(root, "gtep")
    pcm_case = joinpath(root, "pcm")
    mkpath(joinpath(gtep_case, "Data"))
    mkpath(joinpath(pcm_case, "Data"))
    mkpath(joinpath(pcm_case, "references"))
    write(joinpath(gtep_case, "Data", "sentinel.csv"), "value\n1\n")
    write(joinpath(pcm_case, "Data", "sentinel.csv"), "value\n2\n")
    CSV.write(
        joinpath(pcm_case, "references", "source_data_register.csv"),
        DataFrame(
            Dataset = ["Public network"],
            Role = ["Transmission topology"],
            Source = ["Example source"],
            License_or_terms = ["Example terms"],
            Transformation = ["Deterministic fixture"],
        ),
    )

    time_data = DataFrame(
        Symbol("Time Period") => [1],
        :Month => [1],
        :Day => [1],
        :Hours => [1],
        :Z1 => [10.0],
        :Z2 => [20.0],
    )
    gtep_input = Dict{String,Any}(
        "Zonedata" => DataFrame(:Zone_id => ["Z1", "Z2"]),
        "Loaddata" => copy(time_data),
        "Gendata" => DataFrame(:Asset_ID => ["A1"], :Zone => ["Z1"]),
        "Storagedata" => DataFrame(:Zone => String[]),
        "Linedata" => DataFrame(:From_zone => ["Z1"], :To_zone => ["Z2"]),
        "Gendata_candidate" => DataFrame(
            :Candidate_ID => ["GEN_C1"],
            :Zone => ["Z1"],
            :Planning_Zone => ["Z1"],
            :Bus_id => ["B1"],
        ),
        "Estoragedata_candidate" => DataFrame(
            :Candidate_ID => ["STO_C1"],
            :Zone => ["Z2"],
            :Planning_Zone => ["Z2"],
            :Bus_id => ["B2"],
        ),
        "Linedata_candidate" => DataFrame(
            :From_zone => ["Z1"],
            :To_zone => ["Z2"],
            :Corridor_ID => ["C1"],
            :PCM_from_bus => ["B1"],
            :PCM_to_bus => ["B2"],
        ),
    )
    pcm_input = Dict{String,Any}(
        "Zonedata" => DataFrame(:Zone_id => ["Z1", "Z2"]),
        "Loaddata" => copy(time_data),
        "Gendata" => DataFrame(:Asset_ID => ["A1"], :Zone => ["Z1"], :Bus_id => ["B1"]),
        "Storagedata" => DataFrame(:Zone => String[], :Bus_id => String[]),
        "Linedata" => DataFrame(:From_zone => ["Z1"], :To_zone => ["Z2"]),
        "Busdata" => DataFrame(:Bus_id => ["B1", "B2"], :Zone_id => ["Z1", "Z2"]),
        "Branchdata" => DataFrame(
            :From_zone => ["Z1"],
            :To_zone => ["Z2"],
            :from_bus => ["B1"],
            :to_bus => ["B2"],
            :Corridor_ID => ["C1"],
        ),
    )
    gtep_config = Dict(
        "model_mode" => "GTEP",
        "holistic_spatial_basis" => "zone",
        "DataCase" => "Data",
    )
    pcm_config = Dict(
        "model_mode" => "PCM",
        "holistic_spatial_basis" => "auto",
        "DataCase" => "Data",
    )
    contract = Dict{String,Any}(
        "schema_version" => 1,
        "artifact_type" => "HOPE.physical_realization",
        "workflow" => "GTEP-PCM",
        "topology" => Dict(
            "planning_basis" => "zone",
            "expected_counts" => Dict(
                "planning_nodes" => 2,
                "physical_nodes" => 2,
                "physical_branches" => 1,
            ),
        ),
        "resource_siting" => Dict(
            "generation" => Dict(
                "method" => "explicit_bus",
                "planning_zone_column" => "Planning_Zone",
            ),
            "storage" => Dict(
                "method" => "explicit_bus",
                "planning_zone_column" => "Planning_Zone",
            ),
        ),
        "transmission_realization" =>
            Dict("method_priority" => ["corridor_id", "explicit_endpoints"]),
        "provenance" => Dict(
            "source_register" => Dict(
                "case" => "pcm",
                "path" => "references/source_data_register.csv",
            ),
        ),
    )
    return (gtep_case, gtep_config, gtep_input, pcm_case, pcm_config, pcm_input, contract)
end

@testset "Holistic handoff contract" begin
    mktempdir() do root
        fixture = _holistic_contract_fixture(root)
        report = HOPE.validate_holistic_handoff_contract(
            fixture[1:6]...;
            physical_contract = fixture[7],
            require_valid = true,
        )
        @test report["valid"]
        @test all(report["checks"].Passed[report["checks"].Severity.=="error"])
        @test length(report["source_fingerprints"]["gtep"]) == 1
        @test length(report["source_fingerprints"]["pcm"]) == 1

        paths = HOPE.write_holistic_handoff_contract_report(root, report)
        @test isfile(paths["checks_csv"])
        @test isfile(paths["contract_yaml"])
        serialized = YAML.load_file(paths["contract_yaml"])
        @test serialized["valid"]

        write(joinpath(fixture[1], "Data", "sentinel.csv"), "value\nchanged\n")
        gtep_after = HOPE.holistic_case_fingerprint(fixture[1], fixture[2])
        pcm_after = HOPE.holistic_case_fingerprint(fixture[4], fixture[5])
        HOPE.validate_holistic_source_immutability!(
            report,
            gtep_after,
            pcm_after;
            require_valid = false,
        )
        @test !report["valid"]
        @test !only(
            report["checks"].Passed[report["checks"].Check.=="gtep_source_immutability"],
        )
    end

    mktempdir() do root
        fixture = collect(_holistic_contract_fixture(root))
        duplicate = vcat(fixture[3]["Gendata_candidate"], fixture[3]["Gendata_candidate"])
        fixture[3]["Gendata_candidate"] = duplicate
        report = HOPE.validate_holistic_handoff_contract(
            fixture[1:6]...;
            physical_contract = fixture[7],
            require_valid = false,
        )
        @test !report["valid"]
        @test !only(
            report["checks"].Passed[report["checks"].Check.=="gtep.generation_candidates.Candidate_ID"],
        )
    end

    mktempdir() do root
        fixture = collect(_holistic_contract_fixture(root))
        fixture[3]["Estoragedata_candidate"].Bus_id .= "UNKNOWN"
        report = HOPE.validate_holistic_handoff_contract(
            fixture[1:6]...;
            physical_contract = fixture[7],
            require_valid = false,
        )
        @test !report["valid"]
        @test !only(
            report["checks"].Passed[report["checks"].Check.=="storage_candidate_bus_references"],
        )
    end

    mktempdir() do root
        contract_path = joinpath(root, "physical.yml")
        open(contract_path, "w") do io
            YAML.write(
                io,
                Dict(
                    "schema_version" => 1,
                    "artifact_type" => "HOPE.physical_realization",
                    "workflow" => "GTEP-PCM",
                ),
            )
        end
        loaded = HOPE.load_holistic_physical_realization(contract_path)
        @test loaded["schema_version"] == 1
        loaded["schema_version"] = 2
        open(contract_path, "w") do io
            YAML.write(io, loaded)
        end
        @test_throws ArgumentError HOPE.load_holistic_physical_realization(contract_path)
    end

    schema_path = normpath(
        joinpath(
            dirname(pathof(HOPE)),
            "..",
            "schemas",
            "holistic_physical_realization_v1.yml",
        ),
    )
    schema = YAML.load_file(schema_path)
    @test schema["schema_version"] == 1
    @test schema["artifact_type"] == "HOPE.physical_realization"
end
