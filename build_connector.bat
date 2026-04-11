@echo off
REM ============================================================
REM  GT7 Live Connector — Windows EXE build script
REM  Run this once to produce GT7-Live-Connector.exe
REM
REM  Requirements:
REM    pip install pyinstaller pystray pillow pycryptodome websockets cryptography
REM ============================================================

echo Installing build dependencies...
pip install pyinstaller pystray pillow pycryptodome websockets cryptography

echo.
echo Building GT7-Live-Connector.exe...
pyinstaller ^
  --onefile ^
  --noconsole ^
  --name "GT7-Live-Connector" ^
  --icon NONE ^
  gt7_connector.py

echo.
if exist "dist\GT7-Live-Connector.exe" (
  echo Build complete: dist\GT7-Live-Connector.exe
) else (
  echo Build failed. Check output above for errors.
)
pause
