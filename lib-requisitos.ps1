# Instalación de los programas que hacen falta (Go, uv, ffmpeg) en Windows.
#
# No depende de winget: lo usa si está y funciona, pero si no, cae a los
# instaladores oficiales de cada herramienta, que se extraen dentro de la
# carpeta del usuario y no piden permisos de administrador.
#
# Lo cargan install.ps1 e instalador-grafico.ps1.

$script:LocalBin = Join-Path $env:USERPROFILE ".local\bin"
$script:LocalGo  = Join-Path $env:USERPROFILE ".local\go"

# Rutas donde estas herramientas suelen quedar, estén o no en el PATH heredado.
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

# Intenta con winget. Devuelve $false si no está o si falla, para poder caer al
# método oficial sin dar el paso por perdido.
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

  # ZIP oficial de go.dev, extraído en la carpeta del usuario.
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
  try {
    $lista = Invoke-RestMethod -Uri "https://go.dev/dl/?mode=json" -TimeoutSec 30
    $archivo = $lista[0].files | Where-Object {
      $_.os -eq "windows" -and $_.arch -eq $arch -and $_.kind -eq "archive"
    } | Select-Object -First 1
    if (-not $archivo) { return $false }

    $url = "https://go.dev/dl/$($archivo.filename)"
    $zip = Join-Path $env:TEMP $archivo.filename
    $destino = Join-Path $env:USERPROFILE ".local"

    New-Item -ItemType Directory -Force -Path $destino | Out-Null
    if (Test-Path $script:LocalGo) { Remove-Item -Recurse -Force $script:LocalGo }

    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $destino -Force
    Remove-Item $zip -ErrorAction SilentlyContinue
  } catch {
    return $false
  }

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

# Deja las rutas en el PATH del usuario para que sigan disponibles después.
function Persistir-Ruta {
  try {
    $actual = [Environment]::GetEnvironmentVariable("PATH", "User")
    $añadir = @($script:LocalBin, (Join-Path $script:LocalGo "bin"))
    $nuevo = $actual
    foreach ($d in $añadir) {
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
