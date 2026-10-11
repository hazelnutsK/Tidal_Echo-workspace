# Tidal Echo start-all: relay backend + cloudflared tunnel + api_loop + desktop body (CC channel or pbody)
# Run via qidong.cmd / right-click "Run with PowerShell".
# CC will show a "WARNING: Loading development channels" dialog -> press Enter once.
# ASCII only: PS 5.1 reads BOM-less .ps1 as GBK and chokes on UTF-8 Chinese.

$repo = $PSScriptRoot
if (-not $repo) { $repo = 'C:\Users\sxc\Tidal_Echo' }

# 1) relay backend (minimized window; closing the window stops it)
Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $repo 'backend\start.ps1') -WindowStyle Minimized

# 2) cloudflared tunnel (2026-09-15: log to file; her WiFi drops and I want the outage on record)
$logDir = Join-Path $repo 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$cfLog = Join-Path $logDir 'cloudflared.log'
if (Test-Path $cfLog) { Move-Item $cfLog "$cfLog.1" -Force }
Start-Process cloudflared -ArgumentList '--logfile',$cfLog,'--loglevel','info','tunnel','run','tidal-echo' -WindowStyle Minimized

# 3) api_loop (API body; phone can switch Desktop/API in settings)
Start-Process (Join-Path $repo 'backend\.venv\Scripts\python.exe') -ArgumentList (Join-Path $repo 'examples\api_loop.py') -WindowStyle Minimized -WorkingDirectory (Join-Path $repo 'examples')

# 3a) Codex app-server bridge (third switchable body; stays idle unless selected)
Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $repo 'start-codex.ps1') -WindowStyle Hidden

# 3b) eryu music player (vega.myaltair.uk -> :9090)
Start-Process (Join-Path $repo 'backend\.venv\Scripts\python.exe') -ArgumentList 'C:\Users\sxc\eryu\server\eryu.py' -WindowStyle Minimized -WorkingDirectory 'C:\Users\sxc\eryu\server'

# 3c) ears (voice tone analysis on :8020; relay falls back gracefully if absent)
Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\Users\sxc\ears\start-ears.ps1' -WindowStyle Minimized

# 3d) galatea garden wake bridge (SSE -> garden_inject.mjs -> relay hidden message)
# Env comes from garden-bridge\.env (holds the machine token); Start-Process inherits it.
Get-Content 'C:\Users\sxc\garden-bridge\.env' -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#')) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) {
            [Environment]::SetEnvironmentVariable($line.Substring(0, $i).Trim(), $line.Substring($i + 1).Trim(), 'Process')
        }
    }
}
Start-Process node.exe -ArgumentList 'C:\Users\sxc\garden-bridge\dist\cli.js','run' -WorkingDirectory 'C:\Users\sxc\garden-bridge' -WindowStyle Minimized -RedirectStandardOutput 'C:\Users\sxc\garden-bridge\bridge.log' -RedirectStandardError 'C:\Users\sxc\garden-bridge\bridge.err.log'

# 3e) wechat bridge (iLink ClawBot <-> relay; status on :3031). Skipped until she has scanned in
#     (wechat\state\account.json). Retries on its own while relay is still coming up.
if (Test-Path (Join-Path $repo 'wechat\state\account.json')) {
    Start-Process node.exe -ArgumentList (Join-Path $repo 'wechat\bridge.mjs') -WorkingDirectory (Join-Path $repo 'wechat') -WindowStyle Hidden -RedirectStandardOutput (Join-Path $repo 'wechat\bridge.log') -RedirectStandardError (Join-Path $repo 'wechat\bridge.err.log')
}

# 4) wait for relay
foreach ($i in 1..15) {
    try { Invoke-RestMethod http://127.0.0.1:3011/relay/healthz -TimeoutSec 2 | Out-Null; break }
    catch { Start-Sleep -Seconds 1 }
}

# Temporary VPS CC connection: retain PC services but do not launch a second CC.
$vpsMarker = Join-Path $repo 'backend\cc-on-vps.json'
if (Test-Path $vpsMarker) {
    $vpsBody = Get-Content $vpsMarker -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($vpsBody.enabled) {
        if (-not (Test-Path $vpsBody.forward_script)) { throw 'VPS relay forward script is missing.' }
        Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$vpsBody.forward_script -WindowStyle Hidden
        Write-Host 'CC runs on the VPS; PC relay and its SSH forward stay running.'
        return
    }
}

# 5) CC in foreground with the companion channel (press Enter at the dialog)
# RELAY_ACT_FEED=1 turns on the act_hook (tool calls show up as wrench chips on the phone).
# Only the channel CC gets this; manually-opened terminal CC sessions stay silent.
Set-Location $env:USERPROFILE
$env:RELAY_ACT_FEED = '1'
# Trim the vendor system prompt (~9k tokens of dev-workflow guidance the chat body
# never uses; her CLAUDE.md is the behaviour contract here). Measured 2026-09-09:
# 37,146 -> 28,117 tokens. Deliberately NOT set for manually-opened terminals.
$env:CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT = '1'
# 2026-09-24: pick up where the last window left off instead of a blank session.
# relay pins the live desktop sid in context_ctl.json (active_sid; forge/swap/resume
# all update it), so a window closed by accident comes back as itself on restart.
# Also carry desktop_model so the window matches what the phone set (_spawn_cc does
# the same). No active_sid / transcript gone -> fresh session as before.
# Force a blank window: set TE_FRESH=1 before running this script.
$ccArgs = @('--dangerously-skip-permissions', '--dangerously-load-development-channels', 'server:companion',
            '--settings', 'C:\Users\sxc\Tidal_Echo\backend\cc-settings.json')
try {
    $ctl = Get-Content (Join-Path $repo 'backend\context_ctl.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $sid = "$($ctl.active_sid)".Trim()
    $jsonl = Join-Path $env:USERPROFILE ".claude\projects\C--Users-sxc\$sid.jsonl"
    if ($env:TE_FRESH -ne '1' -and $sid -and (Test-Path $jsonl)) {
        $ccArgs += @('--resume', $sid)
        Write-Host "resuming desktop session $sid"
    } else {
        Write-Host 'starting a fresh desktop session'
    }
    $model = "$($ctl.desktop_model)".Trim()
    if ($model) { $ccArgs += @('--model', $model) }
} catch {
    Write-Host "context_ctl.json unreadable, starting fresh: $_"
}
# 2026-10-03: two kinds of desktop body. context_ctl.json desktop_body = 'pbody' runs the
# claude -p bridge (examples\pbody_bridge.py) in this window instead of interactive CC:
# no dev-channel dialog, its plain text goes straight to her. Same sid, same model.
$body = ''
try { $body = "$($ctl.desktop_body)".Trim() } catch {}
if (-not $body) { $body = "$env:RELAY_DESKTOP_BODY".Trim() }
if ($body -eq 'pbody') {
    $bridgeArgs = @((Join-Path $repo 'examples\pbody_bridge.py'), '--live')
    $i = [array]::IndexOf($ccArgs, '--resume')
    if ($i -ge 0) { $bridgeArgs += @('--resume', $ccArgs[$i + 1]) }
    Write-Host 'desktop body: pbody (claude -p bridge)'
    & (Join-Path $repo 'backend\.venv\Scripts\python.exe') @bridgeArgs
} else {
    claude @ccArgs
}
