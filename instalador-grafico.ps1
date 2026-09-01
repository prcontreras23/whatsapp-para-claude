# Instalador gráfico para Windows — lo lanza "Instalar en Windows.bat".
#
# La persona no escribe ningún comando: responde dos avisos, escanea un código
# QR que se le abre en pantalla, y listo.

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms | Out-Null

$RepoDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Destino      = Join-Path $env:USERPROFILE "whatsapp-para-claude"
$InstancesDir = Join-Path $env:USERPROFILE ".whatsapp-para-claude"
$Instancia    = "principal"

function Bold($m) { Write-Host $m -ForegroundColor White }
function Ok($m)   { Write-Host "  OK  $m" -ForegroundColor Green }
function Info($m) { Write-Host "   .  $m" -ForegroundColor DarkGray }
function Paso($m) { Write-Host ""; Bold $m }

function Aviso($titulo, $mensaje) {
  [System.Windows.Forms.MessageBox]::Show($mensaje, $titulo, 'OK', 'Information') | Out-Null
}
function Alerta($titulo, $mensaje) {
  [System.Windows.Forms.MessageBox]::Show($mensaje, $titulo, 'OK', 'Warning') | Out-Null
}
function Preguntar($titulo, $mensaje) {
  $r = [System.Windows.Forms.MessageBox]::Show($mensaje, $titulo, 'OKCancel', 'Question')
  return ($r -eq 'OK')
}
function Morir($m) {
  Write-Host ""
  Write-Host "  X  $m" -ForegroundColor Red
  Alerta "No se pudo instalar" $m
  exit 1
}
function Tiene($cmd) { $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }

Clear-Host
Write-Host ""
Write-Host "   WhatsApp para Claude"
Write-Host "   ---------------------"
Write-Host ""
Write-Host "   Vas a conectar tu WhatsApp con Claude."
Write-Host "   No tienes que escribir nada: sigue los avisos que aparezcan."
Write-Host ""

# ---------------------------------------------------------------- consentimiento

$texto = @"
Esto conecta tu WhatsApp con Claude, en esta computadora.

Antes de seguir, es importante que sepas:

- Claude va a poder leer TODO tu WhatsApp, no solo lo del trabajo.
- Tus mensajes se quedan en esta computadora. No se suben a ningun servidor.
- Claude va a poder enviar mensajes en tu nombre.
- Puedes desconectarlo cuando quieras, desde tu telefono.

La instalacion toma unos 15 minutos, casi todos de espera.
Vas a necesitar tu telefono a mano.

Continuamos?
"@
if (-not (Preguntar "WhatsApp para Claude" $texto)) {
  Write-Host "Instalacion cancelada."
  exit 0
}

# ---------------------------------------------------------------- requisitos

Paso "1. Revisando que hace falta"

if (-not (Tiene winget)) {
  Alerta "Falta un programa base" @"
Necesito 'winget', que es lo que instala los demas programas.

Abre la Microsoft Store, busca 'Instalador de aplicaciones' e instalalo.
Despues vuelve a hacer doble clic en este instalador.
"@
  exit 1
}
Ok "winget"

$Faltan = @()
foreach ($par in @(@("go","GoLang.Go"), @("uv","astral-sh.uv"), @("ffmpeg","Gyan.FFmpeg"))) {
  if (Tiene $par[0]) { Ok $par[0] } else { Info "falta $($par[0])"; $Faltan += ,$par }
}

if ($Faltan.Count -gt 0) {
  Paso "2. Instalando lo que falta"
  Info "esto puede tardar varios minutos"
  foreach ($par in $Faltan) {
    Info "instalando $($par[0])..."
    winget install --id $par[1] -e --accept-source-agreements --accept-package-agreements --silent | Out-Null
  }
  Aviso "Falta un paso" @"
Ya instale los programas que faltaban.

Windows necesita que cierres esta ventana y vuelvas a hacer doble clic en el instalador para reconocerlos.

Cierra esta ventana y vuelve a empezar.
"@
  exit 0
} else {
  Paso "2. No falta nada por instalar"
}

# ---------------------------------------------------------------- copiar y compilar

Paso "3. Copiando archivos"
New-Item -ItemType Directory -Force -Path $Destino | Out-Null
if ($RepoDir -ne $Destino) {
  Copy-Item -Recurse -Force (Join-Path $RepoDir "whatsapp-bridge")     $Destino
  Copy-Item -Recurse -Force (Join-Path $RepoDir "whatsapp-mcp-server") $Destino
  Copy-Item -Force (Join-Path $RepoDir "wactl.ps1") $Destino
  $lic = Join-Path $RepoDir "LICENSE"
  if (Test-Path $lic) { Copy-Item -Force $lic $Destino }
}
Ok "copiados"

Paso "4. Preparando el programa"
Info "la primera vez toma unos minutos, es normal"
Push-Location (Join-Path $Destino "whatsapp-bridge")
try {
  & go mod download
  if ($LASTEXITCODE -ne 0) { Morir "No se pudieron bajar los componentes. Revisa que tengas internet." }
  $env:CGO_ENABLED = "0"
  & go build -o whatsapp-bridge.exe .
  if ($LASTEXITCODE -ne 0) { Morir "No se pudo preparar el programa." }
} finally { Pop-Location }
$BridgeBin = Join-Path $Destino "whatsapp-bridge\whatsapp-bridge.exe"
if (-not (Test-Path $BridgeBin)) { Morir "No se genero el programa." }
Ok "listo"

