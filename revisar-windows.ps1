# Audita una PC con Windows y luego instala y actualiza lo que haga falta.
#
# En PowerShell:
#   irm https://raw.githubusercontent.com/prcontreras23/whatsapp-para-claude/main/revisar-windows.ps1 | iex
#
# Primero informa: qué tiene, qué falta, qué está desactualizado. Al final
# ofrece arreglarlo todo. Nada se toca sin que lo confirmes.

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Repo = "prcontreras23/whatsapp-para-claude"

function Bold($m)  { Write-Host $m -ForegroundColor White }
function Gris($m)  { Write-Host $m -ForegroundColor DarkGray }
function Morir($m) { Write-Host ""; Write-Host "  X $m" -ForegroundColor Red; Write-Host ""; exit 1 }

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core' -and -not $env:OS) {
  Morir "Esto es para Windows. En Mac usa: curl -fsSL https://raw.githubusercontent.com/$Repo/main/revisar-mac.sh | bash"
}

# Trae Ruta-Extendida, Tiene, Instalar-*
try {
  $lib = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/$Repo/main/lib-requisitos.ps1" -TimeoutSec 30
  Invoke-Expression $lib
} catch {
  Morir "No se pudo bajar la revisión. Hay internet?"
}
Ruta-Extendida

$Faltan = @()
$Viejos = @()

# Compara versiones tipo 1.2.3. Devuelve $true si $a es menor que $b.
function MenorQue($a, $b) {
  try {
    $va = [version](($a -split '-')[0]); $vb = [version](($b -split '-')[0])
    return ($va -lt $vb)
  } catch { return $false }
}

# ---------------------------------------------------------------- la máquina

Write-Host ""
Bold "=== Revision de esta PC ==="
Write-Host ""

$os      = Get-CimInstance Win32_OperatingSystem
$cs      = Get-CimInstance Win32_ComputerSystem
$build   = [int]$os.BuildNumber
$ramGB   = [math]::Round($cs.TotalPhysicalMemory / 1GB)
$disco   = Get-PSDrive C -ErrorAction SilentlyContinue
$discoGB = if ($disco) { [math]::Round($disco.Free / 1GB) } else { 0 }
$arch    = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "ARM64" } else { "x64" }

"  {0,-16} {1}"    -f "Windows", "$($os.Caption.Trim()) (build $build)" | Write-Host
"  {0,-16} {1}"    -f "Procesador", $arch                               | Write-Host
"  {0,-16} {1} GB" -f "Memoria", $ramGB                                 | Write-Host
"  {0,-16} {1} GB libres" -f "Disco", $discoGB                          | Write-Host

Write-Host ""
$problema = $false
# Claude Code pide Windows 10 1809 (build 17763) o mas nuevo.
if ($build -lt 17763) {
  Write-Host "  X " -ForegroundColor Red -NoNewline
  Write-Host "Windows es muy viejo. Claude Code pide Windows 10 1809 o mas nuevo."
  $problema = $true
}
if ($ramGB -lt 4) {
  Write-Host "  X " -ForegroundColor Red -NoNewline
  Write-Host "Con $ramGB GB va a ir lento. Se recomiendan 4 GB o mas."
  $problema = $true
}
if (-not $problema) {
  Write-Host "  OK " -ForegroundColor Green -NoNewline
  Write-Host "La maquina cumple los requisitos"
}

# ---------------------------------------------------------------- últimas versiones

Write-Host ""
Gris "  consultando las versiones mas recientes..."

$ultGo = $null; $ultUv = $null
try {
  $ultGo = ((Invoke-RestMethod -Uri "https://go.dev/dl/?mode=json" -TimeoutSec 12)[0].version) -replace '^go',''
} catch {}
try {
  $ultUv = ((Invoke-RestMethod -Uri "https://api.github.com/repos/astral-sh/uv/releases/latest" -TimeoutSec 12).tag_name) -replace '^v',''
} catch {}

# ---------------------------------------------------------------- programas

function Revisar($nombre, $cmd, $verScript, $para, $ultima) {
  "  {0,-16} " -f $nombre | Write-Host -NoNewline
  if (-not (Tiene $cmd)) {
    Write-Host "X " -ForegroundColor Red -NoNewline
    Write-Host "falta - $para"
    $script:Faltan += $cmd
    return
  }
  $actual = $null
  try { $actual = (& ([scriptblock]::Create($verScript))) } catch {}
  if ($ultima -and $actual -and (MenorQue $actual $ultima)) {
    Write-Host "^ " -ForegroundColor Yellow -NoNewline
    Write-Host "$actual  ->  hay $ultima"
    $script:Viejos += $cmd
  } else {
    Write-Host "OK " -ForegroundColor Green -NoNewline
    Write-Host $(if ($actual) { $actual } else { "instalado" })
  }
}

Write-Host ""
Bold "Para Claude Code"
Revisar "git"         "git"    'if ((git --version) -match "(\d+\.\d+\.\d+)") { $Matches[1] }' "Claude Code lo usa para ver tus cambios" $null
Revisar "Claude Code" "claude" '((claude --version) -split " ")[0]' "es el programa principal" $null

