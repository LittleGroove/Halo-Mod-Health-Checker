@echo off
rem Halo Mod Health Checker: checks a mods folder and says what's wrong with each mod.
rem Run it and type (or drag in) the folder, or drag the folder onto this file.
rem The report is shown here and saved in the logs folder next to this file.
rem Everything below is in one block, so an update that replaces this file can't trip it up.
(
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0checkmodhealth.ps1" %*
  exit /b
)
