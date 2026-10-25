"""Un Chrome vero, pilotato via DevTools, per leggere le pagine di Wowhead.

Wowhead risponde 403 a curl, e a un browser chiede prima una verifica di AWS
WAF: una pagina di due KB che esegue il suo script, ottiene un token, lo salva
in un cookie e si ricarica sulla pagina vera. Un Chrome vero la supera da solo;
quello che serve qui e' aspettare che lo faccia, invece di leggere la pagina
della verifica come se fosse la risposta -- che e' l'errore della prima prova
del 25/10: cinque pagine lette, cinque verifiche, zero dati.

Il profilo e' separato dal Chrome di tutti i giorni e resta fra un giro e
l'altro, cosi' il token vale anche per il giro dopo.

Copia adattata di RecipeRegistry/tools/recipe-metadata/recipe_sources/
browser_bridge.py su develop: i due alberi non condividono codice. Il client
WebSocket e' lo stesso, scritto a mano perche' gli strumenti di questo repo
non hanno dipendenze esterne.
"""

import base64
import json
import os
import socket
import struct
import subprocess
import time
from urllib.request import urlopen


DEFAULT_PORT = 9333
DEFAULT_PROFILE = os.path.join(os.environ.get("TEMP", "."), "rr-forever-wowhead-profile")
CHROME_CANDIDATES = (
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
)

# I segni della pagina di verifica. Il primo c'e' finche' la verifica gira, il
# secondo quando AWS rinuncia: allora inutile aspettare, e' un rifiuto.
CHALLENGE_MARK = "challenge-container"
CHALLENGE_FAILED = "Max challenge attempts exceeded"


class Refused(Exception):
    """La verifica non e' passata: la pagina non arrivera'."""


def find_browser():
    for candidate in CHROME_CANDIDATES:
        if os.path.exists(candidate):
            return candidate
    raise RuntimeError("nessun Chrome o Edge trovato")


class WebSocket(object):
    """Il client piu' piccolo che regge una sessione DevTools: solo frame di
    testo, una connessione per scheda, niente estensioni."""

    def __init__(self, url, timeout=30.0):
        rest = url[len("ws://"):]
        hostport, _, path = rest.partition("/")
        host, _, port = hostport.partition(":")
        self._socket = socket.create_connection((host, int(port or 80)), timeout)
        self._socket.settimeout(timeout)
        self._buffer = b""
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        self._socket.sendall((
            "GET /{0} HTTP/1.1\r\nHost: {1}\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: {2}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n").format(path, hostport, key).encode("ascii"))
        while b"\r\n\r\n" not in self._buffer:
            chunk = self._socket.recv(4096)
            if not chunk:
                raise RuntimeError("il browser ha chiuso durante l'handshake")
            self._buffer += chunk
        head, _, self._buffer = self._buffer.partition(b"\r\n\r\n")
        if b"101" not in head.split(b"\r\n")[0]:
            raise RuntimeError("il browser ha rifiutato il websocket")

    def _exactly(self, count):
        while len(self._buffer) < count:
            chunk = self._socket.recv(65536)
            if not chunk:
                raise RuntimeError("il browser ha chiuso la connessione")
            self._buffer += chunk
        out, self._buffer = self._buffer[:count], self._buffer[count:]
        return out

    def send(self, payload):
        data = payload.encode("utf-8")
        header = bytearray([0x81])
        if len(data) < 126:
            header.append(0x80 | len(data))
        elif len(data) < (1 << 16):
            header.append(0x80 | 126)
            header += struct.pack(">H", len(data))
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", len(data))
        mask = os.urandom(4)
        header += mask
        masked = bytearray(data)
        for index in range(len(masked)):
            masked[index] ^= mask[index % 4]
        self._socket.sendall(bytes(header) + bytes(masked))

    def recv(self):
        chunks = []
        while True:
            first, second = self._exactly(2)
            length = second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._exactly(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._exactly(8))[0]
            payload = self._exactly(length) if length else b""
            opcode = first & 0x0F
            if opcode == 0x8:
                raise RuntimeError("il browser ha chiuso il websocket")
            if opcode == 0x9:
                continue
            chunks.append(payload)
            if first & 0x80:
                return b"".join(chunks).decode("utf-8", "replace")

    def close(self):
        try:
            self._socket.close()
        except Exception:
            pass


class Browser(object):
    def __init__(self, port=DEFAULT_PORT, profile_dir=DEFAULT_PROFILE):
        self.port = port
        self._next_id = 0
        self._process = subprocess.Popen(
            [find_browser(), "--remote-debugging-port=%d" % port,
             "--user-data-dir=" + profile_dir, "--no-first-run",
             "--no-default-browser-check", "about:blank"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 30
        while True:
            try:
                self._root = WebSocket(self._get("/json/version")["webSocketDebuggerUrl"])
                break
            except Exception:
                if time.time() > deadline:
                    raise RuntimeError("il browser non ha aperto la porta di debug")
                time.sleep(0.3)

    def _get(self, path):
        with urlopen("http://127.0.0.1:%d%s" % (self.port, path), timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))

    def _command(self, channel, method, params=None):
        self._next_id += 1
        channel.send(json.dumps({"id": self._next_id, "method": method, "params": params or {}}))
        while True:
            reply = json.loads(channel.recv())
            if reply.get("id") != self._next_id:
                continue      # un evento, non la risposta
            if "error" in reply:
                raise RuntimeError("%s: %s" % (method, reply["error"]))
            return reply.get("result", {})

    def close(self):
        self._root.close()
        self._process.terminate()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def read(self, url, timeout=60.0):
        """L'HTML della pagina vera, dopo la verifica se c'e'.

        Durante la verifica la pagina si ricarica, e una valutazione che cade
        a meta' ricarica fallisce: e' normale, si riprova al giro dopo.
        """
        target = self._command(self._root, "Target.createTarget", {"url": url})["targetId"]
        page = None
        try:
            for entry in self._get("/json/list"):
                if entry.get("id") == target:
                    page = WebSocket(entry["webSocketDebuggerUrl"])
            if page is None:
                raise RuntimeError("la scheda non ha un endpoint di debug")
            deadline = time.time() + timeout
            html = ""
            while time.time() < deadline:
                time.sleep(1)
                try:
                    state = self._evaluate(page, "document.readyState")
                    html = self._evaluate(page, "document.documentElement.outerHTML") or ""
                except RuntimeError:
                    continue
                if CHALLENGE_FAILED in html:
                    raise Refused("verifica fallita")
                if state == "complete" and CHALLENGE_MARK not in html and len(html) > 10000:
                    return html
            raise Refused("verifica non conclusa in %ds" % timeout)
        finally:
            if page:
                page.close()
            try:
                self._command(self._root, "Target.closeTarget", {"targetId": target})
            except Exception:
                pass

    def _evaluate(self, page, expression):
        result = self._command(page, "Runtime.evaluate",
                               {"expression": expression, "returnByValue": True})
        return (result.get("result") or {}).get("value")
