import sqlite3
from datetime import datetime
from dataclasses import dataclass
from typing import Optional, List, Tuple
import os.path
import requests
import json
import audio

# Configuración por instancia. Cada cuenta de WhatsApp corre su propio bridge
# en su puerto y con su propia base; estas variables apuntan a la que toque.
#
#   WHATSAPP_MESSAGES_DB   ruta a store/messages.db del bridge de esta instancia
#   WHATSAPP_API_BASE_URL  URL del API REST de ese bridge
#
# Sin variables definidas apunta a la instancia por defecto (puerto 8080).
_DEFAULT_DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'whatsapp-bridge', 'store', 'messages.db')

MESSAGES_DB_PATH = os.environ.get('WHATSAPP_MESSAGES_DB') or _DEFAULT_DB
WHATSAPP_API_BASE_URL = os.environ.get('WHATSAPP_API_BASE_URL') or "http://localhost:8080/api"


def _parse_fecha(valor):
    """Convierte a datetime lo que venga de la base.

    Los registros viejos estan en ISO ("2026-03-06 16:07:56-04:00"), pero un
    cambio de driver dejo algunos escritos con el formato de Go, que lleva el
    nombre de la zona al final ("2026-08-31 22:51:12 -0400 AST"). Se aceptan
    los dos para no perder esos mensajes.
    """
    if valor is None:
        return None
    if isinstance(valor, datetime):
        return valor
    texto = str(valor).strip()
    try:
        return datetime.fromisoformat(texto)
    except ValueError:
        pass
    partes = texto.split()
    # "2026-08-31 22:51:12 -0400 AST" -> fecha, hora, offset (se ignora el nombre)
    if len(partes) >= 3:
        try:
            return datetime.strptime(" ".join(partes[:3]), "%Y-%m-%d %H:%M:%S %z")
        except ValueError:
            pass
    if len(partes) >= 2:
        try:
            return datetime.strptime(" ".join(partes[:2]), "%Y-%m-%d %H:%M:%S")
        except ValueError:
            pass
    raise ValueError(f"No pude interpretar la fecha: {valor!r}")

@dataclass
class Message:
    timestamp: datetime
    sender: str
    content: str
    is_from_me: bool
    chat_jid: str
    id: str
    chat_name: Optional[str] = None
    media_type: Optional[str] = None
    # Mensaje al que este responde (cita de WhatsApp), si aplica
    quoted_id: Optional[str] = None
    quoted_sender: Optional[str] = None
    quoted_content: Optional[str] = None
    # Edición / borrado para todos / reacciones ("emoji sender, emoji sender")
    edited_at: Optional[str] = None
    deleted_at: Optional[str] = None
    reactions: Optional[str] = None

@dataclass
class Chat:
    jid: str
    name: Optional[str]
    last_message_time: Optional[datetime]
    last_message: Optional[str] = None
    last_sender: Optional[str] = None
    last_is_from_me: Optional[bool] = None

    @property
    def is_group(self) -> bool:
        """Determine if chat is a group based on JID pattern."""
        return self.jid.endswith("@g.us")

@dataclass
class Contact:
    phone_number: str
    name: Optional[str]
    jid: str

@dataclass
class MessageContext:
    message: Message
    before: List[Message]
    after: List[Message]

def _es_solo_numero(texto: str) -> bool:
    t = (texto or "").strip()
    return t.isdigit() and len(t) >= 8

