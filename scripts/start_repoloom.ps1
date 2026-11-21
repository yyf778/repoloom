param([switch]$SkipInfrastructure)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$backend = Join-Path $root 'backend'
$frontend = Join-Path $root 'frontend'
$data = Join-Path $root '.data'
$python = Join-Path $backend '.venv/Scripts/python.exe'
$node = Get-ChildItem (Join-Path $root '.tools/node-*-win-x64/node.exe') -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (-not $node) { $node = (Get-Command node.exe -ErrorAction Stop).Source }
if (-not (Test-Path -LiteralPath $python)) { throw 'Backend virtual environment is missing.' }
if (-not (Test-Path -LiteralPath (Join-Path $frontend '.next/BUILD_ID'))) { throw 'Build the frontend first: npm run build --prefix frontend' }
if (-not (Test-Path -LiteralPath (Join-Path $root '.env'))) { throw 'Project .env is missing.' }
New-Item -ItemType Directory -Path $data -Force | Out-Null
$env:PATH = (Split-Path -Parent $node) + ';' + $env:PATH
$env:PYTHONPATH = $backend
$env:PYTHONUNBUFFERED = '1'
$env:PYTHONUTF8 = '1'
$env:OMP_NUM_THREADS = '6'
$env:MKL_NUM_THREADS = '6'
$env:TOKENIZERS_PARALLELISM = 'false'
$env:HF_HUB_OFFLINE = '1'
$env:HF_HUB_DISABLE_PROGRESS_BARS = '1'
$env:NEXT_TELEMETRY_DISABLED = '1'
$env:NO_PROXY = 'localhost,127.0.0.1,::1'
# httpx and Git use proxy environment variables rather than Windows proxy settings.
$proxy = Get-ItemProperty 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Internet Settings' -ErrorAction SilentlyContinue
if ($proxy.ProxyEnable -and $proxy.ProxyServer -and $proxy.ProxyServer -notmatch '=') {
    $proxyUrl = [string]$proxy.ProxyServer
    if ($proxyUrl -notmatch '^https?://') { $proxyUrl = 'http://' + $proxyUrl }
    $env:HTTP_PROXY = $proxyUrl
    $env:HTTPS_PROXY = $proxyUrl
}
$docker = $null
if (-not $SkipInfrastructure) {
    $dockerCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs/DockerDesktop/resources/bin/docker.exe'),
        'C:/Program Files/Docker/Docker/resources/bin/docker.exe'
    )
    $docker = $dockerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $docker) { $docker = (Get-Command docker.exe -ErrorAction Stop).Source }
    $env:PATH = (Split-Path -Parent $docker) + ';' + $env:PATH
    & $docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $desktop = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $docker))) 'Docker Desktop.exe'
        if (Test-Path -LiteralPath $desktop) { Start-Process -FilePath $desktop -WindowStyle Hidden }
        Write-Host 'Waiting for Docker Desktop...'
        $ready = $false
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            Start-Sleep -Seconds 2
            & $docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        }
        if (-not $ready) { throw 'Docker engine is unavailable. Check Docker Desktop / WSL, then retry.' }
    }
    $composeArgs = @('compose', '--project-directory', $root, '-f', (Join-Path $root 'docker-compose.yml'))
    & $docker @composeArgs up -d postgres etcd minio milvus
    if ($LASTEXITCODE -ne 0) { throw 'Infrastructure startup failed.' }
    Write-Host 'Waiting for PostgreSQL and Milvus...'
    $ready = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        $postgresId = & $docker @composeArgs ps -q postgres 2>$null
        $postgresReady = $false
        if ($LASTEXITCODE -eq 0 -and $postgresId) {
            $postgresReady = (& $docker inspect --format '{{.State.Health.Status}}' $postgresId 2>$null) -eq 'healthy'
        }
        try {
            $null = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:9091/healthz' -TimeoutSec 2
            if ($postgresReady) { $ready = $true; break }
        } catch {}
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw 'PostgreSQL or Milvus did not become healthy. Inspect docker compose logs.' }
}
$processFile = Join-Path $data 'processes.json'
$tracked = @()
if (Test-Path -LiteralPath $processFile) { $tracked = Get-Content -LiteralPath $processFile -Raw | ConvertFrom-Json }
function Start-LocalService($name, $port, $exe, $arguments, $directory, $uri) {
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
    if ($listeners.Count -gt 0) {
        $saved = @($script:tracked | Where-Object name -eq $name)
        $running = if ($saved.Count -eq 1) { Get-Process -Id $saved[0].pid -ErrorAction SilentlyContinue }
        if (-not $running -or $running.StartTime.ToUniversalTime().Ticks -ne ([datetime]$saved[0].started_utc).ToUniversalTime().Ticks) {
            throw "Port $port is occupied by an untracked service. Stop it or choose another port."
        }
        $null = Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 5
        Write-Host "$name already running: $uri"
        return
    }
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $directory -RedirectStandardOutput (Join-Path $data "$name.out.log") -RedirectStandardError (Join-Path $data "$name.err.log") -WindowStyle Hidden -PassThru
    $script:tracked = @($script:tracked | Where-Object name -ne $name) + @(@{ name = $name; pid = $process.Id; started_utc = $process.StartTime.ToUniversalTime().ToString('o') })
    ConvertTo-Json -InputObject @($script:tracked) | Set-Content -LiteralPath $processFile -Encoding UTF8
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        if ($process.HasExited) { throw "$name exited. See .data/$name.err.log" }
        try {
            $null = Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 2
            Write-Host "$name ready: $uri"
            return
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    throw "$name did not become ready. See .data/$name.err.log"
}
Start-LocalService 'backend' 8000 $python @('-m', 'uvicorn', 'app.main:app', '--host', '127.0.0.1', '--port', '8000') $backend 'http://127.0.0.1:8000/health'
Start-LocalService 'frontend' 3000 $node @('node_modules/next/dist/bin/next', 'start', '--hostname', '127.0.0.1', '--port', '3000') $frontend 'http://127.0.0.1:3000'
Write-Host 'RepoLoom: http://127.0.0.1:3000'
Write-Host 'API docs:   http://127.0.0.1:8000/docs'
