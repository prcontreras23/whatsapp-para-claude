# Arranque de una linea para Windows:
#
#   irm https://raw.githubusercontent.com/prcontreras23/whatsapp-para-claude/main/instalar-windows.ps1 | iex
#
# Baja el proyecto y arranca el instalador, para no tener que descargar el ZIP
# a mano ni descomprimirlo.

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Repo   = "prcontreras23/whatsapp-para-claude"
$Fuente = Join-Path $env:USERPROFILE "whatsapp-para-claude-fuente"

function Bold($m) { Write-Host $m -ForegroundColor White }
function Gris($m) { Write-Host $m -ForegroundColor DarkGray }
function Morir($m) {
  Write-Host ""
  Write-Host "  X $m" -ForegroundColor Red
  Write-Host ""
  exit 1
}

Write-Host ""
Bold "Bajando WhatsApp para Claude..."
Write-Host ""

$zip = Join-Path $env:TEMP "whatsapp-para-claude.zip"
try {
  Invoke-WebRequest -Uri "https://github.com/$Repo/archive/refs/heads/main.zip" `
    -OutFile $zip -UseBasicParsing
} catch {
  Morir "No se pudo bajar. Revisa que tengas internet e intentalo otra vez."
}

if (Test-Path $Fuente) { Remove-Item -Recurse -Force $Fuente -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $Fuente | Out-Null

try {
  $temp = Join-Path $env:TEMP "wpc-extraido"
  if (Test-Path $temp) { Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue }
  Expand-Archive -Path $zip -DestinationPath $temp -Force
  # El ZIP de GitHub trae todo dentro de una carpeta "<repo>-main".
  $interna = Get-ChildItem $temp -Directory | Select-Object -First 1
  Copy-Item -Path (Join-Path $interna.FullName "*") -Destination $Fuente -Recurse -Force
  Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue
  Remove-Item $zip -ErrorAction SilentlyContinue
} catch {
  Morir "No se pudo descomprimir el archivo bajado."
}

Write-Host "  OK " -ForegroundColor Green -NoNewline
Write-Host "listo"
Gris  "  archivos en $Fuente"

$instalador = Join-Path $Fuente "instalador-grafico.ps1"
if (-not (Test-Path $instalador)) { Morir "El proyecto se bajo incompleto. Intentalo de nuevo." }

# -ExecutionPolicy Bypass: Windows bloquea por defecto los scripts bajados de
# internet ("running scripts is disabled on this system"). El Bypass vale solo
# para esta ejecucion; no cambia la configuracion de la maquina.
& powershell -NoProfile -ExecutionPolicy Bypass -File $instalador