def get_sender_name(sender_jid: str) -> str:
    """Nombre para mostrar de un remitente.

    `sender_jid` puede ser un JID completo o solo la parte de usuario, y esa
    parte puede ser un teléfono o un LID (el identificador que WhatsApp usa
    ahora en los grupos). Orden: libreta `contacts` que vuelca el bridge
    (cruza LID ↔ teléfono ↔ nombre), luego el nombre del chat directo si es un
    nombre de verdad, luego el teléfono si se conoce, y al final lo que llegó.
    """
    if not sender_jid:
        return sender_jid
    user = sender_jid.split('@')[0].split(':')[0]
    try:
        conn = sqlite3.connect(MESSAGES_DB_PATH)
        cursor = conn.cursor()

        cursor.execute("SELECT name, phone, lid FROM contacts WHERE user = ? LIMIT 1", (user,))
        row = cursor.fetchone()
        phone = None
        if row:
            name, phone, lid = row
            if name and not _es_solo_numero(name):
                return name
            # Sin nombre en la libreta: probar el chat directo por teléfono o por LID
            for cand in filter(None, {phone, lid}):
                cursor.execute("SELECT name FROM chats WHERE jid IN (?, ?) LIMIT 1",
                               (f"{cand}@s.whatsapp.net", f"{cand}@lid"))
                r = cursor.fetchone()
                if r and r[0] and not _es_solo_numero(r[0]):
                    return r[0]

        # Chat directo con ese mismo identificador (coincidencia exacta, nunca LIKE:
        # el LIKE cruzaba identificadores distintos y bautizaba a todos con el mismo número)
        cursor.execute("SELECT name FROM chats WHERE jid IN (?, ?) LIMIT 1",
                       (f"{user}@s.whatsapp.net", f"{user}@lid"))
        r = cursor.fetchone()
        if r and r[0] and not _es_solo_numero(r[0]):
            return r[0]

        return phone or user
    except sqlite3.Error as e:
        print(f"Database error while getting sender name: {e}")
        return sender_jid
    finally:
        if 'conn' in locals():
            conn.close()

def format_message(message: Message, show_chat_info: bool = True) -> None:
    """Print a single message with consistent formatting."""
    output = ""
    
    if show_chat_info and message.chat_name:
        output += f"[{message.timestamp:%Y-%m-%d %H:%M:%S}] Chat: {message.chat_name} "
    else:
        output += f"[{message.timestamp:%Y-%m-%d %H:%M:%S}] "
        
    content_prefix = ""
    if hasattr(message, 'media_type') and message.media_type:
        content_prefix = f"[{message.media_type} - Message ID: {message.id} - Chat JID: {message.chat_jid}] "
    
    try:
        sender_name = get_sender_name(message.sender) if not message.is_from_me else "Me"
        marks = ""
        if getattr(message, 'deleted_at', None):
            marks += "[ELIMINADO para todos] "
        if getattr(message, 'edited_at', None):
            marks += "[editado] "
        output += f"From: {sender_name}: {marks}{content_prefix}{message.content}\n"
        if getattr(message, 'reactions', None):
            partes = []
            for item in message.reactions.split(", "):
                emoji, _, who = item.partition(" ")
                partes.append(f"{emoji} {get_sender_name(who) if who else '?'}")
            output += f"    ♥ reacciones: {', '.join(partes)}\n"
        if getattr(message, 'quoted_id', None):
            quoted_sender = get_sender_name(message.quoted_sender) if message.quoted_sender else "?"
            quoted_text = (message.quoted_content or "").replace("\n", " ")
            if len(quoted_text) > 120:
                quoted_text = quoted_text[:117] + "..."
            output += f"    ↳ en respuesta a {quoted_sender} (ID {message.quoted_id}): {quoted_text}\n"
    except Exception as e:
        print(f"Error formatting message: {e}")
    return output

def format_messages_list(messages: List[Message], show_chat_info: bool = True) -> None:
    output = ""
    if not messages:
        output += "No messages to display."
        return output
    
    for message in messages:
        output += format_message(message, show_chat_info)
    return output

