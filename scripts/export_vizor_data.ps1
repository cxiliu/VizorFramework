# Exports the sessions Vizor Web Control logged to MongoDB into plain files under data\, one folder
# per session with a CSV per ROS topic (see export_vizor_data.js for the layout).
#
# The export itself runs inside the vizor-mongo container with mongosh, so this needs only Docker -
# no Python or MongoDB driver on this machine. The web console stack must be running.
#
# Usage:
#   ExportVizorData.bat                                      # every session
#   .\scripts\export_vizor_data.ps1 -Participant collabfab-test
#   .\scripts\export_vizor_data.ps1 -SessionId 6adf093351ee9d069f24dac3
#   .\scripts\export_vizor_data.ps1 -OutDir D:\study\raw
#
# Re-running overwrites a session's folder with a fresh snapshot, so exporting a session that was
# still in progress and then exporting again once it ends is safe. Nothing is deleted from MongoDB.

param(
    # Checked here so a typo fails with a clear message rather than a mongosh BSONError.
    [ValidatePattern('^[0-9a-fA-F]{24}$')]
    [string]$SessionId,
    [string]$Participant,
    [string]$OutDir,
    [string]$Database = 'vizor_ros_logger'
)

$ErrorActionPreference = 'Stop'
$FrameworkRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $PSScriptRoot 'VizorCommon.ps1')

if (-not $OutDir) { $OutDir = Join-Path $FrameworkRoot 'data' }
# Made absolute against PowerShell's location: docker resolves a relative path against the process
# working directory, which Windows PowerShell does not update on cd.
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)

$container = 'vizor-mongo'
if ((Get-RunningContainers -Names @($container)).Count -eq 0) {
    throw "$container is not running. Start the web console with StartVizor.bat first - the logged data is kept in its volume while it is stopped."
}

# A fresh scratch folder per run inside the container, so a previous run's leftovers - or a
# session filtered out this time - never get copied out alongside this run's files.
$runId = [guid]::NewGuid().ToString('N')
$remoteScript = "/tmp/export_vizor_data_$runId.js"
$remoteOut = "/tmp/vizor_export_$runId"

docker cp (Join-Path $PSScriptRoot 'export_vizor_data.js') "${container}:$remoteScript" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not copy the export script into $container." }

try {
    Write-Host "Exporting from $Database to $OutDir ..."
    docker exec -e "OUT_DIR=$remoteOut" -e "SESSION_ID=$SessionId" -e "PARTICIPANT=$Participant" `
        $container mongosh --quiet $Database $remoteScript
    if ($LASTEXITCODE -ne 0) { throw "mongosh export failed (exit code $LASTEXITCODE)." }

    # Nothing matched means mongosh never created the folder; there is nothing to copy.
    docker exec $container test -d $remoteOut
    if ($LASTEXITCODE -eq 0) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        # The trailing '/.' copies the folder's contents into $OutDir rather than nesting it.
        docker cp "${container}:$remoteOut/." $OutDir | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not copy the exported files out of $container." }
        Write-Host "Done. Files are in $OutDir"
    }
} finally {
    docker exec $container rm -rf $remoteScript $remoteOut | Out-Null
}
