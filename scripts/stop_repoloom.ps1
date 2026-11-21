param([switch]$StopInfrastructure)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$processFile = Join-Path $root '.data/processes.json'
function Stop-TrackedTree([int]$processId) {
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$processId" -ErrorAction SilentlyContinue)
    foreach ($child in $children) { Stop-TrackedTree $child.ProcessId }
    Stop-Process -Id $processId -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $processFile) {
    foreach ($entry in (Get-Content -LiteralPath $processFile -Raw | ConvertFrom-Json)) {
        $process = Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
        if ($process -and $process.StartTime.ToUniversalTime().Ticks -eq ([datetime]$entry.started_utc).ToUniversalTime().Ticks) {
            Stop-TrackedTree $process.Id
            Write-Host "Stopped $($entry.name)"
        }
    }
    '[]' | Set-Content -LiteralPath $processFile -Encoding UTF8
}
if ($StopInfrastructure) {
    $docker = Join-Path $env:LOCALAPPDATA 'Programs/DockerDesktop/resources/bin/docker.exe'
    if (-not (Test-Path -LiteralPath $docker)) { $docker = (Get-Command docker.exe -ErrorAction Stop).Source }
    & $docker compose --project-directory $root -f (Join-Path $root 'docker-compose.yml') stop postgres etcd minio milvus
    if ($LASTEXITCODE -ne 0) { throw 'Could not stop infrastructure.' }
}