def list_messages(
    after: Optional[str] = None,
    before: Optional[str] = None,
    sender_phone_number: Optional[str] = None,
    chat_jid: Optional[str] = None,
    query: Optional[str] = None,
    limit: int = 20,
    page: int = 0,
    include_context: bool = True,
    context_before: int = 1,
    context_after: int = 1
) -> List[Message]:
    """Get messages matching the specified criteria with optional context."""
    try:
        conn = sqlite3.connect(MESSAGES_DB_PATH)
        cursor = conn.cursor()
        
        # Build base query
        query_parts = ["SELECT messages.timestamp, messages.sender, chats.name, messages.content, messages.is_from_me, chats.jid, messages.id, messages.media_type, messages.quoted_id, messages.quoted_sender, messages.quoted_content, messages.edited_at, messages.deleted_at, (SELECT group_concat(r.emoji || ' ' || r.sender, ', ') FROM reactions r WHERE r.message_id = messages.id AND r.chat_jid = messages.chat_jid) FROM messages"]
        query_parts.append("JOIN chats ON messages.chat_jid = chats.jid")
        where_clauses = []
        params = []
        
        # Add filters
        if after:
            try:
                after = datetime.fromisoformat(after)
            except ValueError:
                raise ValueError(f"Invalid date format for 'after': {after}. Please use ISO-8601 format.")
            
            where_clauses.append("messages.timestamp > ?")
            params.append(after)

        if before:
            try:
                before = datetime.fromisoformat(before)
            except ValueError:
                raise ValueError(f"Invalid date format for 'before': {before}. Please use ISO-8601 format.")
            
            where_clauses.append("messages.timestamp < ?")
            params.append(before)

        if sender_phone_number:
            where_clauses.append("messages.sender = ?")
            params.append(sender_phone_number)
            
        if chat_jid:
            where_clauses.append("messages.chat_jid = ?")
            params.append(chat_jid)
            
        if query:
            where_clauses.append("LOWER(messages.content) LIKE LOWER(?)")
            params.append(f"%{query}%")
            
        if where_clauses:
            query_parts.append("WHERE " + " AND ".join(where_clauses))
            
        # Add pagination
        offset = page * limit
        query_parts.append("ORDER BY messages.timestamp DESC")
        query_parts.append("LIMIT ? OFFSET ?")
        params.extend([limit, offset])
        
        cursor.execute(" ".join(query_parts), tuple(params))
        messages = cursor.fetchall()
        
        result = []
        for msg in messages:
            message = Message(
                timestamp=_parse_fecha(msg[0]),
                sender=msg[1],
                chat_name=msg[2],
                content=msg[3],
                is_from_me=msg[4],
                chat_jid=msg[5],
                id=msg[6],
                media_type=msg[7],
                quoted_id=msg[8],
                quoted_sender=msg[9],
                quoted_content=msg[10],
                edited_at=msg[11],
                deleted_at=msg[12],
                reactions=msg[13]
            )
            result.append(message)
            
        if include_context and result:
            # Add context for each message
            messages_with_context = []
            for msg in result:
                context = get_message_context(msg.id, context_before, context_after)
                messages_with_context.extend(context.before)
                messages_with_context.append(context.message)
                messages_with_context.extend(context.after)
            
            return format_messages_list(messages_with_context, show_chat_info=True)
            
        # Format and display messages without context
        return format_messages_list(result, show_chat_info=True)    
        
    except sqlite3.Error as e:
        print(f"Database error: {e}")
        return []
    finally:
        if 'conn' in locals():
            conn.close()


