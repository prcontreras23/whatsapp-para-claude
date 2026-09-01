#!/bin/bash
# Instalación de los programas que hacen falta (Go, uv, ffmpeg) en macOS.
#
# No depende de Homebrew: lo usa si está y funciona, pero si no, cae a los
# instaladores oficiales de cada herramienta, que se extraen dentro de la
# carpeta del usuario y no piden contraseña de administrador.
#
# Lo carga install.sh y también "Instalar en Mac.command".

# Rutas donde estas herramientas suelen quedar, estén o no en el PATH heredado.
ruta_extendida() {
  local extra=(
    "$HOME/.local/bin"
    "$HOME/.local/go/bin"
    "/opt/homebrew/bin"
    "/usr/local/bin"
  )
  local d
  for d in "${extra[@]}"; do
    [[ -d "$d" && ":$PATH:" != *":$d:"* ]] && PATH="$d:$PATH"
  done
  export PATH
}

tiene() { command -v "$1" >/dev/null 2>&1; }

# Carga el entorno de Homebrew aunque no esté en el PATH todavía. Pasa cuando
# Homebrew se acaba de instalar y la terminal no se ha reabierto.
cargar_brew() {
  tiene brew && return 0
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$b" ]]; then
      eval "$("$b" shellenv)" 2>/dev/null
      return 0
    fi
  done
  return 1
}

# Intenta con Homebrew. Devuelve 1 si no está o si falla, para poder caer al
# método oficial sin dar el paso por perdido.
_probar_brew() {
  local paquete="$1"
  cargar_brew || return 1
  brew install "$paquete" >/dev/null 2>&1 || return 1
  ruta_extendida
  return 0
}

# ------------------------------------------------------------------ Go

instalar_go() {
  ruta_extendida
  tiene go && return 0

  _probar_brew go && { tiene go && return 0; }

  # Tarball oficial de go.dev, extraído en la carpeta del usuario.
  local arch tarball url destino="$HOME/.local"
  case "$(uname -m)" in
    arm64) arch="arm64" ;;
    *)     arch="amd64" ;;
  esac

  tarball="$(curl -s "https://go.dev/dl/?mode=json" 2>/dev/null | \
    python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for f in d[0]['files']:
    if f['os']=='darwin' and f['arch']=='$arch' and f['kind']=='archive':
        print(f['filename']); break
" 2>/dev/null)"

  [[ -z "$tarball" ]] && return 1
  url="https://go.dev/dl/$tarball"

  mkdir -p "$destino"
  rm -rf "$destino/go"
  curl -fsSL "$url" -o "$destino/go.tar.gz" || return 1
  tar -xzf "$destino/go.tar.gz" -C "$destino" || { rm -f "$destino/go.tar.gz"; return 1; }
  rm -f "$destino/go.tar.gz"

  ruta_extendida
  tiene go
}

# ------------------------------------------------------------------ uv

instalar_uv() {
  ruta_extendida
  tiene uv && return 0

  _probar_brew uv && { tiene uv && return 0; }

  # Instalador oficial de Astral: deja uv en ~/.local/bin, sin contraseña.
  curl -LsSf https://astral.sh/uv/install.sh 2>/dev/null | sh >/dev/null 2>&1

  ruta_extendida
  tiene uv
}

# ------------------------------------------------------------------ git

# En macOS git viene con las Command Line Tools de Xcode. Instalarlas abre un
# diálogo del sistema que el usuario tiene que aceptar; no hay forma de hacerlo
# en silencio sin permisos de administrador.
instalar_git() {
  ruta_extendida
  tiene git && return 0

  # Si Xcode o las Command Line Tools ya están, git deberia aparecer.
  if xcode-select -p >/dev/null 2>&1; then
    tiene git && return 0
  fi

  printf '\033[33m  ! Falta git. Se va a abrir una ventana de macOS para instalarlo.\033[0m\n'
  printf '\033[33m  ! Dale a "Instalar" y espera a que termine (unos minutos).\033[0m\n'
  xcode-select --install >/dev/null 2>&1

  # Esperar a que aparezca, hasta 20 minutos.
  local i
  for i in $(seq 1 240); do
    if xcode-select -p >/dev/null 2>&1 && tiene git; then
      return 0
    fi
    sleep 5
  done

  ruta_extendida
  tiene git
}

# ------------------------------------------------------------------ Claude Code

instalar_claude() {
  ruta_extendida
  tiene claude && return 0

  # Instalador oficial de Anthropic: deja claude en ~/.local/bin,
  # se actualiza solo, y no necesita Homebrew ni npm.
  curl -fsSL https://claude.ai/install.sh 2>/dev/null | bash >/dev/null 2>&1

  ruta_extendida
  tiene claude
}

# ------------------------------------------------------------------ Claude Desktop

# La app de escritorio. Distinta de Claude Code: una es ventana, la otra terminal.
tiene_claude_desktop() {
  [[ -d "/Applications/Claude.app" || -d "$HOME/Applications/Claude.app" ]]
}

# Devuelve 0 si quedó instalada, 1 si no se pudo, 2 si hace falta Homebrew
# y el usuario todavía no lo autorizó.
instalar_claude_desktop() {
  tiene_claude_desktop && return 0

  # Anthropic sirve el DMG detrás de Cloudflare, que bloquea las descargas por
  # terminal. El camino soportado es el cask oficial de Homebrew, que copia la
  # app a /Applications sin pedir contraseña de administrador.
  if cargar_brew; then
    brew install --cask claude >/dev/null 2>&1
    tiene_claude_desktop && return 0
    return 1
  fi
  return 2
}

# Instala Homebrew. A diferencia de todo lo demás, esto SÍ pide la contraseña
# del Mac, porque crea carpetas fuera del home del usuario.
instalar_brew() {
  cargar_brew && return 0
  if : < /dev/tty 2>/dev/null; then
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < /dev/tty
  else
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  cargar_brew
}

# ------------------------------------------------------------------ ffmpeg

# ffmpeg solo hace falta para enviar notas de voz. Si no se puede instalar,
# no es motivo para abortar: todo lo demas funciona igual.
instalar_ffmpeg() {
  ruta_extendida
  tiene ffmpeg && return 0
  _probar_brew ffmpeg && { tiene ffmpeg && return 0; }
  return 1
}

# ------------------------------------------------------------------ PATH persistente

# Deja las rutas en el perfil del shell para que sigan disponibles después.
persistir_ruta() {
  local rc="$HOME/.zshrc"
  [[ "${SHELL:-}" == *bash* ]] && rc="$HOME/.bash_profile"
  local linea='export PATH="$HOME/.local/bin:$HOME/.local/go/bin:$PATH"'
  grep -qsF '.local/go/bin' "$rc" || echo "$linea" >> "$rc"
}
