@echo off
setlocal
set SCRIPT_DIR=%~dp0
set PROJECT_DIR=%SCRIPT_DIR%..
python "%PROJECT_DIR%\scripts\ui_launcher.py" %*
