@echo off
rem Double-click this. It runs a read-only survey of this computer and puts
rem two report files on the Desktop to send to Mark. Nothing is changed.
title Honeycomb flight-sim survey
echo.
echo  Surveying this computer for the Honeycomb launcher. This takes a few seconds.
echo  Nothing will be changed.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Survey-Machine.ps1"
echo.
echo  Press any key to close this window.
pause >nul
