@echo off
rem Launch PerfWidget without a console window
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0PerfWidget.ps1"
