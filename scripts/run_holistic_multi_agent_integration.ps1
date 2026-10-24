[CmdletBinding()]
param(
    [ValidateSet("gurobi", "highs", "cbc", "clp", "scip", "cplex")]
    [string]$Solver = "gurobi",

    [ValidateRange(60, 86400)]
    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$mcpRoot = Join-Path $repoRoot "tools\hope_mcp_server"
$modelCasesRoot = if ($env:HOPE_MODELCASES_PATH) {
    (Resolve-Path $env:HOPE_MODELCASES_PATH).Path
} else {
    (Resolve-Path (Join-Path $repoRoot "ModelCases")).Path
}
$uv = (Get-Command uv -ErrorAction Stop).Source

$environmentUpdates = [ordered]@{
    HOPE_REPO_ROOT                              = $repoRoot
    HOPE_MODELCASES_PATH                        = $modelCasesRoot
    HOPE_RUN_HOLISTIC_MULTI_AGENT_INTEGRATION  = "1"
    HOPE_HOLISTIC_AGENT_SOLVER                  = $Solver
    HOPE_HOLISTIC_AGENT_TIMEOUT                 = "$TimeoutSeconds"
}
$previousEnvironment = @{}

try {
    foreach ($entry in $environmentUpdates.GetEnumerator()) {
        $previousEnvironment[$entry.Key] = [Environment]::GetEnvironmentVariable(
            $entry.Key,
            "Process"
        )
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }

    Write-Host "Running the role-separated coordinator / executor / auditor integration test."
    Write-Host "Solver: $Solver"
    Write-Host "ModelCases: $modelCasesRoot"

    & $uv `
        --directory $mcpRoot `
        run python -m unittest discover `
        -s tests `
        -p test_holistic_multi_agent_integration.py `
        -v

    if ($LASTEXITCODE -ne 0) {
        throw "Holistic multi-agent integration test failed with exit code $LASTEXITCODE."
    }
} finally {
    foreach ($entry in $previousEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }
}
