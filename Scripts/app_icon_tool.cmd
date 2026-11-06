@echo off
setlocal
set "PYTHONUTF8=1"
where python >nul 2>nul
if errorlevel 1 (
  echo Python 3 with Pillow is required.
  pause
  exit /b 1
)
python -X utf8 -c "import PIL" >nul 2>nul
if errorlevel 1 (
  echo Install Pillow first: python -X utf8 -m pip install Pillow
  pause
  exit /b 1
)
python -X utf8 "%~dp0app_icon_tool.py" %*
if errorlevel 1 pause
endlocal
