using HOPE
using Test

@testset "HOPE.jl" begin
    include("test-basic-test.jl")
    include("test-time-mapping.jl")
    include("test-directional-transmission.jl")
    include("test-aggregation.jl")
    include("test-rep-day.jl")
    include("test-erec-core.jl")
    include("test-erec-endtoend.jl")
    include("test-gtep-output-regression.jl")
    include("test-erec-integration.jl")
    include("test-erec-settings.jl")
    include("test-erec-snapshot.jl")
    include("test-holistic.jl")
    include("test-holistic-linkage.jl")
    include("test-holistic-contract.jl")
    include("test-lmp-sign-regression.jl")
    include("test-pcm-constraints.jl")
    include("test-dart.jl")
    include("test-operational-snapshot.jl")
    include("test-operational-state-contract.jl")
    include("test-dart-workflow.jl")
end
