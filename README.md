# WhatsApp para Claude

Conecta tu WhatsApp con Claude Code, para que puedas pedirle cosas como *"búscame lo que me escribió Juan la semana pasada"* o *"mándale este mensaje al grupo de pastores"*.

Funciona en **Mac** y en **Windows**.

---

## Antes de instalar, lee esto

Esto le da a Claude acceso a **todo tu WhatsApp**: tus chats personales, tus grupos, tus fotos, todo. No solo lo del trabajo.

Vale la pena que sepas cómo funciona:

- **Tus mensajes se quedan en tu computadora.** Se guardan en un archivo tuyo, en tu equipo. No se suben a ningún servidor.
- **Lo que sí sale** es lo que tú le pidas a Claude en cada conversación. Si le pides que te resuma un chat, ese chat va a Claude para poder resumirlo. Igual que cuando le pegas un texto.
- **Puede enviar mensajes en tu nombre.** Esa es justamente la gracia, pero significa que conviene revisar lo que Claude escribe antes de que lo mande.
- **Se desconecta cuando quieras**, desde tu propio teléfono: WhatsApp → Ajustes → Dispositivos vinculados → y lo quitas de la lista.

Si el equipo comparte una computadora, mejor no lo instalen ahí: cada quien en la suya.

---

## Antes: ¿tu computadora está lista?

Si es una máquina nueva, o no sabes qué tiene instalado, corre primero la revisión. **Audita la máquina, te dice qué falta y qué está desactualizado, y solo entonces te pregunta si lo arregla.** No toca nada sin tu confirmación.

**Mac** — en la app Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/prcontreras23/whatsapp-para-claude/main/revisar-mac.sh | bash
```

**Windows** — en PowerShell:

```powershell
irm https://raw.githubusercontent.com/prcontreras23/whatsapp-para-claude/main/revisar-windows.ps1 | iex
```

Revisa el sistema (versión, memoria, disco), git, Claude Code, y los tres programas del puente de WhatsApp. Instala lo que falte y actualiza lo que esté viejo — **sin Homebrew, sin winget y sin contraseña de administrador**.

> Si solo quieres Claude Code y nada más, el instalador oficial de Anthropic basta:
> `curl -fsSL https://claude.ai/install.sh | bash` en Mac, o `irm https://claude.ai/install.ps1 | iex` en Windows.

---

## Qué necesitas

- Una Mac o una PC con Windows 10/11
- Tu teléfono con WhatsApp, a mano
- Claude Code instalado
- Unos 15 minutos, casi todos de espera

No necesitas saber programar, ni tener nada instalado de antemano. El instalador se encarga de los tres programas que hacen falta (Go, uv y ffmpeg): usa Homebrew o winget si los tienes, y si no, los baja de sus sitios oficiales y los deja en tu carpeta de usuario, **sin pedirte contraseña de administrador**.

> ffmpeg es el único opcional: solo hace falta para enviar notas de voz. Si no se puede instalar, el resto funciona igual y el instalador te lo avisa en vez de abortar.

---

## Instalar

**No hace falta escribir ningún comando.** Descarga el proyecto y haz doble clic.

### 1. Descarga el proyecto

