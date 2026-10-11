# Tidal Echo stop-all: relay(:3011) + api_loop(:3020) + cloudflared
# Does NOT kill an interactive CC - close the CC terminal window yourself (a pbody bridge IS stopped).
# ASCII only: PS 5.1 reads BOM-less .ps1 as GBK and chokes on UTF-8 Chinese.

# Kill by COMMAND LINE first. A process that lost its listener but still runs its
# asyncio watchers is invisible to Get-NetTCPConnection - that is how a stale relay
# survived 20 days and kept firing ghost desire pulses at api_loop.
# The Name filter keeps this query from matching itself (powershell.exe is not python).
foreach ($pat in 'Tidal_Echo\\backend\\app\.py', 'Tidal_Echo\\examples\\api_loop\.py', 'Tidal_Echo\\wechat\\bridge\.mjs') {
    Get-CimInstance Win32_Process -Filter "Name like 'python%' or Name = 'node.exe'" |
        Where-Object { $_.CommandLine -match $pat } |
        ForEach-Object {
            Write-Host ("stopped pid {0} ({1})" -f $_.ProcessId, $pat)
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
        }
}

# pbody bridge (claude -p desktop body): taskkill /T so its claude child goes with it.
Get-CimInstance Win32_Process -Filter "Name like 'python%'" |
    Where-Object { $_.CommandLine -match 'pbody_bridge\.py' } |
    ForEach-Object {
        Write-Host ("stopped pid {0} (pbody bridge)" -f $_.ProcessId)
        taskkill /PID $_.ProcessId /T /F | Out-Null
    }

# Then by port, in case something non-python is squatting on them.
foreach ($port in 3011, 3020) {
    try {
        $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop
        foreach ($p in ($conns.OwningProcess | Sort-Object -Unique)) {
            $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Host ("stopped {0} (pid {1}, port {2})" -f $proc.ProcessName, $p, $port)
                Stop-Process -Id $p -Force
            }
        }
    } catch { Write-Host "port $port : nothing listening" }
}

$cf = Get-Process cloudflared -ErrorAction SilentlyContinue
if ($cf) { $cf | Stop-Process -Force; Write-Host "cloudflared stopped" }
else { Write-Host "cloudflared not running" }

& (Join-Path $PSScriptRoot 'stop-codex.ps1')

Write-Host ""
Write-Host "Done. Close the CC window manually, then run start-all."
