# Instalador grafico para Windows - lo lanza "Instalar en Windows.bat".
#
# La persona no escribe ningun comando: responde dos avisos, escanea un codigo
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

# Corre un comando de wactl y devuelve su codigo y lo que dijo. Con "Stop", lo
# que wactl escriba en stderr tumbaria el instalador antes de mostrar el motivo.
function CorrerWactl {
  $antes = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $salida = & powershell -NoProfile -ExecutionPolicy Bypass -File $Wactl @args 2>&1 |
              ForEach-Object { "$_" } | Out-String
  $codigo = $LASTEXITCODE
  $ErrorActionPreference = $antes
  return @{ Codigo = $codigo; Salida = $salida.Trim() }
}

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
- Ocupa uno de los 4 "dispositivos vinculados" de tu WhatsApp. Es un
  dispositivo aparte de WhatsApp para Windows: si usas esa app, son dos.

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

# Se lee y se evalua, en vez de dot-sourcing: la politica de ejecucion de
# Windows bloquea por defecto los .ps1 bajados de internet.
Invoke-Expression ([System.IO.File]::ReadAllText((Join-Path $RepoDir "lib-requisitos.ps1"), [System.Text.Encoding]::UTF8))
Ruta-Extendida

foreach ($p in @('go','uv','ffmpeg')) {
  if (Tiene $p) { Ok $p } else { Info "falta $p" }
}

Paso "2. Instalando lo que falta"

if (-not (Tiene go) -or -not (Tiene uv)) {
  Info "esto puede tardar varios minutos, no cierres la ventana"
}

if (-not (Tiene go)) {
  Info "instalando Go..."
  if (Instalar-Go) { Ok "Go" } else {
    Morir @"
No pude instalar Go automaticamente.
Motivo: $script:ErrorGo

Descargalo de https://go.dev/dl/ (la version para Windows), instalalo,
y vuelve a hacer doble clic aqui.
"@
  }
}

if (-not (Tiene uv)) {
  Info "instalando uv..."
  if (Instalar-Uv) { Ok "uv" } else {
    Morir @"
No pude instalar uv automaticamente.

Abre PowerShell, pega esta linea, y vuelve a hacer doble clic aqui:

irm https://astral.sh/uv/install.ps1 | iex
"@
  }
}

if (-not (Tiene ffmpeg)) {
  Info "instalando ffmpeg..."
  if (Instalar-Ffmpeg) { Ok "ffmpeg" } else {
    Alerta "Sin ffmpeg" "No pude instalar ffmpeg. Todo va a funcionar menos enviar notas de voz."
  }
}

Persistir-Ruta

# ---------------------------------------------------------------- copiar y compilar

