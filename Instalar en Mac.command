#!/bin/bash
# Instalador de doble clic para Mac.
#
# La persona no escribe ni un comando: hace doble clic, responde dos diálogos,
# escanea un código QR que se le abre en pantalla, y listo.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
REPO_DIR="$(pwd)"
DESTINO="$HOME/whatsapp-para-claude"
INSTANCES_DIR="$HOME/.whatsapp-para-claude"
INSTANCIA="principal"

# ---------------------------------------------------------------- diálogos

dialogo() {  # título, mensaje
  osascript -e "display dialog \"$2\" with title \"$1\" buttons {\"Continuar\"} default button 1 giving up after 600" >/dev/null 2>&1
}

preguntar() {  # título, mensaje -> 0 si sigue, 1 si cancela
  osascript -e "display dialog \"$2\" with title \"$1\" buttons {\"Cancelar\", \"Instalar\"} default button 2" >/dev/null 2>&1
}

avisar() {  # título, mensaje
  osascript -e "display dialog \"$2\" with title \"$1\" buttons {\"Entendido\"} default button 1 with icon caution" >/dev/null 2>&1
}

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
info()  { printf '\033[90m  · %s\033[0m\n' "$*"; }
warn()  { printf '\033[33m  ! %s\033[0m\n' "$*"; }
paso()  { echo; bold "$*"; }

morir() {
  echo
  printf '\033[31m  ✗ %s\033[0m\n' "$*"
  avisar "No se pudo instalar" "$*"
  echo
  echo "Puedes cerrar esta ventana."
  exit 1
}

clear
cat <<'BANNER'

   WhatsApp para Claude
   ─────────────────────

   Vas a conectar tu WhatsApp con Claude.
   No tienes que escribir nada: sigue los avisos que aparezcan.

BANNER

# ---------------------------------------------------------------- consentimiento

if ! preguntar "WhatsApp para Claude" "Esto conecta tu WhatsApp con Claude, en esta computadora.

Antes de seguir, es importante que sepas:

• Claude va a poder leer TODO tu WhatsApp, no solo lo del trabajo.
• Tus mensajes se quedan en esta computadora. No se suben a ningún servidor.
• Claude va a poder enviar mensajes en tu nombre.
• Puedes desconectarlo cuando quieras, desde tu teléfono.

La instalación toma unos 15 minutos, casi todos de espera.
Vas a necesitar tu teléfono a mano.

¿Continuamos?"; then
  echo "Instalación cancelada."
  exit 0
fi

# ---------------------------------------------------------------- requisitos

paso "1. Revisando qué hace falta"

# shellcheck source=lib-requisitos.sh
source "$REPO_DIR/lib-requisitos.sh" || morir "Falta el archivo lib-requisitos.sh en esta carpeta."
ruta_extendida

for prog in go uv ffmpeg; do
  tiene "$prog" && ok "$prog" || info "falta $prog"
done

paso "2. Instalando lo que falta"

if ! tiene go || ! tiene uv; then
  info "esto puede tardar varios minutos, no cierres la ventana"
fi

if ! tiene go; then
  info "instalando Go..."
  instalar_go && ok "Go" || morir "No pude instalar Go automáticamente.

Descárgalo de https://go.dev/dl/ (la versión para Mac), instálalo, y vuelve a hacer doble clic aquí."
fi

if ! tiene uv; then
  info "instalando uv..."
  instalar_uv && ok "uv" || morir "No pude instalar uv automáticamente.

Abre la Terminal, pega esta línea, y vuelve a hacer doble clic aquí:

curl -LsSf https://astral.sh/uv/install.sh | sh"
fi

if ! tiene ffmpeg; then
  info "instalando ffmpeg..."
  if instalar_ffmpeg; then
    ok "ffmpeg"
  else
    warn "sin ffmpeg: todo funciona menos enviar notas de voz"
  fi
fi

persistir_ruta

# ---------------------------------------------------------------- copiar y compilar

paso "3. Copiando archivos"
mkdir -p "$DESTINO"
if [[ "$REPO_DIR" != "$DESTINO" ]]; then
  cp -R "$REPO_DIR/whatsapp-bridge" "$REPO_DIR/whatsapp-mcp-server" "$DESTINO/" 2>/dev/null
  cp "$REPO_DIR/wactl" "$DESTINO/wactl"
  cp "$REPO_DIR/lib-requisitos.sh" "$DESTINO/" 2>/dev/null
  [[ -f "$REPO_DIR/LICENSE" ]] && cp "$REPO_DIR/LICENSE" "$DESTINO/"
fi
chmod +x "$DESTINO/wactl"
ok "copiados"

paso "4. Preparando el programa"
info "la primera vez toma unos minutos, es normal"
cd "$DESTINO/whatsapp-bridge" || morir "No encuentro los archivos del programa."
go mod download 2>&1 | tail -3
CGO_ENABLED=0 go build -o whatsapp-bridge . 2>&1 | tail -5
[[ -x "$DESTINO/whatsapp-bridge/whatsapp-bridge" ]] || morir "No se pudo preparar el programa. Revisa que tengas internet."
ok "listo"

paso "5. Preparando la conexión con Claude"
cd "$DESTINO/whatsapp-mcp-server" || morir "No encuentro los archivos del servidor."
uv sync 2>&1 | tail -3 || morir "Falló la preparación del servidor."
ok "listo"

