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
include("read_input_data.jl")#read input data module
include("GTEP.jl")#capacity expansion model
include("PCM.jl")#production cost model
include("write_output.jl")#write output module
include("solver_config.jl")#setting solver parameters
include("DART.jl")#day-ahead and real-time operations
using .DART
include("operational_snapshot.jl") # installed-system snapshot and DART conversion
include("operational_state_contract.jl") # immutable chronological state exchange
include("dart_workflow.jl")        # standard DART case configuration and runner
include("solve.jl")                #solve model function
include("run.jl")                  #run module
include("erec.jl")                 #EREC postprocessing module
include("debug.jl")                #debug function
include("holistic_linkage.jl")     #auditable multi-resolution GTEP-PCM linkage
include("holistic_coverage.jl")    #machine-readable holistic coverage and acceptance
include("holistic_contract.jl")    #versioned handoff and physical-realization contracts
include("run_holistic.jl")         #Holistic assessment: GTEP-PCM two stage

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
export validate_holistic_handoff_contract
export validate_holistic_source_immutability!
export write_holistic_handoff_contract_report
export write_holistic_coverage_report
export write_operational_state_artifact
export solve_model
export solve_dart_sced
export solve_dart_scuc
export write_output

export marginal_load_price_from_dual

end