# Un puente que ya este corriendo (de una instalacion anterior) bloquea
# whatsapp-bridge.exe y la compilacion falla. Se apagan antes, con sus
# supervisores, y al final se vuelven a encender.
$cuentasAntes = @()
$supervisores = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine.Contains($InstancesDir) -and $_.CommandLine -match 'arrancar\.ps1' })
$puentes = @(Get-CimInstance Win32_Process -Filter "Name='whatsapp-bridge.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Destino, [StringComparison]::OrdinalIgnoreCase) })
if ($supervisores.Count -or $puentes.Count) {
  Paso "Apagando la version anterior"
  foreach ($p in $puentes) {
    if ($p.CommandLine -match '--instancia=([a-z0-9-]+)') { $cuentasAntes += $Matches[1] }
  }
  foreach ($p in $supervisores) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
  foreach ($p in $puentes) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
  foreach ($p in $puentes) { Wait-Process -Id $p.ProcessId -Timeout 10 -ErrorAction SilentlyContinue }
  Ok "apagada ($($puentes.Count) puente(s))"
}

Paso "3. Copiando archivos"
New-Item -ItemType Directory -Force -Path $Destino | Out-Null
if ($RepoDir -ne $Destino) {
  Copy-Item -Recurse -Force (Join-Path $RepoDir "whatsapp-bridge")     $Destino
  Copy-Item -Recurse -Force (Join-Path $RepoDir "whatsapp-mcp-server") $Destino
  Copy-Item -Force (Join-Path $RepoDir "wactl.ps1") $Destino
  Copy-Item -Force (Join-Path $RepoDir "lib-requisitos.ps1") $Destino
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
$puerto  = $cfg.WHATSAPP_BRIDGE_PORT
$qrPath  = Join-Path $store "qr.png"
$log     = Join-Path $InstancesDir "$Instancia\bridge.log"

# Que exista whatsapp.db no basta: un intento anterior que no llego a escanearse
# deja uno vacio. Se le pregunta al puente si hay un numero vinculado de verdad.
$numero = NumeroDe $store $BridgeBin
$yaVinculado = ($numero -ne "sin vincular")

# Espera a que el puente diga que esta conectado a WhatsApp (no basta con que
# el puerto conteste). Se pide dos veces seguidas, porque justo despues de
# escanear WhatsApp corta la conexion una vez y el puente se reconecta.
function EsperarConexion($segundos, $proceso) {
  $seguidas = 0
  for ($i = 0; $i -lt $segundos; $i += 2) {
    if ($proceso -and $proceso.HasExited) { return $false }
    $st = EstadoPuente $puerto
    if ($st -and $st.connected -and $st.logged_in) { $seguidas++ } else { $seguidas = 0 }
    if ($seguidas -ge 2) { return $true }
    Start-Sleep -Seconds 2
  }
  return $false
}

function UltimasLineas($ruta) {
  if (-not (Test-Path $ruta)) { return "" }
  try {
    $fs = [System.IO.File]::Open($ruta, 'Open', 'Read', 'ReadWrite')
    try {
      $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
      $lineas = $sr.ReadToEnd() -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '[▀-▟]' }
    } finally { $fs.Close() }
    return (@($lineas) | Select-Object -Last 4) -join "`n"
  } catch { return "" }
}

if ($yaVinculado) {
  Paso "7. Tu WhatsApp ya estaba vinculado ($numero)"
  Ok "no hace falta escanear otra vez"
} else {
  Paso "7. Vinculando tu telefono"

  # Dos formas: escribir en el telefono un codigo de 8 letras (con el numero)
  # o escanear un QR. La del numero no depende de la camara ni de abrir una
  # imagen en la PC.
  $forma = [System.Windows.Forms.MessageBox]::Show(@"
Como quieres vincular tu WhatsApp?

SI  = con tu numero de telefono. Te doy un codigo de 8 letras
      y lo escribes en el telefono.

NO  = escaneando un codigo QR con la camara del telefono.
"@, "Vincular WhatsApp", 'YesNoCancel', 'Question')
  if ($forma -eq 'Cancel') { Write-Host "Instalacion cancelada."; exit 0 }
  $porNumero = ($forma -eq 'Yes')

  $telefono = ""
  if ($porNumero) {
    Add-Type -AssemblyName Microsoft.VisualBasic | Out-Null
    for ($intento = 0; $intento -lt 3 -and -not $telefono; $intento++) {
      $escrito = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Escribe tu numero de WhatsApp.`n`nEjemplo: 809 555 1234`n`nSi no es de Republica Dominicana, ponlo con el codigo de pais.",
        "Tu numero de WhatsApp", "")
      if (-not $escrito) { Write-Host "Instalacion cancelada."; exit 0 }
      $digitos = ($escrito -replace '\D', '')
      # Numeros dominicanos de 10 digitos: se les agrega el 1 del pais.
      if ($digitos.Length -eq 10 -and $digitos -match '^(809|829|849)') { $digitos = "1$digitos" }
      if ($digitos.Length -ge 11 -and $digitos.Length -le 15) { $telefono = $digitos }
      else { Alerta "Numero no valido" "No reconozco '$escrito' como numero de telefono. Intentalo otra vez." }
    }
    if (-not $telefono) { Morir "No se pudo leer el numero de telefono." }
  }

  # Un intento anterior pudo dejar un puente de esta cuenta corriendo. Dos a la
  # vez se pelean el puerto y la sesion, y WhatsApp desconecta a uno.
  CorrerWactl stop $Instancia | Out-Null

  $codigoPath = Join-Path $store "codigo.txt"
  $codigoErr  = Join-Path $store "codigo-error.txt"
  Remove-Item $qrPath, $codigoPath, $codigoErr -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $store | Out-Null
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null

  $env:WHATSAPP_STORE_DIR   = $store
  $env:WHATSAPP_BRIDGE_PORT = $puerto
  if ($porNumero) { $env:WHATSAPP_PAIR_PHONE = $telefono } else { $env:WHATSAPP_QR_OPEN = "1" }
  # La marca --instancia permite que wactl y el arranque automatico reconozcan
  # este proceso como el puente de la cuenta y no abran otro.
  $proc = Start-Process -FilePath $BridgeBin -ArgumentList "--instancia=$Instancia" `
            -WorkingDirectory (Split-Path -Parent $BridgeBin) `
            -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
            -WindowStyle Hidden -PassThru
  $null = $proc.Handle
  $proc.Id | Set-Content (Join-Path $InstancesDir "$Instancia\bridge.pid")
  Remove-Item Env:\WHATSAPP_QR_OPEN, Env:\WHATSAPP_PAIR_PHONE -ErrorAction SilentlyContinue

  if ($porNumero) {
    Info "pidiendo el codigo a WhatsApp..."
    for ($i = 0; $i -lt 40; $i++) {
      if ((Test-Path $codigoPath) -or (Test-Path $codigoErr) -or $proc.HasExited) { break }
      Start-Sleep -Seconds 1
    }
    if (-not (Test-Path $codigoPath)) {
      $detalle = if (Test-Path $codigoErr) { Get-Content $codigoErr -Raw } else { UltimasLineas $log }
      CorrerWactl stop $Instancia | Out-Null
      Morir @"
WhatsApp no dio el codigo para el numero +$telefono.

Revisa que el numero este bien y que tengas internet. Tambien puedes correr
el instalador otra vez y elegir el codigo QR.

Detalle:
$detalle
"@
    }
    $codigo = (Get-Content $codigoPath -Raw).Trim()
    Write-Host ""
    Write-Host "      CODIGO:  $codigo" -ForegroundColor Yellow
    Write-Host ""
    Aviso "Escribe este codigo en tu telefono" @"
Tu codigo es:

          $codigo

En tu telefono (+$telefono):

1. Abre WhatsApp
2. Ve a Ajustes -> Dispositivos vinculados
3. Toca 'Vincular un dispositivo'
4. Abajo, toca 'Vincular con el numero de telefono'
5. Escribe el codigo

Puede que te llegue una notificacion de WhatsApp: si la tocas, te lleva
directo a donde se escribe el codigo.

El codigo vence en unos 2 minutos. Cuando termines, dale a Aceptar aqui.
"@
  } else {
    Info "generando el codigo QR..."
    for ($i = 0; $i -lt 40; $i++) {
      if ((Test-Path $qrPath) -or $proc.HasExited) { break }
      Start-Sleep -Seconds 1
    }
    if (-not (Test-Path $qrPath)) {
      $detalle = UltimasLineas $log
      CorrerWactl stop $Instancia | Out-Null
      Morir @"
No se pudo generar el codigo QR. Revisa que tengas internet e intentalo de nuevo.

Detalle:
$detalle
"@
    }
    Ok "codigo QR en pantalla"

    Aviso "Escanea el codigo" @"
Se abrio un codigo QR en tu pantalla.

Si Windows te pregunta con que app abrirlo, elige *Fotos*.
Si no se abrio, el archivo esta en:
$qrPath

En tu telefono:

1. Abre WhatsApp
2. Ve a Ajustes -> Dispositivos vinculados
3. Toca 'Vincular un dispositivo'
4. Escanea el codigo

Cuando termines, dale a Aceptar aqui.
"@
  }

  Info "esperando la conexion..."
  $conectado = EsperarConexion 150 $proc
  if (-not $conectado -and -not $proc.HasExited) {
    # El codigo sigue vivo un rato: se ofrece reintentar sin pedir uno nuevo.
    # Pedir varios seguidos hace que WhatsApp bloquee el vinculo un rato
    # ("intentalo mas tarde").
    $cual = if ($porNumero) { "Escribe en el telefono el codigo $codigo" }
            else { "El codigo QR sigue abierto en:`n$qrPath`nAbrelo y escanealo" }
    $r = [System.Windows.Forms.MessageBox]::Show(@"
Todavia no se ha conectado.

Si no te dio tiempo, todavia puedes hacerlo:
$cual

y dale a Reintentar.

(No cierres esta ventana: pedir codigos nuevos seguidos hace que WhatsApp
bloquee el vinculo por unos 20 minutos.)
"@, "Reintentar?", 'RetryCancel', 'Warning')
    if ($r -eq 'Retry') {
      Info "esperando otra vez..."
      $conectado = EsperarConexion 150 $proc
    }
  }
  if (-not $conectado) {
    CorrerWactl stop $Instancia | Out-Null
    Morir @"
No se completo la conexion. El codigo ya vencio.

Si WhatsApp te dijo 'intentalo mas tarde', espera unos 20 minutos antes de
volver a intentarlo: bloquea el vinculo cuando se piden varios codigos seguidos.

Despues corre de nuevo el instalador.
"@
  }
  $st = EstadoPuente $puerto
  Ok "conectado ($($st.phone))"
  Remove-Item $qrPath, $codigoPath, $codigoErr -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- dejarlo listo

Paso "8. Dejando todo funcionando"
$problemas = @()

$r = CorrerWactl autostart $Instancia
if ($r.Codigo -eq 0) { Ok "arrancara solo al encender la computadora" }
else {
  Write-Host "  X  no pude dejarlo arrancando solo al encender" -ForegroundColor Red
  $problemas += "No arranca solo al encender: $($r.Salida)"
}

# wactl start deja un solo puente con su supervisor: si ya esta el del paso 7,
# lo adopta en vez de abrir otro. Y no dice que esta listo hasta que el puente
# confirma que esta conectado a WhatsApp.
$r = CorrerWactl start $Instancia
if ($r.Codigo -eq 0) { Ok "WhatsApp conectado y funcionando" }
else {
  Write-Host "  X  el puente no quedo conectado" -ForegroundColor Red
  $problemas += "El puente no quedo conectado: $($r.Salida)"
}

# Las otras cuentas que estaban encendidas antes de actualizar.
foreach ($otra in ($cuentasAntes | Where-Object { $_ -ne $Instancia } | Sort-Object -Unique)) {
  $r = CorrerWactl start $otra
  if ($r.Codigo -eq 0) { Ok "cuenta '$otra' encendida otra vez" }
  else { $problemas += "La cuenta '$otra' no volvio a encender: $($r.Salida)" }
}

$mcpOk = $false
$mcpError = ""
if (Tiene claude) {
  $r = CorrerWactl mcp $Instancia
  if ($r.Codigo -eq 0) { Ok "conectado con Claude"; $mcpOk = $true }
  else { $mcpError = $r.Salida }
} else {
  Info "no encontre Claude Code instalado"
}

Write-Host ""
Bold "=== Listo ==="
Write-Host ""
if ($mcpOk) {
  Write-Host "  Abre una conversacion NUEVA en Claude Code: las que ya estaban abiertas"
  Write-Host "  no ven el WhatsApp, porque se abrieron antes de conectarlo."
  Write-Host ""
}
Write-Host "  Para revisar como esta, en PowerShell:"
Write-Host "     powershell -ExecutionPolicy Bypass -File `"$Wactl`" status $Instancia"
Write-Host ""

$extra = ""
if ($problemas.Count) {
  $extra = "`n`nOjo, hubo algo que no quedo bien:`n- " + ($problemas -join "`n- ") +
           "`n`nMandale una foto de esta ventana a quien te paso el instalador."
}

if ($mcpOk) {
  $titulo = if ($problemas.Count) { "Casi listo" } else { "Listo!" }
  Aviso $titulo @"
Tu WhatsApp ya esta conectado con Claude.

Ultimo paso: cierra Claude Code y vuelve a abrirlo.

Importante: empieza una conversacion NUEVA. Las que ya tenias abiertas no ven
el WhatsApp, porque se abrieron antes de conectarlo.

En tu telefono, en Dispositivos vinculados, esto aparece como un dispositivo
aparte de WhatsApp para Windows.

Despues pruebalo pidiendole algo como:
'muestrame mis ultimos chats de WhatsApp'$extra
"@
} elseif ($mcpError) {
  Morir @"
Tu WhatsApp quedo vinculado, pero no pude conectarlo con Claude.

Detalle: $mcpError$extra

Mandale una foto de esta ventana a quien te paso el instalador.
"@
} else {
  Alerta "Casi listo" @"
Tu WhatsApp quedo vinculado.

Pero no encontre Claude Code en esta computadora. Instalalo y despues vuelve a hacer doble clic en este instalador para terminar de conectarlo.$extra
"@
}

Write-Host "Ya puedes cerrar esta ventana."
Write-Host ""