def get_message_context(
    message_id: str,
    before: int = 5,
    after: int = 5
) -> MessageContext:
    """Get context around a specific message."""
    try:
        conn = sqlite3.connect(MESSAGES_DB_PATH)
        cursor = conn.cursor()
        
        # Get the target message first
        cursor.execute("""
            SELECT messages.timestamp, messages.sender, chats.name, messages.content, messages.is_from_me, chats.jid, messages.id, messages.chat_jid, messages.media_type,
                   messages.quoted_id, messages.quoted_sender, messages.quoted_content,
                   messages.edited_at, messages.deleted_at, (SELECT group_concat(r.emoji || ' ' || r.sender, ', ') FROM reactions r WHERE r.message_id = messages.id AND r.chat_jid = messages.chat_jid)
            FROM messages
            JOIN chats ON messages.chat_jid = chats.jid
            WHERE messages.id = ?
        """, (message_id,))
        msg_data = cursor.fetchone()
        
        if not msg_data:
            raise ValueError(f"Message with ID {message_id} not found")
            
        target_message = Message(
            timestamp=_parse_fecha(msg_data[0]),
            sender=msg_data[1],
            chat_name=msg_data[2],
            content=msg_data[3],
            is_from_me=msg_data[4],
            chat_jid=msg_data[5],
            id=msg_data[6],
            media_type=msg_data[8],
            quoted_id=msg_data[9],
            quoted_sender=msg_data[10],
            quoted_content=msg_data[11],
            edited_at=msg_data[12],
            deleted_at=msg_data[13],
            reactions=msg_data[14]
        )
        
        # Get messages before
        cursor.execute("""
            SELECT messages.timestamp, messages.sender, chats.name, messages.content, messages.is_from_me, chats.jid, messages.id, messages.media_type,
                   messages.quoted_id, messages.quoted_sender, messages.quoted_content,
                   messages.edited_at, messages.deleted_at, (SELECT group_concat(r.emoji || ' ' || r.sender, ', ') FROM reactions r WHERE r.message_id = messages.id AND r.chat_jid = messages.chat_jid)
            FROM messages
            JOIN chats ON messages.chat_jid = chats.jid
            WHERE messages.chat_jid = ? AND messages.timestamp < ?
            ORDER BY messages.timestamp DESC
            LIMIT ?
        """, (msg_data[7], msg_data[0], before))
        
        before_messages = []
        for msg in cursor.fetchall():
            before_messages.append(Message(
                timestamp=_parse_fecha(msg[0]),
                sender=msg[1],
                chat_name=msg[2],
                content=msg[3],
                is_from_me=msg[4],
                chat_jid=msg[5],
                id=msg[6],
                media_type=msg[7],
                quoted_id=msg[8],
                quoted_sender=msg[9],
                quoted_content=msg[10],
                edited_at=msg[11],
                deleted_at=msg[12],
                reactions=msg[13]
            ))
        
        # Get messages after
        cursor.execute("""
            SELECT messages.timestamp, messages.sender, chats.name, messages.content, messages.is_from_me, chats.jid, messages.id, messages.media_type,
                   messages.quoted_id, messages.quoted_sender, messages.quoted_content,
                   messages.edited_at, messages.deleted_at, (SELECT group_concat(r.emoji || ' ' || r.sender, ', ') FROM reactions r WHERE r.message_id = messages.id AND r.chat_jid = messages.chat_jid)
            FROM messages
            JOIN chats ON messages.chat_jid = chats.jid
            WHERE messages.chat_jid = ? AND messages.timestamp > ?
            ORDER BY messages.timestamp ASC
            LIMIT ?
        """, (msg_data[7], msg_data[0], after))
        
        after_messages = []
        for msg in cursor.fetchall():
            after_messages.append(Message(
                timestamp=_parse_fecha(msg[0]),
                sender=msg[1],
                chat_name=msg[2],
                content=msg[3],
                is_from_me=msg[4],
                chat_jid=msg[5],
                id=msg[6],
                media_type=msg[7],
                quoted_id=msg[8],
                quoted_sender=msg[9],
                quoted_content=msg[10],
                edited_at=msg[11],
                deleted_at=msg[12],
                reactions=msg[13]
            ))
        
        return MessageContext(
            message=target_message,
            before=before_messages,
            after=after_messages
        )
        
    except sqlite3.Error as e:
        print(f"Database error: {e}")
        raise
    finally:
        if 'conn' in locals():
            conn.close()


def list_chats(
    query: Optional[str] = None,
    limit: int = 20,
    page: int = 0,
    include_last_message: bool = True,
    sort_by: str = "last_active"
) -> List[Chat]:
    """Get chats matching the specified criteria."""
    try:
        conn = sqlite3.connect(MESSAGES_DB_PATH)
        cursor = conn.cursor()
        
        # Build base query
        query_parts = ["""
            SELECT 
                chats.jid,
                chats.name,
                chats.last_message_time,
                messages.content as last_message,
                messages.sender as last_sender,
                messages.is_from_me as last_is_from_me
            FROM chats
        """]
        
        if include_last_message:
            query_parts.append("""
                LEFT JOIN messages ON chats.jid = messages.chat_jid 
                AND chats.last_message_time = messages.timestamp
            """)
            
        where_clauses = []
        params = []
        
        if query:
            where_clauses.append("(LOWER(chats.name) LIKE LOWER(?) OR chats.jid LIKE ?)")
            params.extend([f"%{query}%", f"%{query}%"])
            
        if where_clauses:
            query_parts.append("WHERE " + " AND ".join(where_clauses))
            
        # Add sorting
        order_by = "chats.last_message_time DESC" if sort_by == "last_active" else "chats.name"
        query_parts.append(f"ORDER BY {order_by}")
        
        # Add pagination
        offset = (page ) * limit
        query_parts.append("LIMIT ? OFFSET ?")
        params.extend([limit, offset])
        
        cursor.execute(" ".join(query_parts), tuple(params))
        chats = cursor.fetchall()
        
        result = []
        for chat_data in chats:
            chat = Chat(
                jid=chat_data[0],
                name=chat_data[1],
                last_message_time=_parse_fecha(chat_data[2]) if chat_data[2] else None,
                last_message=chat_data[3],
                last_sender=chat_data[4],
                last_is_from_me=chat_data[5]
            )
            result.append(chat)
            
        return result
        
    except sqlite3.Error as e:
        print(f"Database error: {e}")
        return []
    finally:
        if 'conn' in locals():
            conn.close()


