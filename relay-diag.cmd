@echo off
rem Start the relay with output captured to backend\relay-diag.log,
rem wait for healthz, and print the log if it does not come up.

rem clear any half-started leftovers on :3011 first
powershell -NoProfile -Command "Get-NetTCPConnection -LocalPort 3011 -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }"

start "relay-logged" /min powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\sxc\Tidal_Echo\backend\start-logged.ps1

powershell -NoProfile -Command "for($i=0;$i -lt 15;$i++){ try{ $r=Invoke-WebRequest -UseBasicParsing http://127.0.0.1:3011/relay/healthz -TimeoutSec 2; if($r.StatusCode -eq 200){ Write-Output 'relay healthz OK'; exit 0 } }catch{}; Start-Sleep -Seconds 1 }; Write-Output '--- startup failed, relay-diag.log tail ---'; Get-Content C:\Users\sxc\Tidal_Echo\backend\relay-diag.log -Tail 50"
