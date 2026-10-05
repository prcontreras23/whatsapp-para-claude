# Instalacion de los programas que hacen falta (Go, uv, ffmpeg) en Windows.
#
# No depende de winget: lo usa si esta y funciona, pero si no, cae a los
# instaladores oficiales de cada herramienta, que se extraen dentro de la
# carpeta del usuario y no piden permisos de administrador.
#
# Lo cargan install.ps1 e instalador-grafico.ps1.

$script:LocalBin = Join-Path $env:USERPROFILE ".local\bin"
$script:LocalGo  = Join-Path $env:USERPROFILE ".local\go"

# Rutas donde estas herramientas suelen quedar, esten o no en el PATH heredado.
function Ruta-Extendida {
  $extra = @(
    $script:LocalBin,
    (Join-Path $script:LocalGo "bin"),
    (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links"),
    "C:\Program Files\Go\bin"
  )
  foreach ($d in $extra) {
    if ((Test-Path $d) -and ($env:PATH -notlike "*$d*")) {
      $env:PATH = "$d;$env:PATH"
    }
  }
}

function Tiene($cmd) { $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }

# Intenta con winget. Devuelve $false si no esta o si falla, para poder caer al
# metodo oficial sin dar el paso por perdido.
function Probar-Winget($paqueteId) {
  if (-not (Tiene winget)) { return $false }
  try {
    winget install --id $paqueteId -e --accept-source-agreements `
      --accept-package-agreements --silent 2>&1 | Out-Null
  } catch { return $false }
  Ruta-Extendida
  return $true
}

# ------------------------------------------------------------------ Go

function Instalar-Go {
  Ruta-Extendida
  if (Tiene go) { return $true }

  if (Probar-Winget "GoLang.Go") { Ruta-Extendida; if (Tiene go) { return $true } }

  # ZIP oficial de Go, extraido en la carpeta del usuario.
  # En Windows PowerShell 5.1: sin TLS 1.2 forzado la descarga puede fallar, y
  # con la barra de progreso visible Invoke-WebRequest baja un ZIP de 80 MB a
  # paso de tortuga. Si aun asi falla, se intenta con curl.exe (viene en
  # Windows 10 y 11).
  $script:ErrorGo = ""
  $progresoAntes = $ProgressPreference
  $ProgressPreference = 'SilentlyContinue'
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
  try {
    $version = $null
    try {
      $lista = Invoke-RestMethod -Uri "https://go.dev/dl/?mode=json" -TimeoutSec 30
      $version = @($lista)[0].version
    } catch {
      $version = ((curl.exe -fsSL "https://go.dev/VERSION?m=text") -split "`n")[0].Trim()
    }
    if (-not $version) { throw "no pude averiguar la version actual de Go" }

    $nombre = "$version.windows-$arch.zip"
    $url = "https://dl.google.com/go/$nombre"
    $zip = Join-Path $env:TEMP $nombre
    $destino = Join-Path $env:USERPROFILE ".local"

    New-Item -ItemType Directory -Force -Path $destino | Out-Null
    if (Test-Path $script:LocalGo) { Remove-Item -Recurse -Force $script:LocalGo }

    try {
      Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    } catch {
      curl.exe -fL --retry 3 -o $zip $url
      if ($LASTEXITCODE -ne 0) { throw "la descarga de $url fallo (curl $LASTEXITCODE)" }
    }
    if ((Get-Item $zip).Length -lt 10MB) {
      throw "la descarga de $url llego incompleta ($((Get-Item $zip).Length) bytes)"
    }
    Expand-Archive -Path $zip -DestinationPath $destino -Force
    Remove-Item $zip -ErrorAction SilentlyContinue
  } catch {
    $script:ErrorGo = $_.Exception.Message
    $ProgressPreference = $progresoAntes
    return $false
  }
  $ProgressPreference = $progresoAntes

  Ruta-Extendida
  return (Tiene go)
}

# ------------------------------------------------------------------ uv

function Instalar-Uv {
  Ruta-Extendida
  if (Tiene uv) { return $true }

  if (Probar-Winget "astral-sh.uv") { Ruta-Extendida; if (Tiene uv) { return $true } }

  # Instalador oficial de Astral: deja uv en la carpeta del usuario, sin admin.
  try {
    $script = Invoke-RestMethod -Uri "https://astral.sh/uv/install.ps1" -TimeoutSec 30
    Invoke-Expression $script | Out-Null
  } catch {
    return $false
  }

  # El instalador de Astral usa su propia carpeta; se agrega al PATH de la sesion.
  $uvBin = Join-Path $env:USERPROFILE ".local\bin"
  if ((Test-Path $uvBin) -and ($env:PATH -notlike "*$uvBin*")) {
    $env:PATH = "$uvBin;$env:PATH"
  }
  Ruta-Extendida
  return (Tiene uv)
}

# ------------------------------------------------------------------ git

