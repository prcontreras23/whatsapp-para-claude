# wactl - gestor de cuentas de WhatsApp para Claude (Windows)
#
# Cada cuenta es un WhatsApp distinto: su numero, su sesion, su historial y su
# puerto. Todas comparten un solo programa.
#
#   wactl.ps1 list                     cuentas y su estado
#   wactl.ps1 new <nombre>             crear una cuenta
#   wactl.ps1 qr <nombre>              vincular el telefono (muestra el QR)
#   wactl.ps1 start|stop|restart <n>   controlar el puente
#   wactl.ps1 status <nombre>          detalle de una cuenta
#   wactl.ps1 logs <nombre> [lineas]   ver el registro
#   wactl.ps1 mcp <nombre>             conectarla a Claude Code
#   wactl.ps1 autostart <nombre>       que arranque sola al encender
#   wactl.ps1 remove <nombre>          eliminarla

param(
  [Parameter(Position=0)][string]$Comando = "list",
  [Parameter(Position=1)][string]$Nombre  = "",
  [Parameter(Position=2)][string]$Extra   = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$WactlHome    = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstancesDir = if ($env:WHATSAPP_INSTANCES_DIR) { $env:WHATSAPP_INSTANCES_DIR }
                else { Join-Path $env:USERPROFILE ".whatsapp-para-claude" }
$BridgeBin    = Join-Path $WactlHome "whatsapp-bridge\whatsapp-bridge.exe"
$McpServerDir = Join-Path $WactlHome "whatsapp-mcp-server"
$TaskPrefix   = "WhatsAppParaClaude"

function Ok($m)   { Write-Host $m -ForegroundColor Green }
function Info($m) { Write-Host $m -ForegroundColor DarkGray }
function Morir($m) { Write-Host "Error: $m" -ForegroundColor Red; exit 1 }

function EnvFile($n) { Join-Path $InstancesDir "$n.env" }

function Cargar($n) {
  $f = EnvFile $n
  if (-not (Test-Path $f)) { Morir "la cuenta '$n' no existe. Mirala con: wactl.ps1 list" }
  $cfg = @{}
  foreach ($line in Get-Content $f) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $k, $v = $line -split '=', 2
    $cfg[$k.Trim()] = $v.Trim()
  }
  return $cfg
}

function PidFile($n) { Join-Path $InstancesDir "$n\bridge.pid" }

function PidReal($n) {
  $pf = PidFile $n
  if (-not (Test-Path $pf)) { return $null }
  $procId = (Get-Content $pf -ErrorAction SilentlyContinue | Select-Object -First 1)
  if (-not $procId) { return $null }
  $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if ($p -and $p.ProcessName -like "whatsapp-bridge*") { return $procId }
  return $null
}

function ApiVivo($puerto) {
  try {
    Invoke-WebRequest -Uri "http://localhost:$puerto/api/" -TimeoutSec 2 -UseBasicParsing | Out-Null
    return $true
  } catch {
    # Un 404 tambien significa que el servidor esta arriba
    if ($_.Exception.Response) { return $true }
    return $false
  }
}

function PuertoOcupado($puerto) {
  $c = Get-NetTCPConnection -LocalPort $puerto -State Listen -ErrorAction SilentlyContinue
  return $null -ne $c
}

function PuertoLibre {
  $p = 8080
  while ($p -le 8130) {
    $enUso = PuertoOcupado $p
    $declarado = $false
    if (Test-Path $InstancesDir) {
      foreach ($f in Get-ChildItem "$InstancesDir\*.env" -ErrorAction SilentlyContinue) {
        if ((Get-Content $f.FullName) -match "^WHATSAPP_BRIDGE_PORT=$p$") { $declarado = $true }
      }
    }
    if (-not $enUso -and -not $declarado) { return $p }
    $p++
  }
  Morir "no encontre puerto libre entre 8080 y 8130"
}