def search_contacts(query: str) -> List[Contact]:
    """Search contacts by name or phone number."""
    try:
        conn = sqlite3.connect(MESSAGES_DB_PATH)
        cursor = conn.cursor()
        
        # Split query into characters to support partial matching
        search_pattern = '%' +query + '%'
        
        cursor.execute("""
            SELECT DISTINCT 
                jid,
                name
            FROM chats
            WHERE 
                (LOWER(name) LIKE LOWER(?) OR LOWER(jid) LIKE LOWER(?))
                AND jid NOT LIKE '%@g.us'
            ORDER BY name, jid
            LIMIT 50
        """, (search_pattern, search_pattern))
        
        contacts = cursor.fetchall()
        
        result = []
        for contact_data in contacts:
            contact = Contact(
                phone_number=contact_data[0].split('@')[0],
                name=contact_data[1],
                jid=contact_data[0]
            )
            result.append(contact)
            
        return result
        
    except sqlite3.Error as e:
        print(f"Database error: {e}")
        return []
    finally:
        if 'conn' in locals():
            conn.close()


def get_contact_chats(jid: str, limit: int = 20, page: int = 0) -> List[Chat]:
    """Get all chats involving the contact.
    
    Args:
        jid: The contact's JID to search for
        limit: Maximum number of chats to return (default 20)
        page: Page number for pagination (default 0)
    """
    try:
        conn = sqlite3.connect(MESSAGES_DB_PATH)
        cursor = conn.cursor()
        
        cursor.execute("""
            SELECT DISTINCT
                c.jid,
                c.name,
                c.last_message_time,
                m.content as last_message,
                m.sender as last_sender,
                m.is_from_me as last_is_from_me
            FROM chats c
            JOIN messages m ON c.jid = m.chat_jid
            WHERE m.sender = ? OR c.jid = ?
            ORDER BY c.last_message_time DESC
            LIMIT ? OFFSET ?
        """, (jid, jid, limit, page * limit))
        
        chats = cursor.fetchall()
        
        result = []
        for chat_data in chats:
            chat = Chat(
                jid=chat_data[0],
                name=chat_data[1],
                last_message_time=_parse_fecha(chat_data[2]) if chat_data[2] else None,
                last_message=chat_data[3],
                last_sender=chat_data[4],
                last_is_from_me=chat_data[5]
            )
            result.append(chat)
            
        return result
        
    except sqlite3.Error as e:
        print(f"Database error: {e}")
        return []
    finally:
        if 'conn' in locals():
            conn.close()


def get_last_interaction(jid: str) -> str:
    """Get most recent message involving the contact."""
    try:
        conn = sqlite3.connect(MESSAGES_DB_PATH)
        cursor = conn.cursor()
        
        cursor.execute("""
            SELECT 
                m.timestamp,
                m.sender,
                c.name,
                m.content,
                m.is_from_me,
                c.jid,
                m.id,
                m.media_type
            FROM messages m
            JOIN chats c ON m.chat_jid = c.jid
            WHERE m.sender = ? OR c.jid = ?
            ORDER BY m.timestamp DESC
            LIMIT 1
        """, (jid, jid))
        
        msg_data = cursor.fetchone()
        
        if not msg_data:
            return None
            
        message = Message(
            timestamp=_parse_fecha(msg_data[0]),
            sender=msg_data[1],
            chat_name=msg_data[2],
            content=msg_data[3],
            is_from_me=msg_data[4],
            chat_jid=msg_data[5],
            id=msg_data[6],
            media_type=msg_data[7]
        )
        
        return format_message(message)
        
    except sqlite3.Error as e:
        print(f"Database error: {e}")
        return None
    finally:
        if 'conn' in locals():
            conn.close()


