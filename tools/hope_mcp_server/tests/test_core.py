from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGE_ROOT / "src"))

from hope_mcp_server.core import (
    DEFAULT_HOPE_REPO_ROOT,
    _MODEL_MODE_OPTIONS,
    _holistic_request_jobs,
    _Job,
    _jobs,
    _launch_job,
    _write_yaml_atomic,
    _validate_settings_dict,
    build_debug_solver_environment_command,
    build_holistic_run_command,
    build_optional_solver_probe_command,
    build_run_command,
    check_optional_solvers_available,
    hope_cancel_job,
    hope_case_info,
    hope_debug_solver_environment,
    hope_debug_solver_environment_async,
    hope_holistic_status,
    hope_job_status,
    hope_open_dashboard,
    hope_output_summary,
    hope_run_holistic,
    hope_run_hope,
    julia_string_literal,
    modelcases_root,
    parse_dart_output_summary,
    setup_command,
)
from hope_mcp_server.server import create_mcp_server

REPO_ROOT = Path(__file__).resolve().parents[3]
JULIA_BIN = (
    "/Users/qianzhang/.julia/juliaup/julia-1.11.6+0.aarch64.apple.darwin14/bin/julia"
)


class HopeCoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env_patch = mock.patch.dict(
            "os.environ",
            {
                "HOPE_REPO_ROOT": str(REPO_ROOT),
                "HOPE_MODELCASES_PATH": str(REPO_ROOT / "ModelCases"),
                "HOPE_JULIA_BIN": JULIA_BIN,
            },
            clear=False,
        )
        self.env_patch.start()

    def tearDown(self) -> None:
        self.env_patch.stop()

    def test_default_repo_root_is_this_source_checkout(self) -> None:
        self.assertEqual(DEFAULT_HOPE_REPO_ROOT, REPO_ROOT)
        self.assertTrue((DEFAULT_HOPE_REPO_ROOT / "src" / "HOPE.jl").is_file())

    def test_modelcases_root_honors_environment_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            configured = Path(tmp) / "external-model-cases"
            with mock.patch.dict(
                "os.environ",
                {"HOPE_MODELCASES_PATH": str(configured)},
                clear=False,
            ):
                self.assertEqual(modelcases_root(REPO_ROOT), configured.resolve())

    def test_case_discovery_uses_external_modelcases_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cases_root = Path(tmp) / "external-model-cases"
            case = cases_root / "external_pcm_case"
            (case / "Settings").mkdir(parents=True)
            (case / "Settings" / "HOPE_model_settings.yml").write_text(
                "model_mode: PCM\nsolver: highs\nDataCase: Data/\n",
                encoding="utf-8",
            )
            with mock.patch.dict(
                "os.environ",
                {"HOPE_MODELCASES_PATH": str(cases_root)},
                clear=False,
            ):
                result = hope_case_info("external_pcm_case")
        self.assertTrue(result["ok"])
        self.assertEqual(result["model_mode"], "PCM")
        self.assertEqual(Path(result["case_path"]), case.resolve())

    def test_case_info_reads_yaml_and_output_inventory(self) -> None:
        result = hope_case_info()
        self.assertTrue(result["ok"])
        self.assertEqual(result["case_id"], "md_gtep_clean")
        self.assertEqual(result["model_mode"], "GTEP")
        self.assertIn(result["solver"], {"cbc", "clp", "highs", "scip", "gurobi", "cplex"})
        self.assertEqual(result["DataCase"], "Data_100RPS/")
        self.assertTrue(result["output_exists"])
        self.assertIn("capacity.csv", result["output_csv_files"])
        self.assertGreater(result["output_csv_count"], 0)

    def test_output_summary_reports_system_cost_and_solar_builds(self) -> None:
        result = hope_output_summary()
        self.assertTrue(result["ok"])
        self.assertIsNotNone(result["total_system_cost"])
        self.assertGreater(result["total_system_cost"], 0.0)
        solar_builds = [
            build
            for build in result["new_generation_builds"]
            if build["technology"] == "SolarPV"
        ]
        self.assertTrue(solar_builds)
        self.assertIn("system_cost.csv", result["available_output_files"])

    def test_dart_mode_and_output_summary_are_supported(self) -> None:
        self.assertIn("DART", _MODEL_MODE_OPTIONS)
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            (output / "acceptance_summary.csv").write_text(
                "all_solves_optimal,day_ahead_solves,real_time_solves\ntrue,2,24\n",
                encoding="utf-8",
            )
            (output / "constraint_coverage.csv").write_text(
                "constraint_family,enabled\na,true\nb,true\n",
                encoding="utf-8",
            )
            (output / "day_ahead_solver.csv").write_text(
                "termination_status,primal_status\nOPTIMAL,FEASIBLE_POINT\nOPTIMAL,FEASIBLE_POINT\n",
                encoding="utf-8",
            )
            (output / "real_time_solver.csv").write_text(
                "termination_status,primal_status\nOPTIMAL,FEASIBLE_POINT\n",
                encoding="utf-8",
            )
            summary = parse_dart_output_summary(output)
        self.assertEqual(summary["dart_acceptance"]["day_ahead_solves"], "2")
        self.assertEqual(summary["dart_constraint_coverage"], {"enabled": 2, "total": 2})
        self.assertEqual(
            summary["dart_solver_status_counts"]["day_ahead"],
            {"OPTIMAL / FEASIBLE_POINT": 2},
        )

    def test_dart_dashboard_returns_explicit_unsupported_error(self) -> None:
        case_path = REPO_ROOT / "ModelCases" / "RTS24_DART_case"
        if not case_path.is_dir():
            self.skipTest("RTS24_DART_case is unavailable")
        result = hope_open_dashboard("RTS24_DART_case")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "dashboard_unsupported_model_mode")
        self.assertEqual(result["model_mode"], "DART")

    def test_dart_settings_warnings_match_julia_compatibility_rules(self) -> None:
        warnings = _validate_settings_dict(
            {
                "model_mode": "DART",
                "resource_aggregation": 1,
                "network_model": 2,
                "transmission_loss": 1,
                "unit_commitment": 2,
                "debug": 1,
                "reference_bus": 1,
            }
        )
        joined = "\n".join(warnings)
        self.assertIn("resource_aggregation", joined)
        self.assertIn("network_model=3", joined)
        self.assertIn("transmission_loss=0", joined)
        self.assertIn("unit_commitment must be 0 or 1", joined)
        self.assertIn("debug=0", joined)

    def test_invalid_case_id_returns_allowed_values_error(self) -> None:
        result = hope_case_info("not_a_case")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "invalid_case_id")
        self.assertIn("md_gtep_clean", result["allowed_case_ids"])
        self.assertIn("MD_GTEP_clean_case", result["allowed_case_ids"])
        self.assertIn("USA_64zone_GTEP_case", result["allowed_case_ids"])

    def test_case_info_accepts_modelcases_directory_name(self) -> None:
        result = hope_case_info("MD_GTEP_clean_case")
        self.assertTrue(result["ok"])
        self.assertEqual(result["model_mode"], "GTEP")

    def test_case_info_accepts_modelcases_prefixed_path(self) -> None:
        result = hope_case_info("ModelCases/MD_GTEP_clean_case")
        self.assertTrue(result["ok"])
        canonical = hope_case_info("MD_GTEP_clean_case")
        self.assertTrue(canonical["ok"])
        self.assertEqual(result["solver"], canonical["solver"])

    def test_read_only_server_exposes_only_fetch_tools(self) -> None:
        mcp = create_mcp_server(read_only=True, host="127.0.0.1", port=8765)
        tool_names = {tool.name for tool in mcp._tool_manager.list_tools()}
        self.assertIn("hope_case_info", tool_names)
        self.assertIn("hope_read_output", tool_names)
        self.assertNotIn("hope_run_hope", tool_names)
        self.assertNotIn("hope_update_settings", tool_names)
        self.assertNotIn("hope_open_dashboard", tool_names)
        self.assertNotIn("hope_cancel_job", tool_names)
        self.assertNotIn("hope_debug_solver_environment", tool_names)
        self.assertNotIn("hope_debug_solver_environment_async", tool_names)

    def test_full_server_keeps_run_tools_for_claude(self) -> None:
        mcp = create_mcp_server(read_only=False, host="127.0.0.1", port=8766)
        tool_names = {tool.name for tool in mcp._tool_manager.list_tools()}
        self.assertIn("hope_run_hope", tool_names)
        self.assertIn("hope_update_settings", tool_names)
        self.assertIn("hope_job_status", tool_names)
        self.assertIn("hope_cancel_job", tool_names)
        self.assertIn("hope_debug_solver_environment", tool_names)
        self.assertIn("hope_debug_solver_environment_async", tool_names)
        self.assertIn("hope_holistic_status", tool_names)
        self.assertIn("hope_prepare_holistic_study", tool_names)
        self.assertIn("hope_launch_holistic_study", tool_names)
        self.assertIn("hope_holistic_study_status", tool_names)
        self.assertIn("hope_audit_holistic_study", tool_names)

    def test_read_only_server_accepts_configured_public_hostname(self) -> None:
        with mock.patch.dict(
            "os.environ",
            {"HOPE_MCP_PUBLIC_HOSTNAME": "hope.hope-mcp.com"},
            clear=False,
        ):
            mcp = create_mcp_server(read_only=True, host="127.0.0.1", port=8767)
        settings = mcp.settings.transport_security
        self.assertIsNotNone(settings)
        self.assertIn("hope.hope-mcp.com", settings.allowed_hosts)
        self.assertIn("https://hope.hope-mcp.com", settings.allowed_origins)

    def test_build_run_command_uses_env_config(self) -> None:
        case_path = REPO_ROOT / "ModelCases" / "MD_GTEP_clean_case"
        command = build_run_command(REPO_ROOT, JULIA_BIN, case_path)
        self.assertEqual(
            command,
            [
                JULIA_BIN,
                "--startup-file=no",
                f"--project={REPO_ROOT}",
                "-e",
                "using HOPE; HOPE.run_hope(ARGS[1])",
                str(case_path),
            ],
        )

    def test_holistic_command_passes_paths_and_solver_as_arguments(self) -> None:
        gtep = REPO_ROOT / "ModelCases" / "$gtep"
        pcm = REPO_ROOT / "ModelCases" / "$pcm"
        manifest = REPO_ROOT / "artifacts" / "$request" / "run_manifest.yml"
        command = build_holistic_run_command(
            REPO_ROOT,
            JULIA_BIN,
            gtep,
            pcm,
            manifest,
            "$solver",
        )
        script = REPO_ROOT / "tools" / "repo_utils" / "run_holistic_agent_job.jl"
        self.assertEqual(
            command[-5:],
            [str(script), str(gtep), str(pcm), str(manifest), "$solver"],
        )

    def test_julia_string_literal_escapes_interpolation(self) -> None:
        self.assertEqual(julia_string_literal("$solver"), '"\\$solver"')

    def test_debug_command_passes_dynamic_values_as_arguments(self) -> None:
        case_path = REPO_ROOT / "ModelCases" / "$case"
        command = build_debug_solver_environment_command(
            REPO_ROOT,
            JULIA_BIN,
            case_path,
            "$solver",
        )
        script_index = command.index("-e") + 1
        script = command[script_index]
        self.assertIn("case = ARGS[1]", script)
        self.assertIn("solver = ARGS[2]", script)
        self.assertNotIn(str(case_path), script)
        self.assertNotIn("$solver", script)
        self.assertEqual(command[script_index + 1 :], [str(case_path), "$solver"])

    def test_optional_solver_probe_does_not_load_hope(self) -> None:
        command = build_optional_solver_probe_command(REPO_ROOT, JULIA_BIN, "Gurobi")
        script = command[command.index("-e") + 1]
        self.assertIn("Base.find_package(pkg)", script)
        self.assertIn("Sys.iswindows()", script)
        self.assertNotIn("using HOPE", script)
        self.assertEqual(command[-1], "Gurobi")
        self.assertIn(f"--project={REPO_ROOT}", command)

    def test_optional_solver_probe_maps_supported_wrappers(self) -> None:
        for solver, package in (("gurobi", "Gurobi"), ("cplex", "CPLEX"), ("scip", "SCIP")):
            completed = subprocess.CompletedProcess(
                args=[],
                returncode=3,
                stdout="DEPOT_PATH=/depot\nLOAD_PATH=/project:/version\nPACKAGE_PATH=\n",
                stderr="",
            )
            with self.subTest(solver=solver), mock.patch(
                "hope_mcp_server.core.subprocess.run",
                return_value=completed,
            ) as run_mock:
                result = check_optional_solvers_available(
                    REPO_ROOT,
                    JULIA_BIN,
                    [solver],
                )
            self.assertIsNotNone(result)
            assert result is not None
            self.assertEqual(result["error_type"], "optional_solver_unavailable")
            self.assertEqual(result["package"], package)
            self.assertIn("Pkg.add", result["install_command"])
            self.assertIn("Pkg.add", result["install_command_powershell"])
            self.assertEqual(run_mock.call_args.args[0][-1], package)
            self.assertEqual(run_mock.call_args.kwargs["stdin"], subprocess.DEVNULL)

    def test_background_julia_jobs_do_not_inherit_mcp_stdin(self) -> None:
        process = mock.Mock()
        process.pid = 1234
        process.stdout = []
        process.stderr = []
        with (
            mock.patch("hope_mcp_server.core.subprocess.Popen", return_value=process) as popen,
            mock.patch("hope_mcp_server.core.threading.Thread") as thread,
        ):
            job_id = _launch_job([JULIA_BIN, "--version"], REPO_ROOT)
        self.addCleanup(lambda: _jobs.pop(job_id, None))
        self.assertEqual(popen.call_args.kwargs["stdin"], subprocess.DEVNULL)
        self.assertEqual(thread.call_count, 2)

    def test_atomic_yaml_write_retries_transient_windows_file_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "manifest.yml"
            real_replace = os.replace
            attempts = 0

            def transient_lock(source: Path, destination: Path) -> None:
                nonlocal attempts
                attempts += 1
                if attempts < 3:
                    raise PermissionError(13, "file temporarily locked")
                real_replace(source, destination)

            with (
                mock.patch("hope_mcp_server.core.os.replace", side_effect=transient_lock),
                mock.patch("hope_mcp_server.core.time.sleep") as sleep,
            ):
                _write_yaml_atomic(path, {"status": "PUBLISHED"})

            self.assertEqual(attempts, 3)
            self.assertEqual(sleep.call_count, 2)
            self.assertIn("PUBLISHED", path.read_text(encoding="utf-8"))

    def test_standalone_missing_optional_solver_is_rejected_before_launch(self) -> None:
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=3,
            stdout="DEPOT_PATH=E:/julia_depot\nLOAD_PATH=project;version\nPACKAGE_PATH=\n",
            stderr="",
        )
        with tempfile.TemporaryDirectory() as tmp:
            case = Path(tmp) / "case"
            (case / "Settings").mkdir(parents=True)
            (case / "Settings" / "HOPE_model_settings.yml").write_text(
                "model_mode: PCM\nsolver: gurobi\nDataCase: Data/\n",
                encoding="utf-8",
            )
            with (
                mock.patch("hope_mcp_server.core.resolve_case", return_value=(case, None)),
                mock.patch(
                    "hope_mcp_server.core.validate_julia_command",
                    return_value=(JULIA_BIN, None),
                ),
                mock.patch(
                    "hope_mcp_server.core.subprocess.run",
                    return_value=completed,
                ),
                mock.patch("hope_mcp_server.core._launch_job") as launch,
            ):
                result = hope_run_hope("standalone_gurobi")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "optional_solver_unavailable")
        self.assertEqual(result["case_id"], "standalone_gurobi")
        launch.assert_not_called()

    def test_missing_julia_path_returns_structured_error(self) -> None:
        with mock.patch.dict(
            "os.environ",
            {
                "HOPE_REPO_ROOT": str(REPO_ROOT),
                "HOPE_JULIA_BIN": str(PACKAGE_ROOT / "missing-julia"),
            },
            clear=False,
        ):
            result = hope_run_hope()
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "julia_not_found")
        self.assertIn("setup_command", result)

    def test_dependency_failure_returns_setup_command(self) -> None:
        process = mock.Mock()
        process.poll.return_value = 1
        job = _Job(
            job_id="depsfail",
            command=[],
            process=process,
            stdout_lines=[],
            stderr_lines=[
                "ArgumentError: Package JuMP is required but does not seem to be installed:",
                " - Run `Pkg.instantiate()` to install all recorded dependencies.",
            ],
        )
        _jobs[job.job_id] = job
        self.addCleanup(lambda: _jobs.pop(job.job_id, None))

        result = hope_job_status(job.job_id)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "hope_environment_not_instantiated")
        self.assertEqual(
            result["setup_command"],
            setup_command(REPO_ROOT, JULIA_BIN),
        )

    def test_cancel_job_returns_not_found_for_unknown_id(self) -> None:
        result = hope_cancel_job("missing-job")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "job_not_found")

    def test_cancel_job_terminates_running_process_and_status_turns_cancelled(self) -> None:
        process = mock.Mock()
        process.poll.side_effect = [None, -15, -15]
        process.wait.return_value = -15
        job = _Job(
            job_id="cancelme",
            command=["julia"],
            process=process,
            stdout_lines=["starting", "working"],
            stderr_lines=["received interrupt"],
        )
        _jobs[job.job_id] = job
        self.addCleanup(lambda: _jobs.pop(job.job_id, None))

        result = hope_cancel_job(job.job_id)
        self.assertTrue(result["ok"])
        self.assertEqual(result["status"], "cancelled")
        self.assertFalse(result["forced_kill"])
        process.terminate.assert_called_once()
        process.kill.assert_not_called()

        status = hope_job_status(job.job_id)
        self.assertTrue(status["ok"])
        self.assertEqual(status["status"], "cancelled")
        self.assertEqual(status["stderr"], "received interrupt")

    def test_cancel_job_force_kills_when_terminate_times_out(self) -> None:
        process = mock.Mock()
        process.poll.side_effect = [None, -9]
        process.wait.side_effect = [subprocess.TimeoutExpired(cmd=["julia"], timeout=5.0), -9]
        job = _Job(
            job_id="forcekill",
            command=["julia"],
            process=process,
        )
        _jobs[job.job_id] = job
        self.addCleanup(lambda: _jobs.pop(job.job_id, None))

        result = hope_cancel_job(job.job_id)
        self.assertTrue(result["ok"])
        self.assertEqual(result["status"], "cancelled")
        self.assertTrue(result["forced_kill"])
        process.terminate.assert_called_once()
        process.kill.assert_called_once()

    def test_debug_solver_environment_reports_probe_details(self) -> None:
        completed = subprocess.CompletedProcess(
            args=["julia"],
            returncode=0,
            stdout=(
                "STEP=julia_start\n"
                "ACTIVE_PROJECT=E:/repo/Project.toml\n"
                "DEPOT_PATH=E:/julia_depot\n"
                "HOPE_PATH=E:/repo/src/HOPE.jl\n"
                "OPTIMIZER_CONSTRUCTOR_VALUE=Gurobi.Optimizer\n"
                "MODEL_TYPE=Model\n"
                "PROBE_STATUS=ok\n"
            ),
            stderr="",
        )
        with (
            mock.patch("hope_mcp_server.core.validate_julia_command", return_value=(JULIA_BIN, None)),
            mock.patch("hope_mcp_server.core.subprocess.run", return_value=completed) as run_mock,
        ):
            result = hope_debug_solver_environment(case_id="MD_GTEP_clean_case", solver="gurobi")
        self.assertTrue(result["ok"])
        self.assertEqual(result["solver"], "gurobi")
        self.assertEqual(result["probe"]["OPTIMIZER_CONSTRUCTOR_VALUE"], "Gurobi.Optimizer")
        self.assertEqual(result["probe"]["PROBE_STATUS"], "ok")
        run_mock.assert_called_once()
        self.assertEqual(run_mock.call_args.kwargs["stdin"], subprocess.DEVNULL)

    def test_debug_solver_environment_rejects_invalid_solver(self) -> None:
        with (
            mock.patch("hope_mcp_server.core.validate_julia_command", return_value=(JULIA_BIN, None)),
            mock.patch("hope_mcp_server.core.subprocess.run") as run_mock,
        ):
            result = hope_debug_solver_environment(
                case_id="MD_GTEP_clean_case",
                solver="$unsupported",
            )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "invalid_solver")
        self.assertEqual(
            result["allowed_solvers"],
            ["cbc", "clp", "highs", "scip", "gurobi", "cplex"],
        )
        run_mock.assert_not_called()

    def test_debug_solver_environment_rejects_invalid_configured_solver(self) -> None:
        with (
            mock.patch("hope_mcp_server.core.validate_julia_command", return_value=(JULIA_BIN, None)),
            mock.patch(
                "hope_mcp_server.core.read_yaml",
                return_value={"solver": "$unsupported"},
            ),
            mock.patch("hope_mcp_server.core.subprocess.run") as run_mock,
        ):
            result = hope_debug_solver_environment(case_id="MD_GTEP_clean_case")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "invalid_solver")
        run_mock.assert_not_called()

    def test_debug_solver_environment_reports_timeout_progress(self) -> None:
        timeout_error = subprocess.TimeoutExpired(
            cmd=["julia"],
            timeout=120.0,
            output="STEP=julia_start\nSTEP=using_HOPE_start\n",
            stderr="",
        )
        with (
            mock.patch("hope_mcp_server.core.validate_julia_command", return_value=(JULIA_BIN, None)),
            mock.patch("hope_mcp_server.core.subprocess.run", side_effect=timeout_error),
        ):
            result = hope_debug_solver_environment(case_id="MD_GTEP_clean_case", solver="gurobi")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "debug_probe_timeout")
        self.assertEqual(result["parsed_stdout"]["STEP"], "using_HOPE_start")

    def test_debug_solver_environment_async_launches_background_job(self) -> None:
        with (
            mock.patch("hope_mcp_server.core.validate_julia_command", return_value=(JULIA_BIN, None)),
            mock.patch("hope_mcp_server.core._launch_job", return_value="probe123") as launch_mock,
        ):
            result = hope_debug_solver_environment_async(
                case_id="MD_GTEP_clean_case",
                solver="gurobi",
            )
        self.assertTrue(result["ok"])
        self.assertEqual(result["job_id"], "probe123")
        self.assertEqual(result["solver"], "gurobi")
        self.assertIn("--startup-file=no", result["command"])
        launch_mock.assert_called_once()

    def test_debug_solver_environment_async_rejects_invalid_solver(self) -> None:
        with (
            mock.patch("hope_mcp_server.core.validate_julia_command", return_value=(JULIA_BIN, None)),
            mock.patch("hope_mcp_server.core._launch_job") as launch_mock,
        ):
            result = hope_debug_solver_environment_async(
                case_id="MD_GTEP_clean_case",
                solver="$unsupported",
            )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "invalid_solver")
        launch_mock.assert_not_called()

    def test_setup_command_disables_startup_file(self) -> None:
        command = setup_command(REPO_ROOT, JULIA_BIN)
        self.assertIn("--startup-file=no", command)

    def test_job_status_returns_parsed_probe_for_completed_debug_job(self) -> None:
        process = mock.Mock()
        process.poll.return_value = 0
        job = _Job(
            job_id="debugdone",
            command=["julia"],
            process=process,
            job_kind="debug_probe",
            stdout_lines=[
                "STEP=julia_start",
                "OPTIMIZER_CONSTRUCTOR_VALUE=HiGHS.Optimizer",
                "PROBE_STATUS=ok",
            ],
        )
        _jobs[job.job_id] = job
        self.addCleanup(lambda: _jobs.pop(job.job_id, None))

        result = hope_job_status(job.job_id)
        self.assertTrue(result["ok"])
        self.assertEqual(result["status"], "done")
        self.assertEqual(result["probe"]["OPTIMIZER_CONSTRUCTOR_VALUE"], "HiGHS.Optimizer")
        self.assertEqual(result["probe"]["PROBE_STATUS"], "ok")
        self.assertNotIn("output_summary", result)


class HolisticAgentWorkflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.runs = self.root / "agent-runs"
        runner = self.root / "tools" / "repo_utils" / "run_holistic_agent_job.jl"
        runner.parent.mkdir(parents=True)
        runner.write_text("# test runner\n", encoding="utf-8")
        self.gtep = self._write_case("gtep_case", "GTEP", "gtep")
        self.pcm = self._write_case("pcm_case", "PCM", "pcm")
        self.env_patch = mock.patch.dict(
            "os.environ",
            {
                "HOPE_REPO_ROOT": str(self.root),
                "HOPE_MODELCASES_PATH": str(self.root / "ModelCases"),
                "HOPE_AGENT_RUNS_ROOT": str(self.runs),
                "HOPE_JULIA_BIN": JULIA_BIN,
            },
            clear=False,
        )
        self.env_patch.start()

    def tearDown(self) -> None:
        self.env_patch.stop()
        for request_id in list(_holistic_request_jobs):
            if request_id.startswith("test-"):
                _holistic_request_jobs.pop(request_id, None)
        for job_id, job in list(_jobs.items()):
            if job.request_id.startswith("test-"):
                _jobs.pop(job_id, None)
        self.temporary.cleanup()

    def _write_case(self, name: str, mode: str, marker: str) -> Path:
        case = self.root / "ModelCases" / name
        (case / "Settings").mkdir(parents=True)
        (case / "Data").mkdir()
        (case / "Settings" / "HOPE_model_settings.yml").write_text(
            f"model_mode: {mode}\nsolver: highs\nDataCase: Data/\n",
            encoding="utf-8",
        )
        (case / "Data" / "input.csv").write_text(
            f"name,value\n{marker},1\n",
            encoding="utf-8",
        )
        (case / "output").mkdir()
        (case / "output" / "stale.csv").write_text("stale\n", encoding="utf-8")
        return case

    def _launch(self, request_id: str = "test-request", solver: str | None = "highs") -> dict:
        def fake_launch(command: list[str], repo_root: Path, case_id: str = "", **kwargs: object) -> str:
            process = mock.Mock()
            process.pid = os.getpid()
            process.poll.return_value = None
            _jobs["job123"] = _Job(
                job_id="job123",
                command=command,
                process=process,
                case_id=case_id,
                job_kind=str(kwargs.get("job_kind", "generic")),
                request_id=str(kwargs.get("request_id", "")),
                workspace_path=str(kwargs.get("workspace_path", "")),
                manifest_path=str(kwargs.get("manifest_path", "")),
                output_case_path=str(kwargs.get("output_case_path", "")),
            )
            return "job123"

        with (
            mock.patch(
                "hope_mcp_server.core.validate_julia_command",
                return_value=(JULIA_BIN, None),
            ),
            mock.patch("hope_mcp_server.core._launch_job", side_effect=fake_launch) as launch,
        ):
            result = hope_run_holistic(
                "gtep_case",
                "pcm_case",
                request_id=request_id,
                solver=solver,
            )
        self.assertEqual(launch.call_count, 1)
        return result

    def test_agent_run_is_isolated_and_persistently_identified(self) -> None:
        result = self._launch()
        self.assertTrue(result["ok"])
        self.assertFalse(result["reused"])
        self.assertEqual(result["status"], "running")

        workspace = Path(result["workspace_path"])
        manifest = Path(result["manifest_path"])
        self.assertTrue((workspace / "gtep_case" / "Data" / "input.csv").is_file())
        self.assertTrue((workspace / "pcm_case" / "Data" / "input.csv").is_file())
        self.assertFalse((workspace / "gtep_case" / "output").exists())
        self.assertFalse((workspace / "pcm_case" / "output").exists())
        self.assertTrue(manifest.is_file())
        self.assertEqual(self.gtep.joinpath("Data", "input.csv").read_text(encoding="utf-8"), "name,value\ngtep,1\n")

        _holistic_request_jobs.pop("test-request", None)
        recovered = hope_holistic_status("test-request")
        self.assertTrue(recovered["ok"])
        self.assertEqual(recovered["status"], "running")
        self.assertTrue(recovered["reused"])

    def test_duplicate_request_is_idempotent(self) -> None:
        first = self._launch("test-duplicate")
        with (
            mock.patch(
                "hope_mcp_server.core.validate_julia_command",
                return_value=(JULIA_BIN, None),
            ),
            mock.patch("hope_mcp_server.core._launch_job") as launch,
        ):
            second = hope_run_holistic(
                "gtep_case",
                "pcm_case",
                request_id="test-duplicate",
                solver="highs",
            )
        self.assertTrue(first["ok"])
        self.assertTrue(second["ok"])
        self.assertTrue(second["reused"])
        self.assertEqual(second["job_id"], "job123")
        launch.assert_not_called()

    def test_request_id_reuse_with_changed_inputs_is_rejected(self) -> None:
        self._launch("test-conflict")
        (self.gtep / "Data" / "input.csv").write_text(
            "name,value\ngtep,2\n",
            encoding="utf-8",
        )
        with (
            mock.patch(
                "hope_mcp_server.core.validate_julia_command",
                return_value=(JULIA_BIN, None),
            ),
            mock.patch("hope_mcp_server.core._launch_job") as launch,
        ):
            result = hope_run_holistic(
                "gtep_case",
                "pcm_case",
                request_id="test-conflict",
                solver="highs",
            )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "request_id_conflict")
        launch.assert_not_called()

    def test_wrong_model_roles_are_rejected_before_launch(self) -> None:
        (self.pcm / "Settings" / "HOPE_model_settings.yml").write_text(
            "model_mode: GTEP\nsolver: highs\nDataCase: Data/\n",
            encoding="utf-8",
        )
        with mock.patch("hope_mcp_server.core._launch_job") as launch:
            result = hope_run_holistic(
                "gtep_case",
                "pcm_case",
                request_id="test-wrong-role",
            )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "invalid_holistic_model_modes")
        launch.assert_not_called()

    def test_missing_optional_solver_is_rejected_without_workspace(self) -> None:
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=3,
            stdout="DEPOT_PATH=E:/julia_depot\nLOAD_PATH=project;version\nPACKAGE_PATH=\n",
            stderr="",
        )
        with (
            mock.patch(
                "hope_mcp_server.core.validate_julia_command",
                return_value=(JULIA_BIN, None),
            ),
            mock.patch(
                "hope_mcp_server.core.subprocess.run",
                return_value=completed,
            ) as run_mock,
            mock.patch("hope_mcp_server.core._launch_job") as launch,
        ):
            result = hope_run_holistic(
                "gtep_case",
                "pcm_case",
                request_id="test-missing-gurobi",
                solver="gurobi",
            )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "optional_solver_unavailable")
        self.assertEqual(result["package"], "Gurobi")
        self.assertEqual(run_mock.call_args.args[0][-1], "Gurobi")
        launch.assert_not_called()
        self.assertFalse((self.runs / "test-missing-gurobi").exists())

    def test_available_optional_solver_launches(self) -> None:
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="PACKAGE_PATH=/depot/Gurobi.jl\n",
            stderr="",
        )
        with mock.patch("hope_mcp_server.core.subprocess.run", return_value=completed):
            result = self._launch("test-gurobi-ok", solver="gurobi")
        self.assertTrue(result["ok"])

    def test_open_source_solver_skips_optional_probe(self) -> None:
        with mock.patch("hope_mcp_server.core.subprocess.run") as run_mock:
            result = self._launch("test-highs-no-probe", solver="highs")
        self.assertTrue(result["ok"])
        run_mock.assert_not_called()

    def test_configured_optional_solvers_are_probed_once_each(self) -> None:
        (self.gtep / "Settings" / "HOPE_model_settings.yml").write_text(
            "model_mode: GTEP\nsolver: gurobi\nDataCase: Data/\n",
            encoding="utf-8",
        )
        (self.pcm / "Settings" / "HOPE_model_settings.yml").write_text(
            "model_mode: PCM\nsolver: cplex\nDataCase: Data/\n",
            encoding="utf-8",
        )
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="PACKAGE_PATH=/depot/wrapper.jl\n",
            stderr="",
        )
        with mock.patch(
            "hope_mcp_server.core.subprocess.run",
            return_value=completed,
        ) as run_mock:
            result = self._launch("test-configured-solvers", solver=None)
        self.assertTrue(result["ok"])
        self.assertEqual(run_mock.call_count, 2)
        self.assertEqual(
            [call.args[0][-1] for call in run_mock.call_args_list],
            ["Gurobi", "CPLEX"],
        )

    def test_duplicate_configured_optional_solver_is_probed_once(self) -> None:
        for case, mode in ((self.gtep, "GTEP"), (self.pcm, "PCM")):
            (case / "Settings" / "HOPE_model_settings.yml").write_text(
                f"model_mode: {mode}\nsolver: gurobi\nDataCase: Data/\n",
                encoding="utf-8",
            )
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="PACKAGE_PATH=/depot/Gurobi.jl\n",
            stderr="",
        )
        with mock.patch(
            "hope_mcp_server.core.subprocess.run",
            return_value=completed,
        ) as run_mock:
            result = self._launch("test-duplicate-solver-probe", solver=None)
        self.assertTrue(result["ok"])
        run_mock.assert_called_once()

    def test_existing_request_is_reused_without_optional_probe(self) -> None:
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="PACKAGE_PATH=/depot/Gurobi.jl\n",
            stderr="",
        )
        with mock.patch("hope_mcp_server.core.subprocess.run", return_value=completed):
            first = self._launch("test-reuse-gurobi", solver="gurobi")
        self.assertTrue(first["ok"])

        with (
            mock.patch(
                "hope_mcp_server.core.validate_julia_command",
                return_value=(JULIA_BIN, None),
            ),
            mock.patch("hope_mcp_server.core.subprocess.run") as run_mock,
            mock.patch("hope_mcp_server.core._launch_job") as launch,
        ):
            second = hope_run_holistic(
                "gtep_case",
                "pcm_case",
                request_id="test-reuse-gurobi",
                solver="gurobi",
            )
        self.assertTrue(second["ok"])
        self.assertTrue(second["reused"])
        run_mock.assert_not_called()
        launch.assert_not_called()

    def test_optional_solver_probe_failure_does_not_launch(self) -> None:
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=2,
            stdout="DEPOT_PATH=E:/julia_depot\n",
            stderr="probe failed",
        )
        with (
            mock.patch(
                "hope_mcp_server.core.validate_julia_command",
                return_value=(JULIA_BIN, None),
            ),
            mock.patch("hope_mcp_server.core.subprocess.run", return_value=completed),
            mock.patch("hope_mcp_server.core._launch_job") as launch,
        ):
            result = hope_run_holistic(
                "gtep_case",
                "pcm_case",
                request_id="test-probe-failure",
                solver="gurobi",
            )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "optional_solver_probe_failed")
        self.assertEqual(result["exit_code"], 2)
        self.assertEqual(result["stderr"], "probe failed")
        launch.assert_not_called()
        self.assertFalse((self.runs / "test-probe-failure").exists())

    def test_optional_solver_probe_timeout_does_not_launch(self) -> None:
        timeout = subprocess.TimeoutExpired(cmd=[JULIA_BIN], timeout=60)
        with (
            mock.patch(
                "hope_mcp_server.core.validate_julia_command",
                return_value=(JULIA_BIN, None),
            ),
            mock.patch("hope_mcp_server.core.subprocess.run", side_effect=timeout),
            mock.patch("hope_mcp_server.core._launch_job") as launch,
        ):
            result = hope_run_holistic(
                "gtep_case",
                "pcm_case",
                request_id="test-probe-timeout",
                solver="gurobi",
            )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error_type"], "optional_solver_probe_failed")
        self.assertEqual(result["timeout_seconds"], 60.0)
        launch.assert_not_called()
        self.assertFalse((self.runs / "test-probe-timeout").exists())

    def test_invalid_request_id_and_solver_are_rejected(self) -> None:
        invalid_id = hope_run_holistic(
            "gtep_case",
            "pcm_case",
            request_id="../cross-over",
        )
        self.assertFalse(invalid_id["ok"])
        self.assertEqual(invalid_id["error_type"], "invalid_request_id")

        invalid_solver = hope_run_holistic(
            "gtep_case",
            "pcm_case",
            request_id="test-invalid-solver",
            solver="$bad",
        )
        self.assertFalse(invalid_solver["ok"])
        self.assertEqual(invalid_solver["error_type"], "invalid_solver")

    def test_completed_job_publishes_manifest_artifacts(self) -> None:
        launched = self._launch("test-complete")
        process = mock.Mock()
        process.poll.return_value = 0
        job = _Job(
            job_id="complete123",
            command=[],
            process=process,
            job_kind="hope_run_holistic",
            request_id="test-complete",
            workspace_path=launched["workspace_path"],
            manifest_path=launched["manifest_path"],
            output_case_path=str(Path(launched["workspace_path"]) / "pcm_case"),
            stdout_lines=[
                "HOPE_GTEP_CASE_PATH=/run/gtep",
                "HOPE_PCM_CASE_PATH=/run/pcm",
                "HOPE_PCM_OUTPUT_PATH=/run/pcm/output_holistic",
                "HOPE_HANDOFF_VALID=true",
                "HOPE_TRANSFER_VALID=true",
                "HOPE_COVERAGE_ALL_PASSED=true",
            ],
        )
        _jobs[job.job_id] = job
        self.addCleanup(lambda: _jobs.pop(job.job_id, None))
        _holistic_request_jobs["test-complete"] = job.job_id

        status = hope_holistic_status("test-complete")
        self.assertTrue(status["ok"])
        self.assertEqual(status["status"], "done")
        self.assertTrue(status["result"]["handoff_valid"])
        self.assertTrue(status["result"]["transfer_valid"])
        self.assertTrue(status["result"]["coverage_all_passed"])

        _holistic_request_jobs.pop("test-complete", None)
        persisted = hope_holistic_status("test-complete")
        self.assertEqual(persisted["status"], "done")
        self.assertEqual(
            persisted["result"]["pcm_output_path"],
            "/run/pcm/output_holistic",
        )

    def test_failed_job_persists_terminal_error(self) -> None:
        launched = self._launch("test-failed")
        process = mock.Mock()
        process.poll.return_value = 2
        job = _Job(
            job_id="failed123",
            command=[],
            process=process,
            job_kind="hope_run_holistic",
            request_id="test-failed",
            workspace_path=launched["workspace_path"],
            manifest_path=launched["manifest_path"],
            stderr_lines=["solver failed"],
        )
        _jobs[job.job_id] = job
        self.addCleanup(lambda: _jobs.pop(job.job_id, None))
        _holistic_request_jobs["test-failed"] = job.job_id

        status = hope_holistic_status("test-failed")
        self.assertFalse(status["ok"])
        self.assertEqual(status["error_type"], "job_failed")

        _holistic_request_jobs.pop("test-failed", None)
        persisted = hope_holistic_status("test-failed")
        self.assertFalse(persisted["ok"])
        self.assertEqual(persisted["error_type"], "job_failed")
        self.assertEqual(persisted["status"], "failed")
        self.assertEqual(persisted["error"]["stderr"], "solver failed")

    def test_cancelled_job_persists_terminal_state(self) -> None:
        launched = self._launch("test-cancelled")
        process = mock.Mock()
        process.poll.side_effect = [None, -15]
        process.wait.return_value = -15
        job = _Job(
            job_id="cancelled123",
            command=[],
            process=process,
            job_kind="hope_run_holistic",
            request_id="test-cancelled",
            workspace_path=launched["workspace_path"],
            manifest_path=launched["manifest_path"],
        )
        _jobs[job.job_id] = job
        self.addCleanup(lambda: _jobs.pop(job.job_id, None))
        _holistic_request_jobs["test-cancelled"] = job.job_id

        cancelled = hope_cancel_job(job.job_id)
        self.assertTrue(cancelled["ok"])
        self.assertEqual(cancelled["status"], "cancelled")

        _holistic_request_jobs.pop("test-cancelled", None)
        persisted = hope_holistic_status("test-cancelled")
        self.assertEqual(persisted["status"], "cancelled")


if __name__ == "__main__":
    unittest.main()
