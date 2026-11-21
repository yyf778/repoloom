@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\stop_repoloom.ps1" -StopInfrastructure
if errorlevel 1 pause
