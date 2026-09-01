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

## Qué necesitas

- Una Mac o una PC con Windows 10/11
- Tu teléfono con WhatsApp, a mano
- Claude Code instalado
- Unos 15 minutos, casi todos de espera

No necesitas saber programar. Los programas que hagan falta los instala solo.

---

## Instalar en Mac

Abre la aplicación **Terminal** y pega esto:

```bash
git clone https://github.com/prcontreras23/whatsapp-para-claude.git
cd whatsapp-para-claude
./install.sh
```

Cuando termine, te va a decir exactamente qué escribir para vincular tu teléfono.

---

## Instalar en Windows

Abre **PowerShell** (búscalo en el menú de inicio) y pega esto:

```powershell
git clone https://github.com/prcontreras23/whatsapp-para-claude.git
cd whatsapp-para-claude
.\install.ps1
```

Si te dice que no reconoce `git`, descarga el proyecto como ZIP desde GitHub (botón verde **Code** → **Download ZIP**), descomprímelo, y abre PowerShell dentro de esa carpeta.

Si te dice que no puede ejecutar scripts, corre esto primero:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

> **Nota**: la primera vez, el instalador puede pedirte que cierres PowerShell y abras una ventana nueva. Es normal — Windows necesita eso para reconocer los programas que acaba de instalar. Vuelve a correr `.\install.ps1` y sigue.

---

## Vincular tu teléfono

Al terminar la instalación te va a salir un comando para correr. Al hacerlo aparece un **código QR** en la pantalla.

En tu teléfono:

**WhatsApp → Ajustes → Dispositivos vinculados → Vincular un dispositivo**

Escanea el código. Después vas a ver mucho texto moviéndose: está bajando tu historial. **Espera a que se calme** (unos minutos si tienes muchos chats) y presiona `Ctrl+C`.

Ya está. Ahora corre los tres comandos que te indicó el instalador, reinicia Claude Code, y pruébalo pidiéndole que te muestre tus últimos chats.

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

Sí, puedes tener varias a la vez — por ejemplo la personal y la del trabajo, cada una con su número:

```bash
./install.sh trabajo
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

### Lo que Claude puede hacer

`search_contacts` · `list_messages` · `list_chats` · `get_chat` · `get_direct_chat_by_contact` · `get_contact_chats` · `get_last_interaction` · `get_message_context` · `send_message` · `send_file` · `send_audio_message` · `download_media`

---

## Créditos y licencia

Basado en [lharries/whatsapp-mcp](https://github.com/lharries/whatsapp-mcp), con cambios propios: actualización a la versión nueva de la librería `whatsmeow`, arreglo de la descarga de multimedia, soporte para varias cuentas, cambio a un SQLite sin dependencias de C, un endpoint para marcar mensajes como leídos, y los instaladores de Mac y Windows.

Licencia MIT, igual que el original.
