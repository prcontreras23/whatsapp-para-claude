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
#   wactl.ps1 logs <nombre> [lineas]   ultimas lineas del registro
#   wactl.ps1 logs <nombre> -f         seguir el registro en vivo (Ctrl+C sale)
#   wactl.ps1 mcp <nombre>             conectarla a Claude Code
#   wactl.ps1 autostart <nombre>       que arranque sola al encender
#   wactl.ps1 remove <nombre>          eliminarla

param(
  [Parameter(Position=0)][string]$Comando = "list",
  [Parameter(Position=1)][string]$Nombre  = "",
  [Parameter(Position=2)][string]$Extra   = "",
  [Alias('f')][switch]$Seguir
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$WactlHome    = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstancesDir = if ($env:WHATSAPP_INSTANCES_DIR) { $env:WHATSAPP_INSTANCES_DIR }
                else { Join-Path $env:USERPROFILE ".whatsapp-para-claude" }
$BridgeBin    = Join-Path $WactlHome "whatsapp-bridge\whatsapp-bridge.exe"
$McpServerDir = Join-Path $WactlHome "whatsapp-mcp-server"
$TaskPrefix   = "WhatsAppParaClaude"

function Ok($m)    { Write-Host $m -ForegroundColor Green }
function Info($m)  { Write-Host $m -ForegroundColor DarkGray }
function Falla($m) { Write-Host $m -ForegroundColor Red }
function Morir($m) { Write-Host "Error: $m" -ForegroundColor Red; exit 1 }

function EnvFile($n) { Join-Path $InstancesDir "$n.env" }
function DirDe($n)   { Join-Path $InstancesDir $n }
function PidFile($n) { Join-Path (DirDe $n) "bridge.pid" }
function LogDe($n)   { Join-Path (DirDe $n) "bridge.log" }
# Mientras exista, el supervisor no vuelve a encender el puente.
function MarcaParada($n) { Join-Path (DirDe $n) "detenida" }
function Arranque($n)    { Join-Path (DirDe $n) "arrancar.ps1" }
function AccesoInicio($n) {
  Join-Path ([Environment]::GetFolderPath('Startup')) "WhatsApp para Claude - $n.vbs"
}
function Tarea($n) { "$TaskPrefix-$n" }
function TareaExiste($n) {
  $null -ne (Get-ScheduledTask -TaskName (Tarea $n) -ErrorAction SilentlyContinue)
}

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

function Cuentas {
  @(Get-ChildItem "$InstancesDir\*.env" -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
}

# ------------------------------------------------------------------ procesos

function DuenoPuerto($puerto) {
  $c = Get-NetTCPConnection -LocalPort $puerto -State Listen -ErrorAction SilentlyContinue |
       Select-Object -First 1
  if (-not $c) { return $null }
  return Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
}

function PuertoOcupado($puerto) { $null -ne (DuenoPuerto $puerto) }

# Todos los puentes de esta cuenta, esten o no en el archivo de PID:
#  - los que llevan la marca --instancia=<n> en la linea de comandos,
#  - el que esta escuchando en su puerto,
#  - el del archivo de PID,
#  - y, si hay una sola cuenta, los que quedaron sin marca de versiones viejas.
function PidsDe($n, $cfg) {
  $ids = New-Object System.Collections.Generic.List[int]
  $todos = @(Get-CimInstance Win32_Process -Filter "Name='whatsapp-bridge.exe'" -ErrorAction SilentlyContinue)
  foreach ($p in $todos) {
    if ($p.CommandLine -match "--instancia=$n(\s|""|$)") { $ids.Add([int]$p.ProcessId) }
  }
  $dueno = DuenoPuerto $cfg.WHATSAPP_BRIDGE_PORT
  if ($dueno -and $dueno.ProcessName -like "whatsapp-bridge*") { $ids.Add([int]$dueno.Id) }
  $pf = PidFile $n
  if (Test-Path $pf) {
    $procId = Get-Content $pf -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($procId -match '^\d+$') {
      $p = Get-Process -Id ([int]$procId) -ErrorAction SilentlyContinue
      if ($p -and $p.ProcessName -like "whatsapp-bridge*") { $ids.Add([int]$procId) }
    }
  }
  if ((Cuentas).Count -le 1) {
    foreach ($p in $todos) {
      if ($p.CommandLine -notmatch '--instancia=' -and $p.ExecutablePath -eq $BridgeBin) {
        $ids.Add([int]$p.ProcessId)
      }
    }
  }
  return @($ids | Sort-Object -Unique)
}

# El powershell que mantiene encendido el puente de esta cuenta.
function SupervisorDe($n) {
  $ruta = Arranque $n
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($ruta) })
}