Entra a [la página del proyecto](https://github.com/prcontreras23/whatsapp-para-claude), dale al botón verde **Code** → **Download ZIP**, y descomprime el archivo.

### 2. Haz doble clic

| Si tienes | Doble clic en |
|---|---|
| **Mac** | `Instalar en Mac.command` |
| **Windows** | `Instalar en Windows.bat` |

> **En Mac el doble clic puede no hacer nada.** No es un fallo tuyo: macOS marca todo lo que baja del navegador y se niega a ejecutarlo si no está firmado con un Developer ID de Apple (de pago). Tienes dos salidas:
>
> **La fácil** — clic derecho sobre `Instalar en Mac.command` → **Abrir** → confirma. Solo la primera vez.
>
> **La que nunca falla** — abre la app **Terminal** (Cmd+Espacio, escribe "terminal", Enter), pega esta línea y dale Enter:
>
> ```bash
> curl -fsSL https://raw.githubusercontent.com/prcontreras23/whatsapp-para-claude/main/instalar.sh | bash
> ```
>
> Eso baja y arranca todo solo, sin descargar el ZIP ni pelear con macOS. Lo que baja así no lleva la marca que bloquea Gatekeeper.

El instalador hace todo solo: revisa qué programas faltan, los instala, prepara todo, y te va avisando en pantalla. Toma unos 15 minutos, casi todos de espera.

En el momento indicado te va a **abrir un código QR en la pantalla**. Ahí sacas tu teléfono:

**WhatsApp → Ajustes → Dispositivos vinculados → Vincular un dispositivo**

Escaneas, y el instalador se encarga del resto. Al terminar solo tienes que cerrar Claude Code y abrirlo de nuevo.

> **En Windows**, la primera vez puede pedirte cerrar la ventana y volver a hacer doble clic. Es normal: Windows necesita eso para reconocer los programas recién instalados.

> Si prefieres la terminal, `install.sh` (Mac) y `install.ps1` (Windows) hacen lo mismo desde la línea de comandos.

### Cosas que conviene saber

- WhatsApp permite **4 dispositivos vinculados** a la vez. Si ya llegaste al tope, quita alguno primero.
- La conexión **se vence a los ~20 días** sin usarse. Si pasa, repites el paso del QR y ya.
- El teléfono **no necesita quedarse conectado**, pero sí debe encender de vez en cuando.

---

## Usarlo día a día

Después de instalar puedes escribir `wactl` en la terminal (en Windows, `wactl.ps1`):

| Comando | Qué hace |
|---|---|
| `wactl list` | ver tus cuentas y si están funcionando |
| `wactl start principal` | encender |
| `wactl stop principal` | apagar |
| `wactl status principal` | ver el detalle |
| `wactl logs principal` | ver qué pasó, si algo falla |
| `wactl qr principal` | volver a vincular si se venció |

En Mac, para que el comando corto funcione, abre una terminal nueva después de instalar.

---

## ¿Varias cuentas de WhatsApp?

Sí, puedes tener varias a la vez — por ejemplo la personal y la del trabajo, cada una con su número. Para eso sí hace falta la terminal:

```bash
~/whatsapp-para-claude/wactl new trabajo
~/whatsapp-para-claude/wactl qr trabajo
~/whatsapp-para-claude/wactl start trabajo
~/whatsapp-para-claude/wactl autostart trabajo
~/whatsapp-para-claude/wactl mcp trabajo
```

Cada cuenta queda por su lado: su propio historial, su propia conexión. En Claude aparecen separadas (`whatsapp-principal`, `whatsapp-trabajo`), así que le puedes decir por cuál mandar cada cosa.

---

## Si algo no funciona

**«No aparecen las herramientas en Claude»**
Revisa que esté encendido con `wactl list`. Si dice `activo`, reinicia Claude Code.

**«Dice que no arrancó»**
Corre `wactl logs principal` y mira las últimas líneas. Casi siempre es que se venció la conexión — repite el paso del QR.

**«Sale un error de TLS o de conexión»**
Es cosa de internet, no del programa. Pasa cuando se reinicia varias veces seguidas y WhatsApp frena las reconexiones. Espera un minuto y `wactl restart principal`.

**«El código QR se ve como cuadritos raros» (Windows)**
Usa **Windows Terminal** en vez de la ventana negra clásica. Ahí se ve bien.

**«Quiero desinstalarlo»**
`wactl remove principal` borra la cuenta y su historial. Después quita el dispositivo desde tu teléfono, en Dispositivos vinculados.

---

## Cómo está hecho

Dos piezas:

- **El puente** (`whatsapp-bridge/`) — un programa en Go que se conecta a WhatsApp igual que WhatsApp Web, guarda tus mensajes en una base de datos local y ofrece una pequeña API en tu propia computadora.
- **El servidor MCP** (`whatsapp-mcp-server/`) — un programa en Python que Claude Code arranca solo, lee esa base y usa la API para enviar.

Ambos están hechos para correr **varias cuentas a la vez**: cada una con su carpeta de datos y su puerto, configurados con variables de entorno (`WHATSAPP_STORE_DIR`, `WHATSAPP_BRIDGE_PORT`, `WHATSAPP_API_BASE_URL`, `WHATSAPP_MESSAGES_DB`, `WHATSAPP_MCP_NAME`). El gestor `wactl` se encarga de eso; no hay que tocarlas a mano.

La base de datos usa un SQLite escrito en Go puro, así que **no hace falta ningún compilador de C** — ni en Mac ni en Windows. Eso es lo que permite que el instalador sea un solo comando.

Los requisitos se resuelven en `lib-requisitos.sh` (Mac) y `lib-requisitos.ps1` (Windows). Ninguno depende de un gestor de paquetes: prueban Homebrew o winget primero, y si no están o fallan, caen a los instaladores oficiales de Go y uv, que se extraen en `~/.local` sin permisos de administrador.

### Lo que Claude puede hacer

`search_contacts` · `list_messages` · `list_chats` · `get_chat` · `get_direct_chat_by_contact` · `get_contact_chats` · `get_last_interaction` · `get_message_context` · `send_message` · `send_file` · `send_audio_message` · `download_media`

---

## Créditos y licencia

Basado en [lharries/whatsapp-mcp](https://github.com/lharries/whatsapp-mcp), con cambios propios: actualización a la versión nueva de la librería `whatsmeow`, arreglo de la descarga de multimedia, soporte para varias cuentas, cambio a un SQLite sin dependencias de C, un endpoint para marcar mensajes como leídos, y los instaladores de Mac y Windows.

Licencia MIT, igual que el original.