function NumeroDe($store) {
  $db = Join-Path $store "whatsapp.db"
  if (-not (Test-Path $db)) { return "sin vincular" }
  # Sin sqlite3.exe en Windows, se lee el JID del archivo directamente.
  try {
    # El JID vive al principio del archivo: se leen solo los primeros 256 KB
    # en vez de cargar una base de decenas de MB en memoria.
    $fs = [System.IO.File]::OpenRead($db)
    try {
      $buf = New-Object byte[] ([Math]::Min(262144, $fs.Length))
      [void]$fs.Read($buf, 0, $buf.Length)
    } finally { $fs.Close() }
    $texto = [System.Text.Encoding]::ASCII.GetString($buf)
    if ($texto -match '(\d{10,15}):\d+@s\.whatsapp\.net') { return "+" + $Matches[1] }
  } catch {}
  return "vinculada"
}

# ------------------------------------------------------------------ comandos

function Cmd-List {
  New-Item -ItemType Directory -Force -Path $InstancesDir | Out-Null
  $archivos = Get-ChildItem "$InstancesDir\*.env" -ErrorAction SilentlyContinue
  if (-not $archivos) { Info "(ninguna todavia - creala con: wactl.ps1 new <nombre>)"; return }

  "{0,-14} {1,-7} {2,-10} {3}" -f "CUENTA","PUERTO","ESTADO","NUMERO" | Write-Host
  "{0,-14} {1,-7} {2,-10} {3}" -f "------","------","------","------" | Write-Host
  foreach ($f in $archivos) {
    $n = $f.BaseName
    $cfg = Cargar $n
    $estado = "parado"
    if (PidReal $n) {
      if (ApiVivo $cfg.WHATSAPP_BRIDGE_PORT) { $estado = "activo" } else { $estado = "arrancando" }
    }
    $num = NumeroDe $cfg.WHATSAPP_STORE_DIR
    "{0,-14} {1,-7} {2,-10} {3}" -f $n, $cfg.WHATSAPP_BRIDGE_PORT, $estado, $num | Write-Host
  }
}

function Cmd-New($n) {
  if (-not $n) { Morir "falta el nombre. Ej: wactl.ps1 new personal" }
  if ($n -notmatch '^[a-z0-9][a-z0-9-]*$') { Morir "nombre invalido. Solo minusculas, numeros y guiones." }
  if (Test-Path (EnvFile $n)) { Morir "la cuenta '$n' ya existe" }

  New-Item -ItemType Directory -Force -Path $InstancesDir | Out-Null
  $puerto = PuertoLibre
  $store  = Join-Path $InstancesDir "$n\store"
  New-Item -ItemType Directory -Force -Path $store | Out-Null

  @"
# Cuenta '$n' - creada $(Get-Date -Format 'yyyy-MM-dd HH:mm')
WHATSAPP_INSTANCIA=$n
WHATSAPP_STORE_DIR=$store
WHATSAPP_BRIDGE_PORT=$puerto
WHATSAPP_API_BASE_URL=http://localhost:$puerto/api
WHATSAPP_MESSAGES_DB=$store\messages.db
WHATSAPP_MCP_NAME=whatsapp-$n
"@ | Set-Content -Encoding UTF8 (EnvFile $n)

  Ok "Cuenta '$n' creada."
  Write-Host "  puerto : $puerto"
  Write-Host "  datos  : $store"
  Write-Host ""
  Write-Host "Siguiente paso - vincular el telefono:"
  Write-Host "  wactl.ps1 qr $n"
}

function Cmd-Qr($n) {
  if (-not $n) { Morir "falta el nombre" }
  $cfg = Cargar $n
  if (PidReal $n) { Morir "'$n' ya esta corriendo. Parala primero: wactl.ps1 stop $n" }

  Write-Host "Arrancando '$n'."
  Write-Host "Escanea el QR desde: WhatsApp -> Ajustes -> Dispositivos vinculados -> Vincular un dispositivo"
  Write-Host "Cuando termine de sincronizar, Ctrl+C y luego: wactl.ps1 start $n"
  Write-Host ""

  New-Item -ItemType Directory -Force -Path $cfg.WHATSAPP_STORE_DIR | Out-Null
  $env:WHATSAPP_STORE_DIR   = $cfg.WHATSAPP_STORE_DIR
  $env:WHATSAPP_BRIDGE_PORT = $cfg.WHATSAPP_BRIDGE_PORT
  Push-Location (Split-Path -Parent $BridgeBin)
  try { & $BridgeBin } finally { Pop-Location }
}