# Lo que el puente dice de si mismo, o $null si no responde.
function EstadoApi($puerto) {
  try {
    return Invoke-RestMethod -Uri "http://localhost:$puerto/api/status" -TimeoutSec 3
  } catch { return $null }
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

# Telefono vinculado, o "sin vincular". Se le pregunta al propio puente: leer
# whatsapp.db a mano no sirve, porque recien vinculada la sesion vive en
# whatsapp.db-wal y el archivo principal todavia no tiene el numero.
function NumeroDe($store) {
  if (-not (Test-Path (Join-Path $store "whatsapp.db"))) { return "sin vincular" }
  if (-not (Test-Path $BridgeBin)) { return "-" }
  $antes = $env:WHATSAPP_STORE_DIR
  try {
    $env:WHATSAPP_STORE_DIR = $store
    $ErrorActionPreference = "Continue"
    $num = & $BridgeBin --numero 2>$null | Select-Object -First 1
    if ($num -match '^\+\d+$') { return $num }
    return "sin vincular"
  } catch { return "-" }
  finally { $env:WHATSAPP_STORE_DIR = $antes }
}

# ------------------------------------------------------------------ registro

# Lee el final del archivo en UTF-8 y sin bloquearlo (el puente lo esta
# escribiendo). Get-Content lo leia con otra codificacion y el QR salia roto.
function ColaDe($ruta, [int]$lineas) {
  if (-not (Test-Path $ruta)) { return @() }
  $fs = [System.IO.File]::Open($ruta, 'Open', 'Read', 'ReadWrite')
  try {
    $desde = [Math]::Max(0, $fs.Length - 262144)
    [void]$fs.Seek($desde, 'Begin')
    $buf = New-Object byte[] ($fs.Length - $desde)
    $leido = 0
    while ($leido -lt $buf.Length) {
      $r = $fs.Read($buf, $leido, $buf.Length - $leido)
      if ($r -le 0) { break }
      $leido += $r
    }
  } finally { $fs.Close() }
  $partes = New-Object System.Collections.Generic.List[string]
  $partes.AddRange([string[]]([System.Text.Encoding]::UTF8.GetString($buf, 0, $leido) -split "`r?`n"))
  # Si se empezo a leer a mitad del archivo, la primera linea viene cortada.
  if ($desde -gt 0 -and $partes.Count) { $partes.RemoveAt(0) }
  if ($partes.Count -and $partes[$partes.Count - 1] -eq '') { $partes.RemoveAt($partes.Count - 1) }
  return @($partes | Select-Object -Last $lineas)
}

function SeguirLog($ruta) {
  Info "(siguiendo $ruta - Ctrl+C para salir)"
  ColaDe $ruta 20 | ForEach-Object { Write-Host $_ }
  $pos = (Get-Item $ruta).Length
  $dec = [System.Text.Encoding]::UTF8.GetDecoder()
  while ($true) {
    Start-Sleep -Milliseconds 700
    if (-not (Test-Path $ruta)) { continue }
    $fs = [System.IO.File]::Open($ruta, 'Open', 'Read', 'ReadWrite')
    $r = 0
    try {
      if ($fs.Length -lt $pos) { $pos = 0 }   # el supervisor empezo un registro nuevo
      if ($fs.Length -gt $pos) {
        [void]$fs.Seek($pos, 'Begin')
        $buf = New-Object byte[] ($fs.Length - $pos)
        $r = $fs.Read($buf, 0, $buf.Length)
        $pos += $r
      }
    } finally { $fs.Close() }
    if ($r -gt 0) {
      $chars = New-Object char[] ($dec.GetCharCount($buf, 0, $r))
      [void]$dec.GetChars($buf, 0, $r, $chars, 0)
      [Console]::Write(-join $chars)
    }
  }
}

# ------------------------------------------------------------------ supervisor

# Escribe arrancar.ps1, que mantiene UN solo puente encendido para la cuenta y
# lo revive si se cae. Si ya hay uno corriendo (por ejemplo el que dejo el
# instalador al vincular), lo adopta y espera a que termine en vez de abrir
# otro con la misma sesion: dos a la vez hacen que WhatsApp desconecte a uno.
function EscribirArranque($n, $cfg) {
  New-Item -ItemType Directory -Force -Path (DirDe $n) | Out-Null
  $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
  @"
# Generado por wactl.ps1 - mantiene encendido el puente de la cuenta '$n'.
`$ErrorActionPreference = 'Continue'
`$env:WHATSAPP_STORE_DIR   = $(& $q $cfg.WHATSAPP_STORE_DIR)
`$env:WHATSAPP_BRIDGE_PORT = '$($cfg.WHATSAPP_BRIDGE_PORT)'
`$env:WHATSAPP_NO_QR       = '1'
`$bin   = $(& $q $BridgeBin)
`$log   = $(& $q (LogDe $n))
`$parar = $(& $q (MarcaParada $n))
`$pidf  = $(& $q (PidFile $n))
while (-not (Test-Path `$parar)) {
  `$vivo = Get-CimInstance Win32_Process -Filter "Name='whatsapp-bridge.exe'" |
           Where-Object { `$_.CommandLine -match '--instancia=$n(\s|"|`$)' } | Select-Object -First 1
  if (`$vivo) {
    `$vivo.ProcessId | Set-Content `$pidf
    Wait-Process -Id `$vivo.ProcessId -ErrorAction SilentlyContinue
    continue
  }
  if (Test-Path `$log) { Move-Item -Force `$log "`$log.anterior" -ErrorAction SilentlyContinue }
  `$p = Start-Process -FilePath `$bin -ArgumentList '--instancia=$n' ``
         -WorkingDirectory (Split-Path -Parent `$bin) ``
         -RedirectStandardOutput `$log -RedirectStandardError "`$log.err" ``
         -WindowStyle Hidden -PassThru
  `$null = `$p.Handle
  `$p.Id | Set-Content `$pidf
  `$p.WaitForExit()
  # 2 = la cuenta no esta vinculada: reintentar no arregla nada.
  if (`$p.ExitCode -eq 2) { break }
  Start-Sleep -Seconds 15
}
"@ | Set-Content -Encoding UTF8 (Arranque $n)
}

function LanzarSupervisor($n) {
  if (TareaExiste $n) {
    Start-ScheduledTask -TaskName (Tarea $n)
  } else {
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
      "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass",
      "-File", "`"$(Arranque $n)`"")
  }
}

# ------------------------------------------------------------------ comandos

function Cmd-List {
  New-Item -ItemType Directory -Force -Path $InstancesDir | Out-Null
  $nombres = Cuentas
  if (-not $nombres) { Info "(ninguna todavia - creala con: wactl.ps1 new <nombre>)"; return }

  "{0,-14} {1,-7} {2,-13} {3}" -f "CUENTA","PUERTO","ESTADO","NUMERO" | Write-Host
  "{0,-14} {1,-7} {2,-13} {3}" -f "------","------","------","------" | Write-Host
  foreach ($n in $nombres) {
    $cfg = Cargar $n
    $st = EstadoApi $cfg.WHATSAPP_BRIDGE_PORT
    if ($st -and $st.connected) { $estado = "conectado" }
    elseif ($st -and -not $st.phone) { $estado = "sin vincular" }
    elseif ($st) { $estado = "sin conexion" }
    elseif ((PidsDe $n $cfg).Count) { $estado = "arrancando" }
    else { $estado = "parado" }
    if ($st -and $st.phone) { $num = $st.phone }
    else {
      $num = NumeroDe $cfg.WHATSAPP_STORE_DIR
      if ($num -eq "sin vincular") { $num = "-" }
    }
    "{0,-14} {1,-7} {2,-13} {3}" -f $n, $cfg.WHATSAPP_BRIDGE_PORT, $estado, $num | Write-Host
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
  if ((PidsDe $n $cfg).Count) { Morir "'$n' ya esta corriendo. Parala primero: wactl.ps1 stop $n" }

  Write-Host "Arrancando '$n'."
  Write-Host "Escanea el QR desde: WhatsApp -> Ajustes -> Dispositivos vinculados -> Vincular un dispositivo"
  Write-Host "Cuando termine de sincronizar, Ctrl+C y luego: wactl.ps1 start $n"
  Write-Host ""

  New-Item -ItemType Directory -Force -Path $cfg.WHATSAPP_STORE_DIR | Out-Null
  $env:WHATSAPP_STORE_DIR   = $cfg.WHATSAPP_STORE_DIR
  $env:WHATSAPP_BRIDGE_PORT = $cfg.WHATSAPP_BRIDGE_PORT
  Push-Location (Split-Path -Parent $BridgeBin)
  try { & $BridgeBin "--instancia=$n" } finally { Pop-Location }
}

function Cmd-Start($n) {
  if (-not $n) { Morir "falta el nombre" }
  $cfg = Cargar $n
  $puerto = $cfg.WHATSAPP_BRIDGE_PORT

  $pids = PidsDe $n $cfg
  if ($pids.Count -gt 1) {
    Info "habia $($pids.Count) puentes de '$n' a la vez; se cierran y queda uno solo"
    Cmd-Stop $n
    $pids = @()
  }
  $sup = SupervisorDe $n
  if ($pids.Count -and $sup.Count) {
    Info "'$n' ya estaba corriendo (PID $($pids[0]))"
  } else {
    if (-not $pids.Count) {
      $dueno = DuenoPuerto $puerto
      if ($dueno) {
        Morir ("el puerto $puerto lo esta usando '$($dueno.ProcessName)' (PID $($dueno.Id)).`n" +
               "  Cierralo con:  Stop-Process -Id $($dueno.Id) -Force`n" +
               "  o cambia WHATSAPP_BRIDGE_PORT en $(EnvFile $n)")
      }
      if ((NumeroDe $cfg.WHATSAPP_STORE_DIR) -eq "sin vincular") {
        Morir "'$n' no esta vinculada todavia. Corre primero: wactl.ps1 qr $n"
      }
    }
    # Si ya hay un puente corriendo, el supervisor lo adopta en vez de abrir otro.
    Remove-Item (MarcaParada $n) -ErrorAction SilentlyContinue
    EscribirArranque $n $cfg
    LanzarSupervisor $n
  }

  # Se espera la conexion real con WhatsApp, no solo que el puerto conteste.
  Info "esperando la conexion con WhatsApp..."
  $st = $null
  for ($i = 0; $i -lt 45; $i++) {
    $st = EstadoApi $puerto
    if ($st -and $st.connected) { break }
    Start-Sleep -Seconds 1
  }
  if ($st -and $st.connected) {
    Ok "'$n' conectada a WhatsApp ($($st.phone)) en el puerto $puerto"
  } elseif ($st -and -not $st.phone) {
    Falla "'$n' esta desvinculada de WhatsApp. Vuelve a vincularla: wactl.ps1 stop $n  y luego  wactl.ps1 qr $n"
    exit 1
  } elseif ($st) {
    Falla "'$n' esta encendida pero no logra conectar con WhatsApp. Mira: wactl.ps1 logs $n"
    exit 1
  } else {
    Falla "'$n' no arranco. Mira el registro: wactl.ps1 logs $n"
    exit 1
  }
}

