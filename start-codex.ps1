# Start the local Tidal Echo Codex app-server bridge.
# Runtime secrets are loaded by the bridge from examples\.env.

$repo = $PSScriptRoot
if (-not $repo) { $repo = 'C:\Users\sxc\Tidal_Echo' }

$pidFile = Join-Path $repo 'examples\codex-bridge.pid'
$bridge = Join-Path $repo 'examples\codex_app_server_bridge.py'

# A stale/missing pid file must not start a second logical bridge. Windows can
# keep the venv launcher's child alive with the same command line.
$existing = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and $_.CommandLine.IndexOf($bridge, [StringComparison]::OrdinalIgnoreCase) -ge 0
}) | Select-Object -First 1
if ($existing) {
    $existing.ProcessId | Set-Content -LiteralPath $pidFile -Encoding ASCII
    Write-Host ("Codex bridge already running (pid {0})" -f $existing.ProcessId)
    exit 0
}

if (Test-Path -LiteralPath $pidFile) {
    $oldPid = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($oldPid) {
        $oldProcess = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f [int]$oldPid) -ErrorAction SilentlyContinue
        if ($oldProcess -and $oldProcess.CommandLine -like '*codex_app_server_bridge.py*') {
            Write-Host ("Codex bridge already running (pid {0})" -f $oldPid)
            exit 0
        }
    }
}

$python = Join-Path $repo 'backend\.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) { $python = 'python' }
$stdout = Join-Path $repo 'examples\codex-bridge.out.log'
$stderr = Join-Path $repo 'examples\codex-bridge.err.log'

$process = Start-Process $python -ArgumentList $bridge -WorkingDirectory (Join-Path $repo 'examples') `
    -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
$process.Id | Set-Content -LiteralPath $pidFile -Encoding ASCII
Write-Host ("Codex bridge started (pid {0})" -f $process.Id)