function Cmd-Start($n) {
  if (-not $n) { Morir "falta el nombre" }
  $cfg = Cargar $n
  if (PidReal $n) { Info "'$n' ya estaba corriendo"; return }
  if (PuertoOcupado $cfg.WHATSAPP_BRIDGE_PORT) { Morir "el puerto $($cfg.WHATSAPP_BRIDGE_PORT) esta ocupado por otro programa" }
  if (-not (Test-Path (Join-Path $cfg.WHATSAPP_STORE_DIR "whatsapp.db"))) {
    Morir "'$n' no esta vinculada todavia. Corre primero: wactl.ps1 qr $n"
  }

  $log = Join-Path $InstancesDir "$n\bridge.log"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null

  $env:WHATSAPP_STORE_DIR   = $cfg.WHATSAPP_STORE_DIR
  $env:WHATSAPP_BRIDGE_PORT = $cfg.WHATSAPP_BRIDGE_PORT
  $p = Start-Process -FilePath $BridgeBin `
        -WorkingDirectory (Split-Path -Parent $BridgeBin) `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
        -WindowStyle Hidden -PassThru
  $p.Id | Set-Content (PidFile $n)
  Start-Sleep -Seconds 3
  if (PidReal $n) { Ok "'$n' arrancada en el puerto $($cfg.WHATSAPP_BRIDGE_PORT)" }
  else { Write-Host "'$n' no arranco. Mira el registro: wactl.ps1 logs $n" -ForegroundColor Red }
}

function Cmd-Stop($n) {
  if (-not $n) { Morir "falta el nombre" }
  Cargar $n | Out-Null
  $procId = PidReal $n
  if (-not $procId) { Info "'$n' no estaba corriendo"; return }
  Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
  Remove-Item (PidFile $n) -ErrorAction SilentlyContinue
  Ok "'$n' detenida"
}

function Cmd-Status($n) {
  if (-not $n) { Cmd-List; return }
  $cfg = Cargar $n
  Write-Host "Cuenta   : $n"
  Write-Host "Puerto   : $($cfg.WHATSAPP_BRIDGE_PORT)"
  Write-Host "Datos    : $($cfg.WHATSAPP_STORE_DIR)"
  Write-Host "MCP      : $($cfg.WHATSAPP_MCP_NAME)"
  Write-Host "Numero   : $(NumeroDe $cfg.WHATSAPP_STORE_DIR)"
  $procId = PidReal $n
  if ($procId) { Write-Host "Proceso  : corriendo (PID $procId)" } else { Write-Host "Proceso  : parado" }
  if (ApiVivo $cfg.WHATSAPP_BRIDGE_PORT) {
    Write-Host "API      : responde en http://localhost:$($cfg.WHATSAPP_BRIDGE_PORT)/api"
  } else { Write-Host "API      : no responde" }
  if (Test-Path (Join-Path $cfg.WHATSAPP_STORE_DIR "whatsapp.db")) {
    Write-Host "Sesion   : vinculada"
  } else { Write-Host "Sesion   : SIN VINCULAR (corre: wactl.ps1 qr $n)" }
}

function Cmd-Logs($n, $lineas) {
  if (-not $n) { Morir "falta el nombre" }
  Cargar $n | Out-Null
  if (-not $lineas) { $lineas = 40 }
  $log = Join-Path $InstancesDir "$n\bridge.log"
  if (-not (Test-Path $log)) { Morir "no hay registro para '$n'" }
  Get-Content $log -Tail ([int]$lineas)
}

