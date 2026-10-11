# Tidal Echo start-api-only: relay backend + cloudflared tunnel + api_loop, NO CC.
# For running without a Claude subscription (API brain only).
# Remember to set brain to API in the phone settings (persisted in backend\brain_target).
# ASCII only: PS 5.1 reads BOM-less .ps1 as GBK and chokes on UTF-8 Chinese.

$repo = $PSScriptRoot
if (-not $repo) { $repo = 'C:\Users\sxc\Tidal_Echo' }

# 1) relay backend (minimized window; closing the window stops it)
Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $repo 'backend\start.ps1') -WindowStyle Minimized

# 2) cloudflared tunnel
Start-Process cloudflared -ArgumentList 'tunnel','run','tidal-echo' -WindowStyle Minimized

# 3) api_loop (API body)
Start-Process (Join-Path $repo 'backend\.venv\Scripts\python.exe') -ArgumentList (Join-Path $repo 'examples\api_loop.py') -WindowStyle Minimized -WorkingDirectory (Join-Path $repo 'examples')

# 3a) WeChat is another relay entrance for the active API session.
if (Test-Path (Join-Path $repo 'wechat\state\account.json')) {
    $wechatRunning = Get-NetTCPConnection -LocalPort 3031 -State Listen -ErrorAction SilentlyContinue
    if (-not $wechatRunning) {
        Start-Process node.exe -ArgumentList (Join-Path $repo 'wechat\bridge.mjs') -WorkingDirectory (Join-Path $repo 'wechat') -WindowStyle Hidden -RedirectStandardOutput (Join-Path $repo 'wechat\bridge.log') -RedirectStandardError (Join-Path $repo 'wechat\bridge.err.log')
    }
}

# 3b) eryu music player (vega.myaltair.uk -> :9090)
Start-Process (Join-Path $repo 'backend\.venv\Scripts\python.exe') -ArgumentList 'C:\Users\sxc\eryu\server\eryu.py' -WindowStyle Minimized -WorkingDirectory 'C:\Users\sxc\eryu\server'

# 4) wait for relay, then make sure brain=loop so messages go to the API body
$ok = $false
foreach ($i in 1..15) {
    try { Invoke-RestMethod http://127.0.0.1:3011/relay/healthz -TimeoutSec 2 | Out-Null; $ok = $true; break }
    catch { Start-Sleep -Seconds 1 }
}
if ($ok) {
    try {
        $secret = ''
        foreach ($line in (Get-Content (Join-Path $repo 'backend\relay.env') -Encoding UTF8)) {
            if ($line -match '^\s*RELAY_SECRET\s*=\s*(.+)\s*$') { $secret = $Matches[1].Trim() }
        }
        if ($secret) {
            Invoke-RestMethod -Method Post -Uri http://127.0.0.1:3011/relay/app/brain `
                -Headers @{ Authorization = "Bearer $secret"; 'Content-Type' = 'application/json' } `
                -Body '{"target":"loop"}' -TimeoutSec 5 | Out-Null
            Write-Host 'brain set to loop (API body).'
        }
    } catch { Write-Host "brain switch failed (set it in phone settings): $($_.Exception.Message)" }
    Write-Host 'API-only stack is up: relay + tunnel + api_loop. No CC.'
} else {
    Write-Host 'relay did not come up on :3011 -- check the minimized relay window.'
}
Start-Sleep -Seconds 3
