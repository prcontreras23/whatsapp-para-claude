# Instalador de WhatsApp para Claude — Windows
#
# Deja tu WhatsApp conectado a Claude Code. Se puede correr varias veces sin
# problema: lo que ya está hecho se salta.
#
#   .\install.ps1              instala y usa el nombre 'principal'
#   .\install.ps1 trabajo      instala una cuenta con el nombre 'trabajo'

param([string]$Instancia = "principal")

$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Destino      = Join-Path $env:USERPROFILE "whatsapp-para-claude"
$InstancesDir = Join-Path $env:USERPROFILE ".whatsapp-para-claude"

function Bold($m) { Write-Host $m -ForegroundColor White }
function Ok($m)   { Write-Host "  OK " -ForegroundColor Green -NoNewline; Write-Host $m }
function Info($m) { Write-Host "   . $m" -ForegroundColor DarkGray }
function Warn($m) { Write-Host "   ! $m" -ForegroundColor Yellow }
function Paso($m) { Write-Host ""; Bold $m }
function Morir($m) { Write-Host ""; Write-Host "  X $m" -ForegroundColor Red; Write-Host ""; exit 1 }

function Tiene($cmd) { $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }

Write-Host ""
Bold "=== WhatsApp para Claude ==="
Write-Host ""
Info "Esto conecta tu WhatsApp con Claude Code."
Info "Todo queda en esta computadora: tus mensajes no se suben a ningun lado."
Write-Host ""

# ---------------------------------------------------------------- requisitos

Paso "1. Revisando lo que hace falta"

if (-not (Tiene winget)) {
  Warn "No tienes winget, que es lo que instala los programas."
  Write-Host ""
  Write-Host "     Instala 'Instalador de aplicaciones' desde la Microsoft Store"
  Write-Host "     y vuelve a correr este instalador."
  Write-Host ""
  Morir "winget es necesario para seguir."
}
Ok "winget"

$Faltan = @()
foreach ($par in @(@("go","GoLang.Go"), @("uv","astral-sh.uv"), @("ffmpeg","Gyan.FFmpeg"))) {
  if (Tiene $par[0]) { Ok $par[0] } else { Info "falta $($par[0])"; $Faltan += ,$par }
}

if ($Faltan.Count -gt 0) {
  Paso "2. Instalando lo que falta"
  foreach ($par in $Faltan) {
    Info "instalando $($par[0])..."
    winget install --id $par[1] -e --accept-source-agreements --accept-package-agreements --silent | Out-Null
  }
  Ok "listo"
  Warn "Cierra esta ventana y abre una PowerShell NUEVA, luego vuelve a correr el instalador."
  Warn "(Windows necesita reabrir la terminal para ver los programas recien instalados.)"
  Write-Host ""
  exit 0
} else {
  Paso "2. No falta nada por instalar"
}

if (-not (Tiene claude)) { Warn "No encuentro el comando 'claude'. Al final tendras que registrar el MCP a mano." }

# ---------------------------------------------------------------- copiar

Paso "3. Copiando los archivos a $Destino"

New-Item -ItemType Directory -Force -Path $Destino | Out-Null
if ($RepoDir -ne $Destino) {
  Copy-Item -Recurse -Force (Join-Path $RepoDir "whatsapp-bridge")     $Destino
  Copy-Item -Recurse -Force (Join-Path $RepoDir "whatsapp-mcp-server") $Destino
  Copy-Item -Force (Join-Path $RepoDir "wactl.ps1") $Destino
  $lic = Join-Path $RepoDir "LICENSE"
  if (Test-Path $lic) { Copy-Item -Force $lic $Destino }
}
Ok "copiados"

# ---------------------------------------------------------------- compilar

Paso "4. Compilando el puente de WhatsApp"
Info "esto tarda un par de minutos la primera vez"

Push-Location (Join-Path $Destino "whatsapp-bridge")
try {
  & go mod download
  if ($LASTEXITCODE -ne 0) { Morir "No se pudieron bajar las librerias. Hay internet?" }
  $env:CGO_ENABLED = "0"
  & go build -o whatsapp-bridge.exe .
  if ($LASTEXITCODE -ne 0) { Morir "Fallo la compilacion." }
  Ok "compilado"
} finally { Pop-Location }

if (-not (Test-Path (Join-Path $Destino "whatsapp-bridge\whatsapp-bridge.exe"))) {
  Morir "no se genero el programa"
}

# ---------------------------------------------------------------- python

Paso "5. Preparando el servidor que habla con Claude"

Push-Location (Join-Path $Destino "whatsapp-mcp-server")
try {
  & uv sync
  if ($LASTEXITCODE -ne 0) { Morir "Fallo 'uv sync'." }
  Ok "listo"
} finally { Pop-Location }

# ---------------------------------------------------------------- instancia

Paso "6. Creando tu cuenta '$Instancia'"

New-Item -ItemType Directory -Force -Path $InstancesDir | Out-Null
$Wactl = Join-Path $Destino "wactl.ps1"
$envFile = Join-Path $InstancesDir "$Instancia.env"

if (Test-Path $envFile) {
  Info "'$Instancia' ya existia, la reutilizo"
} else {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $Wactl new $Instancia
}

# ---------------------------------------------------------------- final

$store = Join-Path $InstancesDir "$Instancia\store"
$yaVinculado = Test-Path (Join-Path $store "whatsapp.db")

Write-Host ""
Bold "=== Instalacion lista ==="
Write-Host ""

if ($yaVinculado) {
  Info "Tu WhatsApp ya estaba vinculado."
  Write-Host ""
  Write-Host "  Para dejarlo corriendo:"
  Write-Host "     $Wactl start $Instancia"
} else {
  Bold "Falta un paso: vincular tu telefono."
  Write-Host ""
  Write-Host "  Corre esto:"
  Write-Host ""
  Write-Host "     $Wactl qr $Instancia"
  Write-Host ""
  Write-Host "  Va a salir un codigo QR. En tu telefono abre WhatsApp y ve a:"
  Write-Host "     Ajustes -> Dispositivos vinculados -> Vincular un dispositivo"
  Write-Host ""
  Write-Host "  Escanea el codigo y espera a que termine de bajar tus mensajes"
  Write-Host "  (unos minutos). Cuando el texto deje de moverse, presiona Ctrl+C."
  Write-Host ""
  Write-Host "  Despues, para dejarlo funcionando:"
  Write-Host ""
  Write-Host "     $Wactl start $Instancia"
  Write-Host "     $Wactl autostart $Instancia"
  Write-Host "     $Wactl mcp $Instancia"
  Write-Host ""
  Write-Host "  Y reinicia Claude Code."
  Write-Host ""
  Warn "Si el codigo QR se ve como cuadros raros, usa Windows Terminal en vez"
  Warn "de la ventana negra clasica: se ve bien ahi."
}
Write-Host ""