function Cmd-Mcp($n) {
  if (-not $n) { Morir "falta el nombre" }
  $cfg = Cargar $n
  $uv = (Get-Command uv -ErrorAction SilentlyContinue).Source
  if (-not $uv) { Morir "no encuentro uv" }
  Write-Host "Registrando '$($cfg.WHATSAPP_MCP_NAME)' en Claude Code..."
  & claude mcp add $cfg.WHATSAPP_MCP_NAME --scope user `
      --env "WHATSAPP_API_BASE_URL=$($cfg.WHATSAPP_API_BASE_URL)" `
      --env "WHATSAPP_MESSAGES_DB=$($cfg.WHATSAPP_MESSAGES_DB)" `
      --env "WHATSAPP_MCP_NAME=$($cfg.WHATSAPP_MCP_NAME)" `
      -- $uv --directory $McpServerDir run main.py
  if ($LASTEXITCODE -eq 0) { Ok "Listo. Reinicia Claude Code para ver las herramientas de '$n'." }
}

function Cmd-Autostart($n) {
  if (-not $n) { Morir "falta el nombre" }
  $cfg = Cargar $n
  $task = "$TaskPrefix-$n"
  $wrapper = Join-Path $InstancesDir "$n\arrancar.ps1"

  @"
`$env:WHATSAPP_STORE_DIR   = '$($cfg.WHATSAPP_STORE_DIR)'
`$env:WHATSAPP_BRIDGE_PORT = '$($cfg.WHATSAPP_BRIDGE_PORT)'
Set-Location '$(Split-Path -Parent $BridgeBin)'
& '$BridgeBin' *>> '$(Join-Path $InstancesDir "$n\bridge.log")'
"@ | Set-Content -Encoding UTF8 $wrapper

  $accion  = New-ScheduledTaskAction -Execute "powershell.exe" `
              -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wrapper`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  # Reinicio automatico: el puente sale con codigo 0 cuando no logra conectar,
  # asi que hay que revivirlo pase lo que pase, no solo cuando falla.
  $ajustes = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
              -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

  Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
  # -User con el usuario actual evita que Windows pida permisos de administrador.
  Register-ScheduledTask -TaskName $task -Action $accion -Trigger $trigger `
    -Settings $ajustes -User $env:USERNAME | Out-Null
  Ok "'$n' queda arrancando sola al encender (tarea: $task)"
}

function Cmd-Remove($n) {
  if (-not $n) { Morir "falta el nombre" }
  $cfg = Cargar $n
  Write-Host "Esto elimina la cuenta '$n':"
  Write-Host "  - su sesion de WhatsApp (habria que volver a escanear el QR)"
  Write-Host "  - su historial en $($cfg.WHATSAPP_STORE_DIR)"
  $conf = Read-Host "Escribe el nombre de la cuenta para confirmar"
  if ($conf -ne $n) { Info "cancelado"; return }
  Cmd-Stop $n
  Unregister-ScheduledTask -TaskName "$TaskPrefix-$n" -Confirm:$false -ErrorAction SilentlyContinue
  & claude mcp remove $cfg.WHATSAPP_MCP_NAME --scope user 2>$null
  Remove-Item -Recurse -Force (Join-Path $InstancesDir $n) -ErrorAction SilentlyContinue
  Remove-Item -Force (EnvFile $n) -ErrorAction SilentlyContinue
  Ok "Cuenta '$n' eliminada"
}

switch ($Comando.ToLower()) {
  "list"      { Cmd-List }
  "new"       { Cmd-New $Nombre }
  "qr"        { Cmd-Qr $Nombre }
  "start"     { Cmd-Start $Nombre }
  "stop"      { Cmd-Stop $Nombre }
  "restart"   { Cmd-Stop $Nombre; Start-Sleep -Seconds 1; Cmd-Start $Nombre }
  "status"    { Cmd-Status $Nombre }
  "logs"      { Cmd-Logs $Nombre $Extra }
  "mcp"       { Cmd-Mcp $Nombre }
  "autostart" { Cmd-Autostart $Nombre }
  "remove"    { Cmd-Remove $Nombre }
  default     { Get-Content $MyInvocation.MyCommand.Path | Select-Object -First 17 |
                ForEach-Object { $_ -replace '^#\s?','' } }
}
