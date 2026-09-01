#!/bin/bash
# Audita una Mac y luego instala y actualiza lo que haga falta:
#
#   curl -fsSL https://raw.githubusercontent.com/prcontreras23/whatsapp-para-claude/main/revisar-mac.sh | bash
#
# Primero informa: qué tiene, qué falta, qué está desactualizado. Al final
# ofrece arreglarlo todo. Nada se toca sin que lo confirmes.

set -uo pipefail

REPO="prcontreras23/whatsapp-para-claude"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
verde() { printf '\033[32m%s\033[0m' "$*"; }
rojo()  { printf '\033[31m%s\033[0m' "$*"; }
ambar() { printf '\033[33m%s\033[0m' "$*"; }
gris()  { printf '\033[90m%s\033[0m\n' "$*"; }

morir() { echo; printf '\033[31m  ✗ %s\033[0m\n' "$*"; echo; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || morir "Esto es para Mac."

# Las funciones de instalación viven en lib-requisitos.sh. Si el script se está
# corriendo desde una copia del repo, se usa la de al lado; si llega por tubería
# (curl | bash), se descarga.
cargar_lib() {
  local propio
  # Con "curl | bash" no hay archivo de origen, así que BASH_SOURCE no existe:
  # el :- evita que set -u aborte por variable sin definir.
  local origen="${BASH_SOURCE[0]:-}"
  [[ -z "$origen" ]] && return 1
  propio="$(cd "$(dirname "$origen")" 2>/dev/null && pwd)/lib-requisitos.sh"
  if [[ -r "$propio" ]]; then
    # shellcheck disable=SC1090
    source "$propio" && declare -F tiene_claude_desktop >/dev/null 2>&1 && return 0
  fi
  local tmp; tmp="$(mktemp)"
  # cache-bust: el CDN de raw.githubusercontent sirve copias viejas unos minutos
  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/lib-requisitos.sh?t=$(date +%s)" -o "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; return 1; }
  # shellcheck disable=SC1090
  source "$tmp"; rm -f "$tmp"
  declare -F tiene_claude_desktop >/dev/null 2>&1
}

cargar_lib || morir "No se pudo cargar la revisión. ¿Hay internet?"
ruta_extendida

FALTAN=()
VIEJOS=()

# Compara dos versiones tipo 1.2.3. Devuelve 0 si $1 es menor que $2.
menor_que() {
  [[ "$1" == "$2" ]] && return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]
}

# ---------------------------------------------------------------- la máquina

echo
bold "═══ Revisión de esta Mac ═══"
echo

MACOS="$(sw_vers -productVersion)"
MACOS_MAYOR="${MACOS%%.*}"
CHIP="$(uname -m)"
RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
DISCO="$(df -h / | awk 'NR==2{print $4}')"

printf '  %-16s %s\n' "macOS"   "$MACOS"
printf '  %-16s %s\n' "Chip"    "$([[ "$CHIP" == "arm64" ]] && echo "Apple Silicon" || echo "Intel")"
printf '  %-16s %s GB\n' "Memoria" "$RAM_GB"
printf '  %-16s %s libres\n' "Disco" "$DISCO"

echo
PROBLEMA=0
if [[ "$MACOS_MAYOR" -lt 13 ]]; then
  printf '  '; rojo "✗"; printf ' macOS %s es muy viejo. Claude Code pide 13.0 o más nuevo.\n' "$MACOS"
  PROBLEMA=1
fi
if [[ "$RAM_GB" -lt 4 ]]; then
  printf '  '; rojo "✗"; printf ' Con %s GB va a ir lento. Se recomiendan 4 GB o más.\n' "$RAM_GB"
  PROBLEMA=1
fi
[[ $PROBLEMA -eq 0 ]] && { printf '  '; verde "✓"; echo " La máquina cumple los requisitos"; }

# ---------------------------------------------------------------- últimas versiones

gris ""
gris "  consultando las versiones más recientes..."

ULT_GO=""; ULT_UV=""
ULT_GO="$(curl -fsS --max-time 12 'https://go.dev/dl/?mode=json' 2>/dev/null \
  | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['version'].lstrip('go'))" 2>/dev/null)"
ULT_UV="$(curl -fsS --max-time 12 'https://api.github.com/repos/astral-sh/uv/releases/latest' 2>/dev/null \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null)"

# ---------------------------------------------------------------- programas

# nombre, comando, cómo sacar la versión, para qué sirve, última versión conocida
revisar() {
  local nombre="$1" cmd="$2" vercmd="$3" para="$4" ultima="${5:-}"
  printf '  %-16s ' "$nombre"
  if ! tiene "$cmd"; then
    rojo "✗"; printf ' falta — %s\n' "$para"
    FALTAN+=("$cmd")
    return
  fi
  local actual; actual="$(eval "$vercmd" 2>/dev/null | head -1)"
  if [[ -n "$ultima" && -n "$actual" ]] && menor_que "$actual" "$ultima"; then
    ambar "↑"; printf ' %s  →  hay %s\n' "$actual" "$ultima"
    VIEJOS+=("$cmd")
  else
    verde "✓"; printf ' %s\n' "${actual:-instalado}"
  fi
}

echo
bold "Para Claude Code"
revisar "git"         git    'git --version | awk "{print \$3}"' "Claude Code lo usa para ver tus cambios"
revisar "Claude Code" claude 'claude --version | awk "{print \$1}"' "es el programa principal"

printf '  %-16s ' "Claude Desktop"
if tiene_claude_desktop; then
  verde "✓"; printf ' instalada\n'
else
  rojo "✗"; printf ' falta — la app de ventana, para usar Claude sin la terminal\n'
  FALTAN+=("desktop")
fi