function Cmd-Stop($n) {
  if (-not $n) { Morir "falta el nombre" }
  $cfg = Cargar $n
  New-Item -ItemType Directory -Force -Path (DirDe $n) | Out-Null
  # Primero se le dice al supervisor que no lo vuelva a encender.
  New-Item -ItemType File -Force -Path (MarcaParada $n) | Out-Null
  foreach ($s in SupervisorDe $n) { Stop-Process -Id $s.ProcessId -Force -ErrorAction SilentlyContinue }
  $pids = PidsDe $n $cfg
  if (-not $pids.Count) {
    Remove-Item (PidFile $n) -ErrorAction SilentlyContinue
    Info "'$n' no estaba corriendo"
    return
  }
  foreach ($procId in $pids) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
  for ($i = 0; $i -lt 10 -and (PidsDe $n $cfg).Count; $i++) { Start-Sleep -Milliseconds 500 }
  Remove-Item (PidFile $n) -ErrorAction SilentlyContinue
  $quedan = PidsDe $n $cfg
  if ($quedan.Count) { Morir "no pude detener '$n' (PID $($quedan -join ', '))" }
  Ok "'$n' detenida (PID $($pids -join ', '))"
}

function Cmd-Status($n) {
  if (-not $n) { Cmd-List; return }
  $cfg = Cargar $n
  $puerto = $cfg.WHATSAPP_BRIDGE_PORT
  $st = EstadoApi $puerto
  $num = if ($st -and $st.phone) { $st.phone } else { NumeroDe $cfg.WHATSAPP_STORE_DIR }
  Write-Host "Cuenta   : $n"
  Write-Host "Puerto   : $puerto"
  Write-Host "Datos    : $($cfg.WHATSAPP_STORE_DIR)"
  Write-Host "MCP      : $($cfg.WHATSAPP_MCP_NAME)"
  Write-Host "Numero   : $num"
  $pids = PidsDe $n $cfg
  if ($pids.Count -gt 1) {
    Falla "Proceso  : HAY $($pids.Count) PUENTES A LA VEZ (PID $($pids -join ', ')). Corre: wactl.ps1 restart $n"
  } elseif ($pids.Count) { Write-Host "Proceso  : corriendo (PID $($pids[0]))" }
  else { Write-Host "Proceso  : parado" }
  if (TareaExiste $n) { Write-Host "Inicio   : tarea programada $(Tarea $n)" }
  elseif (Test-Path (AccesoInicio $n)) { Write-Host "Inicio   : acceso en la carpeta Inicio" }
  else { Write-Host "Inicio   : no arranca sola (wactl.ps1 autostart $n)" }
  if ($st -and $st.connected) {
    Ok "Conexion : conectada a WhatsApp"
  } elseif ($st -and -not $st.phone) {
    Falla "Conexion : el puente responde pero no tiene sesion (wactl.ps1 stop $n y luego wactl.ps1 qr $n)"
  } elseif ($st) {
    Falla "Conexion : el puente responde pero NO esta conectado a WhatsApp (wactl.ps1 restart $n)"
  } elseif (PuertoOcupado $puerto) {
    Falla "Conexion : el puerto $puerto lo tiene otro programa o una version vieja del puente"
  } else { Write-Host "Conexion : el puente no responde" }
}