def get_chat(chat_jid: str, include_last_message: bool = True) -> Optional[Chat]:
    """Get chat metadata by JID."""
    try:
        conn = sqlite3.connect(MESSAGES_DB_PATH)
        cursor = conn.cursor()
        
        query = """
            SELECT 
                c.jid,
                c.name,
                c.last_message_time,
                m.content as last_message,
                m.sender as last_sender,
                m.is_from_me as last_is_from_me
            FROM chats c
        """
        
        if include_last_message:
            query += """
                LEFT JOIN messages m ON c.jid = m.chat_jid 
                AND c.last_message_time = m.timestamp
            """
            
        query += " WHERE c.jid = ?"
        
        cursor.execute(query, (chat_jid,))
        chat_data = cursor.fetchone()
        
        if not chat_data:
            return None
            
        return Chat(
            jid=chat_data[0],
            name=chat_data[1],
            last_message_time=_parse_fecha(chat_data[2]) if chat_data[2] else None,
            last_message=chat_data[3],
            last_sender=chat_data[4],
            last_is_from_me=chat_data[5]
        )
        
    except sqlite3.Error as e:
        print(f"Database error: {e}")
        return None
    finally:
        if 'conn' in locals():
            conn.close()


def get_direct_chat_by_contact(sender_phone_number: str) -> Optional[Chat]:
    """Get chat metadata by sender phone number."""
    try:
        conn = sqlite3.connect(MESSAGES_DB_PATH)
        cursor = conn.cursor()
        
        cursor.execute("""
            SELECT 
                c.jid,
                c.name,
                c.last_message_time,
                m.content as last_message,
                m.sender as last_sender,
                m.is_from_me as last_is_from_me
            FROM chats c
            LEFT JOIN messages m ON c.jid = m.chat_jid 
                AND c.last_message_time = m.timestamp
            WHERE c.jid LIKE ? AND c.jid NOT LIKE '%@g.us'
            LIMIT 1
        """, (f"%{sender_phone_number}%",))
        
        chat_data = cursor.fetchone()
        
        if not chat_data:
            return None
            
        return Chat(
            jid=chat_data[0],
            name=chat_data[1],
            last_message_time=_parse_fecha(chat_data[2]) if chat_data[2] else None,
            last_message=chat_data[3],
            last_sender=chat_data[4],
            last_is_from_me=chat_data[5]
        )
        
    except sqlite3.Error as e:
        print(f"Database error: {e}")
        return None
    finally:
        if 'conn' in locals():
            conn.close()

def send_message(recipient: str, message: str) -> Tuple[bool, str]:
    try:
        # Validate input
        if not recipient:
            return False, "Recipient must be provided"
        
        url = f"{WHATSAPP_API_BASE_URL}/send"
        payload = {
            "recipient": recipient,
            "message": message,
        }
        
        response = requests.post(url, json=payload)
        
        # Check if the request was successful
        if response.status_code == 200:
            result = response.json()
            return result.get("success", False), result.get("message", "Unknown response")
        else:
            return False, f"Error: HTTP {response.status_code} - {response.text}"
            
    except requests.RequestException as e:
        return False, f"Request error: {str(e)}"
    except json.JSONDecodeError:
        return False, f"Error parsing response: {response.text}"
    except Exception as e:
        return False, f"Unexpected error: {str(e)}"

def mark_read(chat_jids: List[str], limit: int = 50, dry_run: bool = False) -> dict:
    """Marca como leídos los últimos mensajes recibidos de uno o varios chats.

    Llama al endpoint /api/markread del bridge, que envía los recibos de lectura
    a WhatsApp (el remitente ve las palomitas azules). Con dry_run=True solo
    cuenta cuántos marcaría sin mandar nada.
    """
    if not chat_jids:
        return {"success": False, "message": "Debes indicar al menos un chat_jid"}
    try:
        response = requests.post(
            f"{WHATSAPP_API_BASE_URL}/markread",
            json={"chat_jids": chat_jids, "limit": limit, "dry_run": dry_run},
            timeout=30,
        )
        if response.status_code != 200:
            return {"success": False, "message": f"Error: HTTP {response.status_code} - {response.text}"}
        return response.json()
    except requests.RequestException as e:
        return {"success": False, "message": f"Request error: {e}"}
    except json.JSONDecodeError:
        return {"success": False, "message": f"Error parsing response: {response.text}"}