echo
bold "Para conectar WhatsApp (opcional)"
revisar "Go"     go     'go version | awk "{print \$3}" | sed "s/^go//"' "compila el puente de WhatsApp" "$ULT_GO"
revisar "uv"     uv     'uv --version | awk "{print \$2}"'               "corre el servidor de Claude"   "$ULT_UV"
revisar "ffmpeg" ffmpeg 'ffmpeg -version | awk "{print \$3}"'            "solo para notas de voz"

echo
bold "Sistema"
printf '  %-16s ' "Homebrew"
if tiene brew; then
  DESACT="$(brew outdated --quiet 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${DESACT:-0}" -gt 0 ]]; then
    ambar "↑"; printf ' %s paquete(s) por actualizar\n' "$DESACT"
  else
    verde "✓"; printf ' al día\n'
  fi
else
  ambar "○"; printf ' no está — y no hace falta, todo se instala sin él\n'
fi

printf '  %-16s ' "macOS"
ACT_MACOS="$(softwareupdate -l 2>&1 | grep -c '^\s*\*' || true)"
if [[ "${ACT_MACOS:-0}" -gt 0 ]]; then
  ambar "↑"; printf ' %s actualización(es) del sistema pendientes\n' "$ACT_MACOS"
  gris "                   (se instalan desde Ajustes del Sistema, no desde aquí)"
else
  verde "✓"; printf ' al día\n'
fi

# ---------------------------------------------------------------- veredicto

echo
if [[ ${#FALTAN[@]} -eq 0 && ${#VIEJOS[@]} -eq 0 ]]; then
  bold "═══ Todo en orden ═══"
  echo
  tiene claude && gris "  Para empezar, abre una terminal y escribe:  claude"
  echo
  exit 0
fi

bold "═══ Resumen ═══"
echo
if [[ ${#FALTAN[@]} -gt 0 ]]; then
  echo "  Falta instalar:"
  for f in "${FALTAN[@]}"; do
    case "$f" in
      git)    echo "    • git — viene con las Command Line Tools de Xcode" ;;
      claude)  echo "    • Claude Code — instalador oficial de Anthropic" ;;
      desktop) echo "    • Claude Desktop — la app oficial de ventana (350 MB)" ;;
      go)     echo "    • Go — solo si vas a conectar WhatsApp" ;;
      uv)     echo "    • uv — solo si vas a conectar WhatsApp" ;;
      ffmpeg) echo "    • ffmpeg — solo para notas de voz" ;;
    esac
  done
  echo
fi
if [[ ${#VIEJOS[@]} -gt 0 ]]; then
  echo "  Se puede actualizar:  ${VIEJOS[*]}"
  echo
fi
gris "  Nada de esto pide contraseña de administrador ni necesita Homebrew."
echo

# ---------------------------------------------------------------- arreglar

if ! : < /dev/tty 2>/dev/null; then
  bold "Para arreglarlo, corre esto en la Terminal:"
  echo
  echo "  curl -fsSL https://raw.githubusercontent.com/$REPO/main/revisar-mac.sh | bash"
  echo
  gris "  (así sí te puede preguntar antes de tocar nada)"
  echo
  exit 0
fi

printf '  ¿Instalo y actualizo todo eso? [s/N] '
read -r RESP < /dev/tty
case "${RESP:-n}" in
  s|S|si|Si|SI|y|Y) ;;
  *) echo; gris "  No se tocó nada."; echo; exit 0 ;;
esac

echo
for f in "${FALTAN[@]}"; do
  [[ -z "$f" ]] && continue
  printf '  instalando %-8s ' "$f"
  case "$f" in
    git)    instalar_git    && verde "✓" || rojo "✗" ;;
    claude) instalar_claude && verde "✓" || rojo "✗" ;;
    desktop)
      gris ""
      printf '    bajando la app oficial (unos 350 MB, tarda un rato)... '
      instalar_claude_desktop
      case $? in
        0) verde "✓" ;;
        3) rojo "✗ el archivo bajado no coincide con el original — no se instaló" ;;
        4) rojo "✗ la app no viene firmada por Anthropic — no se instaló" ;;
        *) rojo "✗ bájala a mano de https://claude.com/download" ;;
      esac ;;
    go)     instalar_go     && verde "✓" || rojo "✗" ;;
    uv)     instalar_uv     && verde "✓" || rojo "✗" ;;
    ffmpeg) instalar_ffmpeg && verde "✓" || ambar "○ (opcional, se sigue sin él)" ;;
  esac
  echo
done

for v in "${VIEJOS[@]}"; do
  printf '  actualizando %-8s ' "$v"
  case "$v" in
    claude) claude update >/dev/null 2>&1 && verde "✓" || ambar "○ (se actualiza solo en segundo plano)" ;;
    go)     rm -rf "$HOME/.local/go"; instalar_go && verde "✓" || rojo "✗" ;;
    uv)     uv self update >/dev/null 2>&1 || instalar_uv >/dev/null 2>&1; verde "✓" ;;
    *)      ambar "○" ;;
  esac
  echo
done

persistir_ruta

echo
bold "═══ Listo ═══"
echo
if tiene claude; then
  echo "  Abre una terminal NUEVA y escribe:  claude"
  echo "  Se abre el navegador para que inicies sesión."
  echo
  gris "  Necesitas cuenta Pro, Max, Team o Enterprise. La gratuita no incluye Claude Code."
else
  gris "  Claude Code no quedó instalado. Inténtalo a mano:"
  echo "     curl -fsSL https://claude.ai/install.sh | bash"
fi
echo
gris "  ¿Conectar tu WhatsApp también? Corre:"
echo "     curl -fsSL https://raw.githubusercontent.com/$REPO/main/instalar.sh | bash"
echo
