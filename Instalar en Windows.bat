@echo off
REM Instalador de doble clic para Windows.
REM La persona no escribe ni un comando: doble clic y seguir los avisos.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0instalador-grafico.ps1"
if errorlevel 1 (
  echo.
  echo Hubo un problema. Puedes cerrar esta ventana.
  pause
)
