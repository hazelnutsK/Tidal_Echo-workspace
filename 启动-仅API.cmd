@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-api-only.ps1"
if errorlevel 1 pause
