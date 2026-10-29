module HOPE
##using package##

using JuMP
using DataFrames
using CSV
using XLSX
using LinearAlgebra
using YAML
using Dates
using Clustering
using Distances
using Combinatorics
using Statistics
using SHA

##using solver##
# Open-source solvers are loaded unconditionally.
# Commercial solvers (Gurobi, SCIP, CPLEX) are wired through Julia package
# extensions so they remain optional for users who do not install them.
using Cbc
using HiGHS
using GLPK

# Clp.jl cannot initialize on Apple Silicon. Keep the rest of HOPE loadable on
# that platform; requesting Clp still produces a clear error in initiate_solver.
@static if Sys.isapple() && Sys.ARCH == :aarch64
    const CLP_AVAILABLE = false
else
    using Clp
    const CLP_AVAILABLE = true
end

#include HOPE module scripts
include("constants.jl")            #shared constants and configuration
include("utils.jl")                #utility functions
include("rep_day.jl")              #representative-day utilities
include("aggregation.jl")          #resource aggregation settings/utilities
include("network_utils.jl")        #network/DCOPF helper utilities
include("holistic_operational_templates.jl") #PCM operating templates for GTEP builds
include("read_input_data.jl")#read input data module
include("GTEP.jl")#capacity expansion model
include("PCM.jl")#production cost model
include("write_output.jl")#write output module
include("solver_config.jl")#setting solver parameters
include("DART.jl")#day-ahead and real-time operations
using .DART
include("operational_snapshot.jl") # installed-system snapshot and DART conversion
include("operational_state_contract.jl") # immutable chronological state exchange
include("pcm_state_adapter.jl")     # explicit PCM boundary to DART state adapter
include("dart_workflow.jl")        # standard DART case configuration and runner
include("solve.jl")                #solve model function
include("run.jl")                  #run module
include("erec.jl")                 #EREC postprocessing module
include("debug.jl")                #debug function
include("holistic_linkage.jl")     #auditable multi-resolution GTEP-PCM linkage
include("computed_realization.jl") #deterministic zonal-to-nodal site allocation
include("computed_realization_handoff.jl") #GTEP/PCM adapters for computed allocation
include("holistic_coverage.jl")    #machine-readable holistic coverage and acceptance
include("realization_ensemble.jl") #multi-realization PCM preparation and assessment
include("adaptive_feedback.jl")   #typed findings and approval-gated revision requests
include("adaptive_study.jl")      #bounded adaptive-study orchestration state machine
include("holistic_contract.jl")    #versioned handoff and physical-realization contracts
include("run_holistic.jl")         #Holistic assessment: GTEP-PCM two stage
include("gtep_child_scenario.jl")  #approval-gated immutable GTEP child cases
include("planning_feedback_diagnostic.jl") #planning evidence before revision
include("compact_planning_experiment.jl") #compact RPS plan and project unitization
include("holistic_benchmark.jl")   #Deterministic solved-value and handoff evidence

#export HOPE functions
export aggregate_gendata_gtep
export aggregate_gendata_pcm
export create_GTEP_model
export create_PCM_model
export advance_dart_state
export build_dart_sced_model
export build_dart_scuc_model
export calculate_dart_settlements
export calculate_erec
export calculate_erec_from_output
export DART
export DARTConfig
export DARTDispatchResult
export DARTForecast
export DARTForecastSet
export DARTGenerator
export DARTNetwork
export DARTReserveProduct
export DARTRollingResult
export DARTSettlementResult
export DARTState
export DARTStorage
export DARTSystemData
export OperationalBranch
export OperationalBus
export OperationalGenerator
export OperationalSnapshot
export OperationalStorage
export OperationalStateArtifact
export build_dart_forecasts
export build_dart_initial_state
export build_dart_system
export build_pcm_operational_state
export dart_system_fingerprint
export default_dart_reserve_products
export default_dart_state
export default_aggregation_settings
export default_erec_settings
export default_rep_day_settings
export initiate_solver
export build_endogenous_rep_periods
export load_data
export load_dart_case
export load_aggregation_settings
export load_operational_snapshot
export load_operational_state_artifact
export load_erec_settings
export load_rep_day_settings
export load_postprocess_snapshot
export resolve_rep_day_time_periods
export run_dart_rolling
export run_dart_case
export run_hope
export validate_dart_case
export validate_dart_settings
export validate_hope
export select_dart_windows
export run_hope_holistic
export run_hope_holistic_fresh
export holistic_coverage_metrics
export holistic_model_activity_metrics
export holistic_case_fingerprint
export load_holistic_physical_realization
export compute_nodal_realizations
export build_candidate_site_catalog_from_pcm
export build_computed_realization_handoff_from_contract
export capacity_plan_from_gtep
export materialize_computed_realization_handoff
export prepare_pcm_inputs_from_computed_realization
export screen_computed_realization
export load_capacity_plan
export load_candidate_site_catalog
export load_realization_policy
export validate_candidate_site_catalog
export validate_capacity_plan
export validate_realization_policy
export write_computed_realization_set
export capacity_plan_to_gtep_fixture
export prepare_pcm_realization_ensemble
export assess_pcm_realization_ensemble
export build_holistic_feedback
export load_feedback_policy
export record_revision_decision
export validate_feedback_policy
export write_holistic_feedback_package
export validate_holistic_study_spec
export load_holistic_study_spec
export initialize_adaptive_study
export record_adaptive_stage
export evaluate_ensemble_acceptance
export verify_adaptive_study
export request_adaptive_revision
export record_adaptive_revision_decision
export start_adaptive_child_iteration
export stop_adaptive_study
export run_adaptive_study_iteration
export write_adaptive_study_state
export build_gtep_child_scenario_spec
export materialize_approved_gtep_child_scenario
export validate_gtep_child_scenario_spec
export diagnose_gtep_feedback_context
export write_gtep_feedback_diagnostic
export materialize_compact_gtep_case
export materialize_compact_rps_gtep_case
export unitize_capacity_plan
export add_compact_planning_proxies_to_pcm
export build_unitized_project_catalog
export load_operational_resource_templates
export validate_operational_resource_templates
export validate_holistic_handoff_contract
export validate_holistic_transfer_reconciliation
export validate_holistic_source_immutability!
export write_holistic_handoff_contract_report
export write_holistic_coverage_report
export write_holistic_benchmark_report
export write_operational_state_artifact
export write_pcm_operational_state_artifact
export solve_model
export solve_dart_sced
export solve_dart_scuc
export write_output

export marginal_load_price_from_dual

end
