#!/bin/bash
# Arranque de una línea para Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/prcontreras23/whatsapp-para-claude/main/instalar.sh | bash
#
# Existe para esquivar Gatekeeper. Un archivo descargado con el navegador queda
# marcado como "de internet" (com.apple.quarantine), y macOS se niega a
# ejecutarlo con doble clic si no está firmado con un Developer ID de Apple.
# Lo que baja curl no lleva esa marca, así que corre sin trabas.

set -uo pipefail

REPO="prcontreras23/whatsapp-para-claude"
FUENTE="$HOME/whatsapp-para-claude-fuente"

rojo()  { printf '\033[31m%s\033[0m\n' "$*"; }
verde() { printf '\033[32m%s\033[0m\n' "$*"; }
gris()  { printf '\033[90m%s\033[0m\n' "$*"; }

morir() { echo; rojo "  ✗ $*"; echo; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || morir "Este arranque es para Mac."

echo
printf '\033[1m%s\033[0m\n' "Bajando WhatsApp para Claude..."
echo

rm -rf "$FUENTE"
mkdir -p "$FUENTE"

if ! curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" \
     | tar -xz -C "$FUENTE" --strip-components=1; then
  morir "No se pudo bajar. Revisa que tengas internet e inténtalo otra vez."
fi

chmod +x "$FUENTE/Instalar en Mac.command" "$FUENTE/wactl" "$FUENTE/install.sh" 2>/dev/null
verde "  ✓ listo"
gris  "  archivos en $FUENTE"

# El instalador muestra diálogos del sistema; se le devuelve la terminal como
# entrada, porque este script llega por una tubería y stdin viene ocupado.
# Si no hay terminal (por ejemplo, corriendo dentro de otro proceso), se ejecuta
# igual en vez de fallar.
if : < /dev/tty 2>/dev/null; then
  exec "$FUENTE/Instalar en Mac.command" < /dev/tty
else
  exec "$FUENTE/Instalar en Mac.command"
fi
