[CmdletBinding()]
param(
    [ValidateSet("gurobi", "highs", "cbc", "clp", "scip", "cplex")]
    [string]$Solver = "gurobi",

    [ValidateRange(1, 12)]
    [int]$Month = 7,

    [ValidateRange(60, 86400)]
    [int]$TimeoutSeconds = 3600
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$mcpRoot = Join-Path $repoRoot "tools\hope_mcp_server"
$defaultModelCases = Join-Path $repoRoot "ModelCases"
$modelCasesRoot = if ($env:HOPE_MODELCASES_PATH) {
    (Resolve-Path $env:HOPE_MODELCASES_PATH).Path
} else {
    (Resolve-Path $defaultModelCases).Path
}
$workRoot = Join-Path $repoRoot "artifacts\agent_test_work"
$uv = (Get-Command uv -ErrorAction Stop).Source

$environmentUpdates = [ordered]@{
    HOPE_REPO_ROOT                                  = $repoRoot
    HOPE_MODELCASES_PATH                            = $modelCasesRoot
    HOPE_AGENT_TEST_WORK_ROOT                       = $workRoot
    HOPE_RUN_HOLISTIC_AGENT_MD_JULY_INTEGRATION    = "1"
    HOPE_HOLISTIC_AGENT_MD_JULY_SOLVER              = $Solver
    HOPE_HOLISTIC_AGENT_MD_JULY_MONTH               = "$Month"
    HOPE_HOLISTIC_AGENT_MD_JULY_TIMEOUT             = "$TimeoutSeconds"
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

    Write-Host "Running annual GTEP / month-$Month nodal PCM agent integration test."
    Write-Host "Solver: $Solver"
    Write-Host "ModelCases: $modelCasesRoot"
    Write-Host "Temporary work root: $workRoot"

    & $uv `
        --directory $mcpRoot `
        run python -m unittest discover `
        -s tests `
        -p test_holistic_agent_md_july_integration.py `
        -v

    if ($LASTEXITCODE -ne 0) {
        throw "High-resolution holistic agent integration test failed with exit code $LASTEXITCODE."
    }
} finally {
    foreach ($entry in $previousEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }
}