# ---------------------------------------------------------------- instancia

paso "6. Creando tu cuenta"
WACTL="$DESTINO/wactl"
mkdir -p "$INSTANCES_DIR"
if [[ ! -f "$INSTANCES_DIR/$INSTANCIA.env" ]]; then
  "$WACTL" new "$INSTANCIA" >/dev/null || morir "No se pudo crear la cuenta."
fi
# shellcheck disable=SC1090
source "$INSTANCES_DIR/$INSTANCIA.env"
ok "cuenta '$INSTANCIA' lista (puerto $WHATSAPP_BRIDGE_PORT)"

# ---------------------------------------------------------------- vincular

YA_VINCULADO=false
[[ -f "$WHATSAPP_STORE_DIR/whatsapp.db" ]] && \
  [[ -n "$(sqlite3 "$WHATSAPP_STORE_DIR/whatsapp.db" 'select jid from whatsmeow_device limit 1' 2>/dev/null)" ]] && \
  YA_VINCULADO=true

if $YA_VINCULADO; then
  paso "7. Tu WhatsApp ya estaba vinculado"
  ok "no hace falta escanear otra vez"
else
  paso "7. Vinculando tu teléfono"

  rm -f "$WHATSAPP_STORE_DIR/qr.png"
  mkdir -p "$WHATSAPP_STORE_DIR"
  LOG="$INSTANCES_DIR/$INSTANCIA/bridge.log"
  mkdir -p "$(dirname "$LOG")"

  ( cd "$DESTINO/whatsapp-bridge" && \
    WHATSAPP_STORE_DIR="$WHATSAPP_STORE_DIR" \
    WHATSAPP_BRIDGE_PORT="$WHATSAPP_BRIDGE_PORT" \
    WHATSAPP_QR_OPEN=1 \
    nohup ./whatsapp-bridge >> "$LOG" 2>&1 & )

  info "generando el código QR..."
  for _ in $(seq 1 40); do
    [[ -f "$WHATSAPP_STORE_DIR/qr.png" ]] && break
    sleep 1
  done

  if [[ ! -f "$WHATSAPP_STORE_DIR/qr.png" ]]; then
    morir "No se pudo generar el código QR. Revisa que tengas internet e inténtalo de nuevo."
  fi

  ok "código QR en pantalla"
  dialogo "Escanea el código" "Se abrió un código QR en tu pantalla.

En tu teléfono:

1. Abre WhatsApp
2. Ve a Ajustes → Dispositivos vinculados
3. Toca 'Vincular un dispositivo'
4. Escanea el código

Cuando termines, dale a Continuar aquí.

(Si el código se venció, ciérralo y vuelve a abrir el archivo qr.png que quedó en la carpeta.)"

  info "esperando la conexión y bajando tus mensajes..."
  CONECTADO=false
  for _ in $(seq 1 90); do
    if curl -s -m 2 -o /dev/null "http://localhost:$WHATSAPP_BRIDGE_PORT/api/" 2>/dev/null; then
      CONECTADO=true; break
    fi
    sleep 2
  done

  osascript -e 'tell application "Preview" to close (every window whose name contains "qr")' >/dev/null 2>&1

  if ! $CONECTADO; then
    morir "No se completó la conexión. Vuelve a hacer doble clic en el instalador para intentarlo otra vez."
  fi
  ok "conectado"
  rm -f "$WHATSAPP_STORE_DIR/qr.png"
fi

# ---------------------------------------------------------------- dejarlo listo

paso "8. Dejando todo funcionando"

"$WACTL" start "$INSTANCIA" >/dev/null 2>&1
"$WACTL" autostart "$INSTANCIA" >/dev/null 2>&1 && ok "arrancará solo al encender la Mac"

if command -v claude >/dev/null 2>&1; then
  "$WACTL" mcp "$INSTANCIA" >/dev/null 2>&1 && ok "conectado con Claude"
  MCP_OK=true
else
  info "no encontré Claude Code instalado"
  MCP_OK=false
fi

SHELL_RC="$HOME/.zshrc"
grep -qs "alias wactl=" "$SHELL_RC" || echo "alias wactl=\"$DESTINO/wactl\"" >> "$SHELL_RC"

# ---------------------------------------------------------------- final

NUMERO="$(sqlite3 "$WHATSAPP_STORE_DIR/whatsapp.db" 'select jid from whatsmeow_device limit 1' 2>/dev/null | cut -d: -f1 | cut -d@ -f1)"

echo
bold "═══ Listo ═══"
echo
[[ -n "$NUMERO" ]] && ok "WhatsApp conectado: +$NUMERO"

if $MCP_OK; then
  dialogo "¡Listo!" "Tu WhatsApp ya está conectado con Claude.

Último paso: cierra Claude Code y vuelve a abrirlo.

Después pruébalo pidiéndole algo como:
'muéstrame mis últimos chats de WhatsApp'"
else
  avisar "Casi listo" "Tu WhatsApp quedó conectado y funcionando.

Pero no encontré Claude Code en esta computadora. Instálalo y después vuelve a hacer doble clic en este instalador para terminar de conectarlo."
fi

echo
echo "Ya puedes cerrar esta ventana."
echo