Paso "5. Preparando la conexion con Claude"
Push-Location (Join-Path $Destino "whatsapp-mcp-server")
try {
  & uv sync
  if ($LASTEXITCODE -ne 0) { Morir "Fallo la preparacion del servidor." }
} finally { Pop-Location }
Ok "listo"

# ---------------------------------------------------------------- instancia

Paso "6. Creando tu cuenta"
$Wactl = Join-Path $Destino "wactl.ps1"
New-Item -ItemType Directory -Force -Path $InstancesDir | Out-Null
$envFile = Join-Path $InstancesDir "$Instancia.env"
if (-not (Test-Path $envFile)) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $Wactl new $Instancia | Out-Null
}
$cfg = @{}
foreach ($line in Get-Content $envFile) {
  if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
  $k, $v = $line -split '=', 2
  $cfg[$k.Trim()] = $v.Trim()
}
Ok "cuenta '$Instancia' lista (puerto $($cfg.WHATSAPP_BRIDGE_PORT))"

# ---------------------------------------------------------------- vincular

$store   = $cfg.WHATSAPP_STORE_DIR
$qrPath  = Join-Path $store "qr.png"
$sesion  = Join-Path $store "whatsapp.db"
$yaVinculado = Test-Path $sesion

if ($yaVinculado) {
  Paso "7. Tu WhatsApp ya estaba vinculado"
  Ok "no hace falta escanear otra vez"
} else {
  Paso "7. Vinculando tu telefono"
  Remove-Item $qrPath -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $store | Out-Null
  $log = Join-Path $InstancesDir "$Instancia\bridge.log"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null

  $env:WHATSAPP_STORE_DIR   = $store
  $env:WHATSAPP_BRIDGE_PORT = $cfg.WHATSAPP_BRIDGE_PORT
  $env:WHATSAPP_QR_OPEN     = "1"
  $proc = Start-Process -FilePath $BridgeBin `
            -WorkingDirectory (Split-Path -Parent $BridgeBin) `
            -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
            -WindowStyle Hidden -PassThru
  $proc.Id | Set-Content (Join-Path $InstancesDir "$Instancia\bridge.pid")

  Info "generando el codigo QR..."
  for ($i = 0; $i -lt 40; $i++) {
    if (Test-Path $qrPath) { break }
    Start-Sleep -Seconds 1
  }
  if (-not (Test-Path $qrPath)) {
    Morir "No se pudo generar el codigo QR. Revisa que tengas internet e intentalo de nuevo."
  }
  Ok "codigo QR en pantalla"

  Aviso "Escanea el codigo" @"
Se abrio un codigo QR en tu pantalla.

En tu telefono:

1. Abre WhatsApp
2. Ve a Ajustes -> Dispositivos vinculados
3. Toca 'Vincular un dispositivo'
4. Escanea el codigo

Cuando termines, dale a Aceptar aqui.
"@

  Info "esperando la conexion y bajando tus mensajes..."
  $conectado = $false
  for ($i = 0; $i -lt 90; $i++) {
    try {
      Invoke-WebRequest -Uri "http://localhost:$($cfg.WHATSAPP_BRIDGE_PORT)/api/" -TimeoutSec 2 -UseBasicParsing | Out-Null
      $conectado = $true; break
    } catch {
      if ($_.Exception.Response) { $conectado = $true; break }
    }
    Start-Sleep -Seconds 2
  }
  if (-not $conectado) {
    Morir "No se completo la conexion. Vuelve a hacer doble clic en el instalador para intentarlo otra vez."
  }
  Ok "conectado"
  Remove-Item $qrPath -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- dejarlo listo

Paso "8. Dejando todo funcionando"
& powershell -NoProfile -ExecutionPolicy Bypass -File $Wactl autostart $Instancia | Out-Null
Ok "arrancara solo al encender la computadora"

$mcpOk = $false
if (Tiene claude) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $Wactl mcp $Instancia | Out-Null
  if ($LASTEXITCODE -eq 0) { Ok "conectado con Claude"; $mcpOk = $true }
} else {
  Info "no encontre Claude Code instalado"
}

Write-Host ""
Bold "=== Listo ==="
Write-Host ""

if ($mcpOk) {
  Aviso "Listo!" @"
Tu WhatsApp ya esta conectado con Claude.

Ultimo paso: cierra Claude Code y vuelve a abrirlo.

Despues pruebalo pidiendole algo como:
'muestrame mis ultimos chats de WhatsApp'
"@
} else {
  Alerta "Casi listo" @"
Tu WhatsApp quedo conectado y funcionando.

Pero no encontre Claude Code en esta computadora. Instalalo y despues vuelve a hacer doble clic en este instalador para terminar de conectarlo.
"@
}

Write-Host "Ya puedes cerrar esta ventana."
Write-Host ""
