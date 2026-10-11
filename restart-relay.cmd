@echo off
rem Syntax-check backend + frontend, then restart the relay (port 3011).
rem Aborts BEFORE touching the relay if any check fails.

"C:\Users\sxc\Tidal_Echo\backend\.venv\Scripts\python.exe" -c "import ast; ast.parse(open(r'C:\Users\sxc\Tidal_Echo\backend\app.py',encoding='utf-8').read()); print('app.py syntax OK')"
if errorlevel 1 (
  echo app.py syntax check FAILED - relay NOT restarted
  exit /b 1
)

node "C:\Users\sxc\Tidal_Echo\check-inline-scripts.js"
if errorlevel 1 (
  echo index.html inline-script check FAILED - relay NOT restarted
  exit /b 1
)

echo Killing relay on :3011 and restarting via backend\start.ps1 ...
rem Kill by COMMAND LINE first, then by port. A relay that lost its listener but
rem still runs its asyncio watchers (desire/night/reply-guard) is invisible to
rem Get-NetTCPConnection - that is how a stale instance survived 20 days and kept
rem firing ghost desire pulses at api_loop. Name filter keeps this query from
rem matching itself.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-CimInstance Win32_Process -Filter \"Name like 'python%%'\" | Where-Object { $_.CommandLine -match 'Tidal_Echo\\backend\\app\.py' } | ForEach-Object { Write-Output ('killing stale relay pid ' + $_.ProcessId); try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} };" ^
  "Get-NetTCPConnection -LocalPort 3011 -State Listen -ErrorAction SilentlyContinue | ForEach-Object { try { Stop-Process -Id $_.OwningProcess -Force -ErrorAction Stop } catch {} };" ^
  "Start-Process powershell -ArgumentList '-ExecutionPolicy','Bypass','-File','C:\Users\sxc\Tidal_Echo\backend\start.ps1' -WindowStyle Minimized"

rem NOTE: healthz lives on the mounted sub-app -> /relay/healthz (root /healthz is 404)
powershell -NoProfile -Command "for($i=0;$i -lt 20;$i++){ try{ $r=Invoke-WebRequest -UseBasicParsing http://127.0.0.1:3011/relay/healthz -TimeoutSec 2; if($r.StatusCode -eq 200){ Write-Output 'relay healthz OK'; exit 0 } }catch{}; Start-Sleep -Seconds 1 }; Write-Output 'relay did NOT come back - check the minimized window'; exit 1"
