@echo off
rem Fix the "CC double-replies to API-window chats" bug:
rem 1) syntax-check the edited api_loop.py (abort if broken)
rem 2) re-mark orphaned API-window messages so CC won't replay them
rem 3) restart api_loop via the existing restart-api.cmd

set PY=C:\Users\sxc\Tidal_Echo\backend\.venv\Scripts\python.exe

"%PY%" -c "import ast; ast.parse(open(r'C:\Users\sxc\Tidal_Echo\examples\api_loop.py',encoding='utf-8').read()); print('api_loop.py syntax OK')"
if errorlevel 1 (
  echo api_loop.py syntax check FAILED - stopping, nothing restarted
  exit /b 1
)

"%PY%" C:\Users\sxc\Tidal_Echo\remark-loop-messages.py
if errorlevel 1 (
  echo re-mark script FAILED - stopping before restart
  exit /b 1
)

call C:\Users\sxc\Tidal_Echo\restart-api.cmd