function Instalar-Git {
  Ruta-Extendida
  if (Tiene git) { return $true }

  if (Probar-Winget "Git.Git") { Ruta-Extendida; if (Tiene git) { return $true } }

  # Instalador oficial de Git for Windows, en modo silencioso.
  try {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "64-bit" }
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -TimeoutSec 30
    $asset = $rel.assets | Where-Object { $_.name -like "*$arch.exe" -and $_.name -notlike "*Portable*" } | Select-Object -First 1
    if (-not $asset) { return $false }
    $exe = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $exe -UseBasicParsing
    Start-Process -FilePath $exe -ArgumentList "/VERYSILENT","/NORESTART" -Wait
    Remove-Item $exe -ErrorAction SilentlyContinue
  } catch {
    return $false
  }

  # Git for Windows instala en Program Files; se agrega al PATH de la sesion.
  foreach ($d in @("C:\Program Files\Git\cmd", "C:\Program Files (x86)\Git\cmd")) {
    if ((Test-Path $d) -and ($env:PATH -notlike "*$d*")) { $env:PATH = "$d;$env:PATH" }
  }
  return (Tiene git)
}

# ------------------------------------------------------------------ Claude Code

function Instalar-Claude {
  Ruta-Extendida
  if (Tiene claude) { return $true }

  # Instalador oficial de Anthropic: deja claude en la carpeta del usuario,
  # se actualiza solo, y no necesita winget ni npm ni Node.
  try {
    $script = Invoke-RestMethod -Uri "https://claude.ai/install.ps1" -TimeoutSec 60
    Invoke-Expression $script | Out-Null
  } catch {
    return $false
  }

  Ruta-Extendida
  return (Tiene claude)
}

# ------------------------------------------------------------------ sesion de WhatsApp

# Lee el numero vinculado de la sesion. Sirve para distinguir una sesion real de
# un whatsapp.db vacio que dejo un intento anterior sin escanear.
#
# Se le pregunta al propio puente (whatsapp-bridge.exe --numero) en vez de
# buscar el numero dentro del archivo: recien vinculada, la sesion vive en
# whatsapp.db-wal y no en whatsapp.db, y la busqueda a mano decia "sin vincular"
# con una sesion buena. Eso hacia que el instalador levantara un segundo puente
# con la misma sesion.
function NumeroDe($store, $bin) {
  if (-not (Test-Path (Join-Path $store "whatsapp.db"))) { return "sin vincular" }
  if (-not $bin -or -not (Test-Path $bin)) { return "sin vincular" }
  $antesStore = $env:WHATSAPP_STORE_DIR
  $antesEap = $ErrorActionPreference
  try {
    $env:WHATSAPP_STORE_DIR = $store
    $ErrorActionPreference = "Continue"
    $num = & $bin --numero 2>$null | Select-Object -First 1
    if ($num -match '^\+\d+$') { return $num }
  } catch {}
  finally {
    $env:WHATSAPP_STORE_DIR = $antesStore
    $ErrorActionPreference = $antesEap
  }
  return "sin vincular"
}

# Lo que el puente dice de si mismo (/api/status): si esta conectado a WhatsApp
# de verdad, no solo si el puerto contesta. $null si no responde.
function EstadoPuente($puerto) {
  try {
    return Invoke-RestMethod -Uri "http://localhost:$puerto/api/status" -TimeoutSec 3
  } catch { return $null }
}

# ------------------------------------------------------------------ Claude Desktop

# La app de escritorio. Distinta de Claude Code: una es ventana, la otra terminal.
function Tiene-ClaudeDesktop {
  $rutas = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Claude\Claude.exe"),
    (Join-Path $env:LOCALAPPDATA "AnthropicClaude\Claude.exe"),
    "C:\Program Files\Claude\Claude.exe"
  )
  foreach ($r in $rutas) { if (Test-Path $r) { return $true } }
  if (Tiene winget) {
    try {
      $l = winget list --id Anthropic.Claude -e 2>$null | Out-String
      if ($l -match "Anthropic\.Claude") { return $true }
    } catch {}
  }
  return $false
}

function Instalar-ClaudeDesktop {
  if (Tiene-ClaudeDesktop) { return $true }
  if (Probar-Winget "Anthropic.Claude") {
    if (Tiene-ClaudeDesktop) { return $true }
  }
  return $false
}

# ------------------------------------------------------------------ ffmpeg

# ffmpeg solo hace falta para enviar notas de voz. Si no se puede instalar,
# no es motivo para abortar: todo lo demas funciona igual.
function Instalar-Ffmpeg {
  Ruta-Extendida
  if (Tiene ffmpeg) { return $true }
  if (Probar-Winget "Gyan.FFmpeg") { Ruta-Extendida; if (Tiene ffmpeg) { return $true } }
  return $false
}

# ------------------------------------------------------------------ PATH persistente

# Deja las rutas en el PATH del usuario para que sigan disponibles despues.
function Persistir-Ruta {
  try {
    $actual = [Environment]::GetEnvironmentVariable("PATH", "User")
    $anadir = @($script:LocalBin, (Join-Path $script:LocalGo "bin"))
    $nuevo = $actual
    foreach ($d in $anadir) {
      if ($nuevo -notlike "*$d*") {
        $nuevo = if ([string]::IsNullOrEmpty($nuevo)) { $d } else { "$nuevo;$d" }
      }
    }
    if ($nuevo -ne $actual) {
      [Environment]::SetEnvironmentVariable("PATH", $nuevo, "User")
    }
  } catch {
    # Si no se puede escribir el PATH del usuario, no es fatal: la sesion actual
    # ya tiene las rutas y el instalador termina igual.
  }
}