def load_older_messages(chat_jid: str, count: int = 50, wait_seconds: int = 20) -> dict:
    """Pide al teléfono los mensajes anteriores al más viejo que la base tiene de un chat.

    WhatsApp entrega al vincular solo una ventana de historial; lo anterior hay
    que pedirlo por páginas. Cada llamada trae hasta `count` mensajes más
    antiguos y espera hasta `wait_seconds` a que lleguen. El teléfono principal
    tiene que estar encendido y con conexión, porque es quien los envía.
    """
    if not chat_jid:
        return {"success": False, "message": "Debes indicar el chat_jid"}
    try:
        response = requests.post(
            f"{WHATSAPP_API_BASE_URL}/history",
            json={"chat_jid": chat_jid, "count": count, "wait_seconds": wait_seconds},
            timeout=wait_seconds + 30,
        )
        if response.status_code != 200:
            try:
                return response.json()
            except ValueError:
                return {"success": False, "message": f"Error: HTTP {response.status_code} - {response.text}"}
        return response.json()
    except requests.RequestException as e:
        return {"success": False, "message": f"Request error: {e}"}

def send_file(recipient: str, media_path: str) -> Tuple[bool, str]:
    try:
        # Validate input
        if not recipient:
            return False, "Recipient must be provided"
        
        if not media_path:
            return False, "Media path must be provided"
        
        if not os.path.isfile(media_path):
            return False, f"Media file not found: {media_path}"
        
        url = f"{WHATSAPP_API_BASE_URL}/send"
        payload = {
            "recipient": recipient,
            "media_path": media_path
        }
        
        response = requests.post(url, json=payload)
        
        # Check if the request was successful
        if response.status_code == 200:
            result = response.json()
            return result.get("success", False), result.get("message", "Unknown response")
        else:
            return False, f"Error: HTTP {response.status_code} - {response.text}"
            
    except requests.RequestException as e:
        return False, f"Request error: {str(e)}"
    except json.JSONDecodeError:
        return False, f"Error parsing response: {response.text}"
    except Exception as e:
        return False, f"Unexpected error: {str(e)}"

def send_audio_message(recipient: str, media_path: str) -> Tuple[bool, str]:
    try:
        # Validate input
        if not recipient:
            return False, "Recipient must be provided"
        
        if not media_path:
            return False, "Media path must be provided"
        
        if not os.path.isfile(media_path):
            return False, f"Media file not found: {media_path}"

        if not media_path.endswith(".ogg"):
            try:
                media_path = audio.convert_to_opus_ogg_temp(media_path)
            except Exception as e:
                return False, f"Error converting file to opus ogg. You likely need to install ffmpeg: {str(e)}"
        
        url = f"{WHATSAPP_API_BASE_URL}/send"
        payload = {
            "recipient": recipient,
            "media_path": media_path
        }
        
        response = requests.post(url, json=payload)
        
        # Check if the request was successful
        if response.status_code == 200:
            result = response.json()
            return result.get("success", False), result.get("message", "Unknown response")
        else:
            return False, f"Error: HTTP {response.status_code} - {response.text}"
            
    except requests.RequestException as e:
        return False, f"Request error: {str(e)}"
    except json.JSONDecodeError:
        return False, f"Error parsing response: {response.text}"
    except Exception as e:
        return False, f"Unexpected error: {str(e)}"

def download_media(message_id: str, chat_jid: str) -> Optional[str]:
    """Download media from a message and return the local file path.
    
    Args:
        message_id: The ID of the message containing the media
        chat_jid: The JID of the chat containing the message
    
    Returns:
        The local file path if download was successful, None otherwise
    """
    try:
        url = f"{WHATSAPP_API_BASE_URL}/download"
        payload = {
            "message_id": message_id,
            "chat_jid": chat_jid
        }
        
        response = requests.post(url, json=payload)
        
        if response.status_code == 200:
            result = response.json()
            if result.get("success", False):
                path = result.get("path")
                print(f"Media downloaded successfully: {path}")
                return path
            else:
                print(f"Download failed: {result.get('message', 'Unknown error')}")
                return None
        else:
            print(f"Error: HTTP {response.status_code} - {response.text}")
            return None
            
    except requests.RequestException as e:
        print(f"Request error: {str(e)}")
        return None
    except json.JSONDecodeError:
        print(f"Error parsing response: {response.text}")
        return None
    except Exception as e:
        print(f"Unexpected error: {str(e)}")
        return None