function Cmd-Logs($n, $lineas) {
  if (-not $n) { Morir "falta el nombre" }
  $cfg = Cargar $n
  $log = LogDe $n
  if (-not (Test-Path $log)) { Morir "no hay registro para '$n'" }
  if ($Seguir -or $lineas -eq "seguir") { SeguirLog $log; return }
  if (-not $lineas) { $lineas = 40 }
  ColaDe $log ([int]$lineas) | ForEach-Object { Write-Host $_ }
  $err = ColaDe "$log.err" 10
  if ($err.Count) {
    Write-Host ""
    Info "--- errores ($log.err) ---"
    $err | ForEach-Object { Write-Host $_ }
  }
  Write-Host ""
  Info "(para seguirlo en vivo: wactl.ps1 logs $n -f)"
  Info "(si hay un codigo QR, tambien queda como imagen en $(Join-Path $cfg.WHATSAPP_STORE_DIR 'qr.png'))"
}

function Cmd-Mcp($n) {
  if (-not $n) { Morir "falta el nombre" }
  $cfg = Cargar $n
  $uv = (Get-Command uv -ErrorAction SilentlyContinue).Source
  if (-not $uv) { Morir "no encuentro uv" }
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Morir "no encuentro Claude Code" }

  # En Windows PowerShell 5.1, con "Stop", cualquier linea que claude escriba
  # en stderr (por ejemplo "No MCP server named ...", al quitar un registro que
  # no existe) se vuelve un error que tumba el script. Aqui los fallos se
  # revisan con $LASTEXITCODE.
  $ErrorActionPreference = "Continue"

  # Windows PowerShell 5.1 se traga el "--" al llamar programas externos, asi
  # que "claude mcp add ... -- uv --directory ..." llegaba roto y el registro
  # fallaba sin avisar. Se arma un .cmd con todo dentro y se registra ese, sin
  # argumentos con guion. Va con "cmd /c" porque Node no lanza un .cmd directo.
  $dir = DirDe $n
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $lanzador = Join-Path $dir "mcp.cmd"
  @(
    "@echo off",
    "set ""WHATSAPP_API_BASE_URL=$($cfg.WHATSAPP_API_BASE_URL)""",
    "set ""WHATSAPP_MESSAGES_DB=$($cfg.WHATSAPP_MESSAGES_DB)""",
    "set ""WHATSAPP_MCP_NAME=$($cfg.WHATSAPP_MCP_NAME)""",
    """$uv"" --directory ""$McpServerDir"" run main.py"
  ) | ForEach-Object {
    # Las rutas van como %USERPROFILE% para que un nombre de usuario con tilde
    # no se dane al escribir el .cmd en ASCII.
    $_.Replace($env:USERPROFILE, '%USERPROFILE%')
  } | Set-Content -Path $lanzador -Encoding ASCII

  Write-Host "Registrando '$($cfg.WHATSAPP_MCP_NAME)' en Claude Code..."
  & claude mcp remove $cfg.WHATSAPP_MCP_NAME --scope user 2>$null | Out-Null
  & claude mcp add $cfg.WHATSAPP_MCP_NAME --scope user cmd /c $lanzador
  if ($LASTEXITCODE -ne 0) { Morir "Claude Code no acepto el registro de '$($cfg.WHATSAPP_MCP_NAME)'" }

  # Se confirma que quedo registrado, en vez de darlo por hecho.
  & claude mcp get $cfg.WHATSAPP_MCP_NAME 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { Morir "'$($cfg.WHATSAPP_MCP_NAME)' no aparece en Claude Code despues de registrarlo" }
  Ok "Listo. Las herramientas de '$n' salen en las sesiones NUEVAS de Claude Code; las que ya estaban abiertas no las ven."
}

function Cmd-Autostart($n) {
  if (-not $n) { Morir "falta el nombre" }
  $cfg = Cargar $n
  EscribirArranque $n $cfg
  $wrapper = Arranque $n

  # El nombre completo (EQUIPO\usuario, AzureAD\usuario...). Con solo
  # $env:USERNAME, en cuentas de Microsoft o de una organizacion, Windows
  # responde "El parametro no es correcto (UserId)".
  $yo = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

  $registrada = $false
  try {
    $accion = New-ScheduledTaskAction -Execute "powershell.exe" `
                -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wrapper`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $yo
    $principal = New-ScheduledTaskPrincipal -UserId $yo -LogonType Interactive -RunLevel Limited
    # ExecutionTimeLimit en cero: por defecto Windows mata la tarea a las 72
    # horas. Los reinicios del puente los hace arrancar.ps1, no la tarea.
    $ajustes = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Unregister-ScheduledTask -TaskName (Tarea $n) -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName (Tarea $n) -Action $accion -Trigger $trigger `
      -Principal $principal -Settings $ajustes -ErrorAction Stop | Out-Null
    $registrada = TareaExiste $n
  } catch {
    Info "no se pudo crear la tarea programada: $($_.Exception.Message.Trim())"
  }

  if ($registrada) {
    Remove-Item (AccesoInicio $n) -ErrorAction SilentlyContinue
    Ok "'$n' queda arrancando sola al encender (tarea: $(Tarea $n))"
    return
  }

  # Plan B, que no pide ningun permiso: un lanzador en la carpeta Inicio.
  try {
    $vbs = AccesoInicio $n
    "CreateObject(""WScript.Shell"").Run ""powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """"$wrapper"""""", 0, False" |
      Set-Content -Path $vbs -Encoding Unicode
    if (-not (Test-Path $vbs)) { throw "no se creo $vbs" }
    Ok "'$n' queda arrancando sola al encender (acceso en la carpeta Inicio)"
  } catch {
    Morir "no pude dejar '$n' arrancando sola al encender: $($_.Exception.Message)"
  }
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
  $ErrorActionPreference = "Continue"
  Unregister-ScheduledTask -TaskName (Tarea $n) -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item (AccesoInicio $n) -ErrorAction SilentlyContinue
  & claude mcp remove $cfg.WHATSAPP_MCP_NAME --scope user 2>$null
  Remove-Item -Recurse -Force (DirDe $n) -ErrorAction SilentlyContinue
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
  default     { Get-Content $MyInvocation.MyCommand.Path | Select-Object -First 16 |
                ForEach-Object { $_ -replace '^#\s?','' } }
}
