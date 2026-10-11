@echo off
rem Restart api_loop only (relay/tunnel/CC untouched), then print /loop/stats.
rem ASCII only in this file (GBK parsing rule for cmd/PS 5.1).
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-CimInstance Win32_Process -Filter \"Name like 'python%%'\" | Where-Object { $_.CommandLine -match 'api_loop\.py' } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -Confirm:$false -ErrorAction Stop } catch {} };" ^
  "Start-Process 'C:\Users\sxc\Tidal_Echo\backend\.venv\Scripts\python.exe' -ArgumentList '-X','utf8','C:\Users\sxc\Tidal_Echo\examples\api_loop.py' -WindowStyle Minimized -WorkingDirectory 'C:\Users\sxc\Tidal_Echo\examples' -RedirectStandardOutput 'C:\Users\sxc\Tidal_Echo\examples\api_loop.out.log' -RedirectStandardError 'C:\Users\sxc\Tidal_Echo\examples\api_loop.err.log';" ^
  "Start-Sleep -Seconds 5;" ^
  "try { Invoke-RestMethod http://127.0.0.1:3020/loop/stats -TimeoutSec 15 | ConvertTo-Json -Depth 4 } catch { 'stats check failed: ' + $_ }"
