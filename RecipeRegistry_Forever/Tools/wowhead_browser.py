"""Un Chrome vero, pilotato via DevTools, per leggere le pagine di Wowhead.

Wowhead risponde 403 a curl, e a un browser chiede prima una verifica di AWS
WAF. A volte Chrome completa la verifica da solo, altre volte serve intervenire
nella scheda: interactive=True lascia farlo all'utente, poi rilegge la stessa
pagina. Una pagina viene accettata solo quando contiene i dati richiesti,
mai per la sola dimensione dell'HTML.

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
import re
import socket
import struct
import subprocess
import time
from urllib.request import urlopen
from urllib.parse import urlsplit


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

    def __init__(self, message, html=""):
        super().__init__(message)
        self.html = html


def challenge_reason(html):
    lowered = html.lower()
    if CHALLENGE_FAILED.lower() in lowered:
        return "verifica fallita"
    if any(mark in lowered for mark in (CHALLENGE_MARK, "captcha-container",
                                        "awswaf-captcha", "cf-chl-")):
        return "verifica richiesta da Wowhead"
    title = re.search(r"<title[^>]*>(.*?)</title>", lowered, re.S)
    if title and any(mark in title.group(1) for mark in
                     ("just a moment", "access denied", "request blocked", "403 forbidden")):
        return "accesso rifiutato da Wowhead"
    return None


def page_has_data(html, url):
    """Gli stessi blocchi letti dal parser, per il tipo e l'ID richiesti.

    Anche una pagina di errore puo' superare 10 KB. Un oggetto senza fonti e'
    valido se ha il suo blob; una pagina di verifica senza blob non lo e'.
    """
    route = urlsplit(url).path
    item = re.search(r"/item=(\d+)(?:/|$)", route)
    if item:
        return bool(re.search(r"\$\.extend\(g_items\[%s\],\s*\{" % item.group(1), html))
    if "/items/recipes/" in route:
        return "var listviewitems = [" in html
    if "/spells/" in route:
        return "var listviewspells = [" in html
    if route.endswith("/zones") or "/zones/" in route:
        return bool(re.search(
            r'<script type="application/json" id="data\.page\.listPage\.listviews">', html))
    return False


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
    def __init__(self, port=DEFAULT_PORT, profile_dir=DEFAULT_PROFILE, interactive=False,
                 verification_timeout=300.0):
        self.port = port
        self.interactive = interactive
        self.verification_timeout = verification_timeout
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
        try:
            # Una chiusura normale lascia a Chrome il tempo di salvare i cookie.
            self._command(self._root, "Browser.close")
        except (OSError, RuntimeError):
            pass
        finally:
            self._root.close()
        try:
            self._process.wait(timeout=5)
        except subprocess.TimeoutExpired:
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
            deadline = time.monotonic() + timeout
            html = ""
            manual_used = False
            while True:
                time.sleep(1)
                try:
                    state = self._evaluate(page, "document.readyState")
                    html = self._evaluate(page, "document.documentElement.outerHTML") or ""
                except RuntimeError:
                    # Una ricarica invalida il contesto JS, ma non il timeout.
                    state, html = "loading", ""
                reason = challenge_reason(html)
                if state == "complete" and not reason and page_has_data(html, url):
                    return html
                expired = time.monotonic() >= deadline
                if self.interactive and not manual_used and (reason or expired):
                    print("\nWowhead: %s\n%s" % (reason or "dati della pagina non disponibili", url), flush=True)
                    print("Completa la verifica nel Chrome aperto (se serve, ricarica la scheda). "
                          "Riprendo automaticamente quando compaiono i dati; attendo al massimo %ds. "
                          "Ctrl+C interrompe." % self.verification_timeout, flush=True)
                    manual_used = True
                    deadline = time.monotonic() + self.verification_timeout
                    continue
                if not manual_used and reason in ("verifica fallita", "accesso rifiutato da Wowhead"):
                    raise Refused(reason + "; prova --interactive o --from-html", html)
                if expired:
                    waited = self.verification_timeout if manual_used else timeout
                    raise Refused((reason or "dati attesi non trovati") +
                                  " dopo %ds; prova --interactive o --from-html" % waited, html)
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
