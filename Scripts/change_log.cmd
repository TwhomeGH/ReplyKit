@echo off
chcp 65001 >nul
setlocal

rem Find Python: prefer "python", fall back to the "py" launcher.
set "PY="
where python >nul 2>nul && set "PY=python"
if not defined PY (
    where py >nul 2>nul && set "PY=py"
)
if not defined PY (
    echo.
    echo [ERROR] Python not found. Install Python 3 and add it to PATH.
    echo.
    pause
    exit /b 1
)

rem Run the tool. No arguments = launch the local web GUI.
%PY% "%~dp0change_log.py" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [EXIT] code %RC%
    echo.
    pause
)
endlocal
