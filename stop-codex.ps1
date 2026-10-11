# Stop only the Tidal Echo Codex bridge started by start-codex.ps1.

$repo = $PSScriptRoot
if (-not $repo) { $repo = 'C:\Users\sxc\Tidal_Echo' }
$pidFile = Join-Path $repo 'examples\codex-bridge.pid'
$bridgePath = Join-Path $repo 'examples\codex_app_server_bridge.py'
$all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
$roots = @($all | Where-Object {
    $_.CommandLine -and $_.CommandLine.IndexOf($bridgePath, [StringComparison]::OrdinalIgnoreCase) -ge 0
})

# The Windows venv launcher can leave its real python child alive after the
# launcher PID is killed. Stop every matching process plus descendants.
$ids = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($rootProcess in $roots) { [void]$ids.Add([int]$rootProcess.ProcessId) }
$changed = $true
while ($changed) {
    $changed = $false
    foreach ($process in $all) {
        if ($ids.Contains([int]$process.ParentProcessId) -and $ids.Add([int]$process.ProcessId)) {
            $changed = $true
        }
    }
}
foreach ($processId in @($ids) | Sort-Object -Descending) {
    Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
}
if ($roots.Count) {
    Write-Host ("Codex bridge stopped ({0} process nodes)" -f $ids.Count)
} else {
    Write-Host 'Codex bridge is not running.'
}
Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
