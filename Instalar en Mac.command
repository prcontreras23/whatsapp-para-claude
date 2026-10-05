#!/bin/bash
# Instalador de doble clic para Mac.
#
# La persona no escribe ni un comando: hace doble clic, responde dos diálogos,
# vincula su teléfono (con un código QR o con su número), y listo.

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

  # Dos formas: escribir en el teléfono un código de 8 letras (con el número)
  # o escanear un QR. La del número no depende de la cámara.
  FORMA="$(osascript -e 'button returned of (display dialog "¿Cómo quieres vincular tu WhatsApp?

Con mi número: te doy un código de 8 letras y lo escribes en el teléfono.

Código QR: lo escaneas con la cámara del teléfono." with title "Vincular WhatsApp" buttons {"Cancelar", "Código QR", "Con mi número"} default button 3)' 2>/dev/null)"
  [[ -z "$FORMA" || "$FORMA" == "Cancelar" ]] && { echo "Instalación cancelada."; exit 0; }

  TELEFONO=""
  if [[ "$FORMA" == "Con mi número" ]]; then
    for _ in 1 2 3; do
      ESCRITO="$(osascript -e 'text returned of (display dialog "Escribe tu número de WhatsApp.

Ejemplo: 809 555 1234

Si no es de República Dominicana, ponlo con el código de país." with title "Tu número de WhatsApp" default answer "")' 2>/dev/null)" || { echo "Instalación cancelada."; exit 0; }
      DIGITOS="$(printf '%s' "$ESCRITO" | tr -cd '0-9')"
      # Números dominicanos de 10 dígitos: se les agrega el 1 del país.
      [[ ${#DIGITOS} -eq 10 && "$DIGITOS" =~ ^(809|829|849) ]] && DIGITOS="1$DIGITOS"
      if [[ ${#DIGITOS} -ge 11 && ${#DIGITOS} -le 15 ]]; then TELEFONO="$DIGITOS"; break; fi
      avisar "Número no válido" "No reconozco '$ESCRITO' como número de teléfono. Inténtalo otra vez."
    done
    [[ -n "$TELEFONO" ]] || morir "No se pudo leer el número de teléfono."
  fi

  # Un intento anterior pudo dejar un puente de esta cuenta corriendo; dos a la
  # vez se pelean la sesión y WhatsApp desconecta a uno.
  "$WACTL" stop "$INSTANCIA" >/dev/null 2>&1

  rm -f "$WHATSAPP_STORE_DIR/qr.png" "$WHATSAPP_STORE_DIR/codigo.txt" "$WHATSAPP_STORE_DIR/codigo-error.txt"
  mkdir -p "$WHATSAPP_STORE_DIR"
  LOG="$INSTANCES_DIR/$INSTANCIA/bridge.log"
  mkdir -p "$(dirname "$LOG")"

  if [[ -n "$TELEFONO" ]]; then EXTRA_ENV="WHATSAPP_PAIR_PHONE=$TELEFONO"; else EXTRA_ENV="WHATSAPP_QR_OPEN=1"; fi
  cd "$DESTINO/whatsapp-bridge" || morir "No encuentro el programa."
  env WHATSAPP_STORE_DIR="$WHATSAPP_STORE_DIR" \
      WHATSAPP_BRIDGE_PORT="$WHATSAPP_BRIDGE_PORT" \
      "$EXTRA_ENV" \
      nohup ./whatsapp-bridge >> "$LOG" 2>&1 &
  PUENTE_PID=$!
  cd "$REPO_DIR" || true

  vivo() { kill -0 "$PUENTE_PID" 2>/dev/null; }

  if [[ -n "$TELEFONO" ]]; then
    info "pidiendo el código a WhatsApp..."
    for _ in $(seq 1 40); do
      [[ -f "$WHATSAPP_STORE_DIR/codigo.txt" || -f "$WHATSAPP_STORE_DIR/codigo-error.txt" ]] && break
      vivo || break
      sleep 1
    done
    if [[ ! -f "$WHATSAPP_STORE_DIR/codigo.txt" ]]; then
      DETALLE="$(cat "$WHATSAPP_STORE_DIR/codigo-error.txt" 2>/dev/null || tail -3 "$LOG")"
      kill "$PUENTE_PID" 2>/dev/null
      morir "WhatsApp no dio el código para el número +$TELEFONO. Revisa que el número esté bien y que tengas internet, o vuelve a correr el instalador y elige el código QR. Detalle: $DETALLE"
    fi
    CODIGO="$(tr -d '[:space:]' < "$WHATSAPP_STORE_DIR/codigo.txt")"
    echo
    printf '\033[1;33m      CÓDIGO:  %s\033[0m\n' "$CODIGO"
    echo
    dialogo "Escribe este código en tu teléfono" "Tu código es:

          $CODIGO

En tu teléfono (+$TELEFONO):

1. Abre WhatsApp
2. Ve a Ajustes → Dispositivos vinculados
3. Toca 'Vincular un dispositivo'
4. Abajo, toca 'Vincular con el número de teléfono'
5. Escribe el código

Puede que te llegue una notificación de WhatsApp: si la tocas, te lleva directo a donde se escribe el código.

El código vence en unos 2 minutos. Cuando termines, dale a Continuar aquí."
  else
    info "generando el código QR..."
    for _ in $(seq 1 40); do
      [[ -f "$WHATSAPP_STORE_DIR/qr.png" ]] && break
      vivo || break
      sleep 1
    done
    if [[ ! -f "$WHATSAPP_STORE_DIR/qr.png" ]]; then
      kill "$PUENTE_PID" 2>/dev/null
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
  fi

  # Se espera la conexión real (/api/status), no solo que el puerto conteste.
  # Se pide dos veces seguidas: justo después de vincular, WhatsApp corta la
  # conexión una vez y el puente se reconecta.
  info "esperando la conexión..."
  CONECTADO=false
  SEGUIDAS=0
  for _ in $(seq 1 75); do
    vivo || break
    if curl -s -m 2 "http://localhost:$WHATSAPP_BRIDGE_PORT/api/status" 2>/dev/null | grep -q '"connected":true,"logged_in":true'; then
      SEGUIDAS=$((SEGUIDAS + 1))
    else
      SEGUIDAS=0
    fi
    [[ $SEGUIDAS -ge 2 ]] && { CONECTADO=true; break; }
    sleep 2
  done

  osascript -e 'tell application "Preview" to close (every window whose name contains "qr")' >/dev/null 2>&1

  if ! $CONECTADO; then
    kill "$PUENTE_PID" 2>/dev/null
    morir "No se completó la conexión. Si WhatsApp te dijo 'inténtalo más tarde', espera unos 20 minutos y vuelve a hacer doble clic en el instalador."
  fi
  ok "conectado"
  rm -f "$WHATSAPP_STORE_DIR/qr.png" "$WHATSAPP_STORE_DIR/codigo.txt" "$WHATSAPP_STORE_DIR/codigo-error.txt"

  # Este puente sirvió para vincular; desde aquí lo maneja launchd. Se cierra
  # con SIGTERM (se desconecta limpio) para que no queden dos con la misma sesión.
  kill -TERM "$PUENTE_PID" 2>/dev/null
  for _ in $(seq 1 10); do vivo || break; sleep 1; done
  vivo && kill -9 "$PUENTE_PID" 2>/dev/null
fi

# ---------------------------------------------------------------- dejarlo listo

paso "8. Dejando todo funcionando"

# autostart carga el servicio en launchd y este lo enciende de una vez. No se
# llama a start antes: abriría un segundo puente con la misma sesión.
if "$WACTL" autostart "$INSTANCIA" >/dev/null 2>&1; then
  ok "arrancará solo al encender la Mac"
else
  "$WACTL" start "$INSTANCIA" >/dev/null 2>&1
  warn "no pude dejarlo arrancando solo al encender"
fi
CONECTADO=false
for _ in $(seq 1 30); do
  if curl -s -m 2 "http://localhost:$WHATSAPP_BRIDGE_PORT/api/status" 2>/dev/null | grep -q '"connected":true'; then
    CONECTADO=true; break
  fi
  sleep 2
done
if $CONECTADO; then ok "WhatsApp conectado y funcionando"
else warn "el puente no quedó conectado todavía; revísalo con:  $WACTL status $INSTANCIA"; fi

if command -v claude >/dev/null 2>&1; then
  if "$WACTL" mcp "$INSTANCIA" >/dev/null 2>&1 && claude mcp get "whatsapp-$INSTANCIA" < /dev/null >/dev/null 2>&1; then
    ok "conectado con Claude"
    MCP_OK=true
  else
    info "no se pudo registrar en Claude Code; corre después:  wactl mcp $INSTANCIA"
    MCP_OK=false
  fi
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
