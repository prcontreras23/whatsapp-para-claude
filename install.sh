#!/bin/bash
# Instalador de WhatsApp para Claude — macOS
#
# Deja tu WhatsApp conectado a Claude Code. Se puede correr varias veces sin
# problema: lo que ya está hecho se salta.
#
#   ./install.sh              instala y usa el nombre 'principal'
#   ./install.sh trabajo      instala una cuenta con el nombre 'trabajo'

set -uo pipefail

INSTANCIA="${1:-principal}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTINO="$HOME/whatsapp-para-claude"
INSTANCES_DIR="$HOME/.whatsapp-para-claude"

# ---------------------------------------------------------------- presentación

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
info() { printf '\033[90m  · %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
err()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; }

paso() { echo; bold "$*"; }

morir() { echo; err "$*"; echo; exit 1; }

echo
bold "═══ WhatsApp para Claude ═══"
echo
info "Esto conecta tu WhatsApp con Claude Code."
info "Todo queda en esta computadora: tus mensajes no se suben a ningún lado."
echo

# ---------------------------------------------------------------- comprobaciones

[[ "$(uname -s)" == "Darwin" ]] || morir "Este instalador es para Mac. En Windows usa install.ps1"

paso "1. Revisando lo que hace falta"

# shellcheck source=lib-requisitos.sh
source "$REPO_DIR/lib-requisitos.sh" || morir "Falta el archivo lib-requisitos.sh"
ruta_extendida

for prog in go uv ffmpeg; do
  tiene "$prog" && ok "$prog" || info "falta $prog"
done

paso "2. Instalando lo que falta"

if tiene go; then :; else
  info "instalando Go (puede tardar unos minutos)..."
  instalar_go && ok "Go" || morir "No pude instalar Go.
Instálalo a mano desde https://go.dev/dl/ y vuelve a correr este instalador."
fi

if tiene uv; then :; else
  info "instalando uv..."
  instalar_uv && ok "uv" || morir "No pude instalar uv.
Instálalo a mano con:  curl -LsSf https://astral.sh/uv/install.sh | sh
y vuelve a correr este instalador."
fi

if tiene ffmpeg; then :; else
  info "instalando ffmpeg..."
  if instalar_ffmpeg; then
    ok "ffmpeg"
  else
    warn "No pude instalar ffmpeg. Todo va a funcionar menos enviar notas de voz."
    warn "Si las quieres, instálalo después con: brew install ffmpeg"
  fi
fi

persistir_ruta
tiene claude || warn "No encuentro el comando 'claude'. Al final tendrás que registrar el MCP a mano."

# ---------------------------------------------------------------- copiar

paso "3. Copiando los archivos a $DESTINO"

mkdir -p "$DESTINO"
if [[ "$REPO_DIR" != "$DESTINO" ]]; then
  cp -R "$REPO_DIR/whatsapp-bridge" "$REPO_DIR/whatsapp-mcp-server" "$DESTINO/" 2>/dev/null
  cp "$REPO_DIR/wactl" "$DESTINO/wactl"
  cp "$REPO_DIR/lib-requisitos.sh" "$DESTINO/" 2>/dev/null
  [[ -f "$REPO_DIR/LICENSE" ]] && cp "$REPO_DIR/LICENSE" "$DESTINO/"
fi
chmod +x "$DESTINO/wactl"
ok "copiados"

# ---------------------------------------------------------------- compilar

paso "4. Compilando el puente de WhatsApp"
info "esto tarda un par de minutos la primera vez"

cd "$DESTINO/whatsapp-bridge" || morir "no encuentro la carpeta del puente"
if ! go mod download 2>&1 | tail -3; then
  morir "No se pudieron bajar las librerías. ¿Hay internet?"
fi
if CGO_ENABLED=0 go build -o whatsapp-bridge . 2>&1 | tail -10; then
  ok "compilado"
else
  morir "Falló la compilación."
fi
[[ -x "$DESTINO/whatsapp-bridge/whatsapp-bridge" ]] || morir "no se generó el programa"

# ---------------------------------------------------------------- python

paso "5. Preparando el servidor que habla con Claude"

cd "$DESTINO/whatsapp-mcp-server" || morir "no encuentro la carpeta del servidor"
if uv sync 2>&1 | tail -5; then
  ok "listo"
else
  morir "Falló 'uv sync'."
fi

# ---------------------------------------------------------------- instancia

paso "6. Creando tu cuenta '$INSTANCIA'"

mkdir -p "$INSTANCES_DIR"
export WACTL_HOME="$DESTINO"
WACTL="$DESTINO/wactl"

if [[ -f "$INSTANCES_DIR/$INSTANCIA.env" ]]; then
  info "'$INSTANCIA' ya existía, la reutilizo"
else
  "$WACTL" new "$INSTANCIA" || morir "no se pudo crear la cuenta"
fi

# ---------------------------------------------------------------- atajo

paso "7. Dejando el comando 'wactl' a mano"

SHELL_RC="$HOME/.zshrc"
[[ "$SHELL" == *bash* ]] && SHELL_RC="$HOME/.bash_profile"
LINEA="alias wactl=\"$DESTINO/wactl\""
if grep -qs "alias wactl=" "$SHELL_RC"; then
  info "ya estaba"
else
  echo "$LINEA" >> "$SHELL_RC"
  ok "agregado a $(basename "$SHELL_RC")"
fi

# ---------------------------------------------------------------- final

STORE="$INSTANCES_DIR/$INSTANCIA/store"
YA_VINCULADO=false
[[ -f "$STORE/whatsapp.db" ]] && YA_VINCULADO=true

echo
bold "═══ Instalación lista ═══"
echo

if $YA_VINCULADO; then
  info "Tu WhatsApp ya estaba vinculado."
  echo
  echo "  Para dejarlo corriendo:"
  echo "     $DESTINO/wactl start $INSTANCIA"
else
  bold "Falta un paso: vincular tu teléfono."
  echo
  echo "  Corre esto:"
  echo
  echo "     $DESTINO/wactl qr $INSTANCIA"
  echo
  echo "  Va a salir un código QR. En tu teléfono abre WhatsApp y ve a:"
  echo "     Ajustes → Dispositivos vinculados → Vincular un dispositivo"
  echo
  echo "  Escanea el código y espera a que termine de bajar tus mensajes"
  echo "  (unos minutos). Cuando el texto deje de moverse, presiona Ctrl+C."
  echo
  echo "  Después, para dejarlo funcionando:"
  echo
  echo "     $DESTINO/wactl start $INSTANCIA"
  echo "     $DESTINO/wactl autostart $INSTANCIA"
  echo "     $DESTINO/wactl mcp $INSTANCIA"
  echo
  echo "  Y reinicia Claude Code."
fi
echo
info "Abre una terminal nueva y podrás escribir solo 'wactl' en vez de la ruta larga."
echo