Write-Host ""
Bold "Para conectar WhatsApp (opcional)"
Revisar "Go"     "go"     '((go version) -split " ")[2] -replace "^go",""' "compila el puente de WhatsApp" $ultGo
Revisar "uv"     "uv"     '((uv --version) -split " ")[1]'                 "corre el servidor de Claude"   $ultUv
Revisar "ffmpeg" "ffmpeg" 'if ((ffmpeg -version 2>$null | Select-Object -First 1) -match "version (\S+)") { $Matches[1] }' "solo para notas de voz" $null

Write-Host ""
Bold "Sistema"
"  {0,-16} " -f "winget" | Write-Host -NoNewline
if (Tiene winget) {
  Write-Host "OK " -ForegroundColor Green -NoNewline; Write-Host "disponible"
} else {
  Write-Host "o " -ForegroundColor Yellow -NoNewline
  Write-Host "no esta - y no hace falta, todo se instala sin el"
}

"  {0,-16} " -f "Git Bash" | Write-Host -NoNewline
if (Test-Path "C:\Program Files\Git\bin\bash.exe") {
  Write-Host "OK " -ForegroundColor Green -NoNewline; Write-Host "Claude Code podra usar comandos de Linux"
} else {
  Write-Host "o " -ForegroundColor Yellow -NoNewline
  Write-Host "sin el, Claude Code usa PowerShell (funciona igual)"
}

# ---------------------------------------------------------------- veredicto

Write-Host ""
if ($Faltan.Count -eq 0 -and $Viejos.Count -eq 0) {
  Bold "=== Todo en orden ==="
  Write-Host ""
  if (Tiene claude) { Gris "  Para empezar, abre PowerShell y escribe:  claude" }
  Write-Host ""
  exit 0
}

Bold "=== Resumen ==="
Write-Host ""
if ($Faltan.Count -gt 0) {
  Write-Host "  Falta instalar:"
  foreach ($f in $Faltan) {
    switch ($f) {
      "git"    { Write-Host "    - git - Git for Windows" }
      "claude" { Write-Host "    - Claude Code - instalador oficial de Anthropic" }
      "go"     { Write-Host "    - Go - solo si vas a conectar WhatsApp" }
      "uv"     { Write-Host "    - uv - solo si vas a conectar WhatsApp" }
      "ffmpeg" { Write-Host "    - ffmpeg - solo para notas de voz" }
    }
  }
  Write-Host ""
}
if ($Viejos.Count -gt 0) {
  Write-Host "  Se puede actualizar:  $($Viejos -join ', ')"
  Write-Host ""
}
Gris "  Nada de esto necesita que seas administrador."
Write-Host ""

# ---------------------------------------------------------------- arreglar

$resp = Read-Host "  Instalo y actualizo todo eso? [s/N]"
if ($resp -notmatch '^(s|si|y|yes)$') {
  Write-Host ""; Gris "  No se toco nada."; Write-Host ""; exit 0
}

Write-Host ""
foreach ($f in $Faltan) {
  "  instalando {0,-8} " -f $f | Write-Host -NoNewline
  $ok = switch ($f) {
    "git"    { Instalar-Git }
    "claude" { Instalar-Claude }
    "go"     { Instalar-Go }
    "uv"     { Instalar-Uv }
    "ffmpeg" { Instalar-Ffmpeg }
    default  { $false }
  }
  if ($ok) { Write-Host "OK" -ForegroundColor Green }
  elseif ($f -eq "ffmpeg") { Write-Host "o (opcional, se sigue sin el)" -ForegroundColor Yellow }
  else { Write-Host "X" -ForegroundColor Red }
}

foreach ($v in $Viejos) {
  "  actualizando {0,-8} " -f $v | Write-Host -NoNewline
  switch ($v) {
    "claude" {
      try { claude update 2>&1 | Out-Null; Write-Host "OK" -ForegroundColor Green }
      catch { Write-Host "o (se actualiza solo en segundo plano)" -ForegroundColor Yellow }
    }
    "go" {
      $goLocal = Join-Path $env:USERPROFILE ".local\go"
      if (Test-Path $goLocal) { Remove-Item -Recurse -Force $goLocal -ErrorAction SilentlyContinue }
      if (Instalar-Go) { Write-Host "OK" -ForegroundColor Green } else { Write-Host "X" -ForegroundColor Red }
    }
    "uv" {
      try { uv self update 2>&1 | Out-Null } catch { Instalar-Uv | Out-Null }
      Write-Host "OK" -ForegroundColor Green
    }
    default { Write-Host "o" -ForegroundColor Yellow }
  }
}

Persistir-Ruta

Write-Host ""
Bold "=== Listo ==="
Write-Host ""
if (Tiene claude) {
  Write-Host "  Abre una ventana NUEVA de PowerShell y escribe:  claude"
  Write-Host "  Se abre el navegador para que inicies sesion."
  Write-Host ""
  Gris "  Necesitas cuenta Pro, Max, Team o Enterprise. La gratuita no incluye Claude Code."
} else {
  Gris "  Claude Code no quedo instalado. Intentalo a mano:"
  Write-Host "     irm https://claude.ai/install.ps1 | iex"
}
Write-Host ""
Gris "  Conectar tu WhatsApp tambien? Descarga el repo y haz doble clic en 'Instalar en Windows.bat':"
Write-Host "     https://github.com/$Repo"
Write-Host ""
