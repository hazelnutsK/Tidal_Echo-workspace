# Run manually to load bridge changes without restarting relay or the API body.
$ErrorActionPreference = 'Stop'
$bridgeRoot = $PSScriptRoot
$bridgeFile = Join-Path $bridgeRoot 'bridge.mjs'
$relayEnvFile = Join-Path (Split-Path $bridgeRoot -Parent) 'backend\relay.env'
$statusPort = 3031
foreach ($line in Get-Content -LiteralPath $relayEnvFile -Encoding UTF8) {
    if ($line -match '^\s*WECHAT_BRIDGE_PORT\s*=\s*["'']?(\d+)') {
        $statusPort = [int]$Matches[1]
    }
}
if ($env:WECHAT_BRIDGE_PORT) { $statusPort = [int]$env:WECHAT_BRIDGE_PORT }
if (-not (Test-Path -LiteralPath (Join-Path $bridgeRoot 'state\account.json'))) {
    throw 'WeChat login is required first.'
}
$nodePath = (Get-Command node.exe -ErrorAction Stop).Source
$listener = Get-NetTCPConnection -LocalPort $statusPort -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    $ownerId = @($listener.OwningProcess | Select-Object -Unique)
    if ($ownerId.Count -ne 1) { throw 'Unexpected status port owners; no process stopped.' }
    $bridgeProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $($ownerId[0])"
    if ($bridgeProcess.Name -ne 'node.exe' -or -not $bridgeProcess.CommandLine.Contains($bridgeFile)) {
        throw 'Status port belongs to another program; no process stopped.'
    }
    $nodePath = $bridgeProcess.ExecutablePath
    Stop-Process -Id $bridgeProcess.ProcessId
    Wait-Process -Id $bridgeProcess.ProcessId -Timeout 10 -ErrorAction SilentlyContinue
    if (Get-Process -Id $bridgeProcess.ProcessId -ErrorAction SilentlyContinue) {
        throw 'Old bridge has not exited; no replacement started.'
    }
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
foreach ($name in @('bridge.log', 'bridge.err.log')) {
    $logPath = Join-Path $bridgeRoot $name
    if (Test-Path -LiteralPath $logPath) {
        Copy-Item -LiteralPath $logPath -Destination "$logPath.$stamp"
    }
}
Start-Process -FilePath $nodePath -ArgumentList ('"' + $bridgeFile + '"') `
    -WorkingDirectory $bridgeRoot -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $bridgeRoot 'bridge.log') `
    -RedirectStandardError (Join-Path $bridgeRoot 'bridge.err.log') | Out-Null
foreach ($attempt in 1..10) {
    Start-Sleep -Seconds 1
    try { $status = Invoke-RestMethod -Uri "http://127.0.0.1:$statusPort/" -TimeoutSec 2 }
    catch { continue }
    if ($status.sse -like 'connected*') {
        Write-Host 'WeChat bridge restarted and connected to relay.'
        exit 0
    }
}
throw 'Bridge did not reconnect in time; check bridge.err.log and bridge.log.'
