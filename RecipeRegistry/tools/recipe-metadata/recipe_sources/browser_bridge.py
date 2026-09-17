"""Read pages out of a Chrome that is already showing them.

The obtain-side data lives in the rendered HTML of an item page, and fetching
those pages with urllib stopped working: a 403 that held even on a single
serial request. This reads the same pages from a real Chrome instead -- the
tabs open, the browser loads them as it loads anything else, and the DOM is
read back over the DevTools protocol.

The pacing is deliberate and is the point: a batch at a time, with a gap
between batches, which is roughly what a person clicking through tabs would
generate.

Implemented against the DevTools protocol directly rather than through
Selenium or Playwright. This project has no third-party Python dependencies
-- there is not even a YAML parser, the one config file is read by hand -- and
a WebSocket client small enough to read in one sitting is a better trade than
a driver stack and a matching browser binary.
"""

import base64
import json
import os
import socket
import struct
import subprocess
import time
from urllib.request import urlopen


DEFAULT_PORT = 9222
DEFAULT_BATCH = 20
# Between batches, not between tabs: a batch opens at once, the way a person
# middle-clicks a page of search results.
DEFAULT_BATCH_DELAY = 3.0
DEFAULT_LOAD_TIMEOUT = 30.0

CHROME_CANDIDATES = (
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    "/usr/bin/google-chrome",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
)


def find_browser(explicit=None):
    if explicit:
        return explicit
    for candidate in CHROME_CANDIDATES:
        if os.path.exists(candidate):
            return candidate
    raise RuntimeError("no Chrome or Edge found; pass --browser with the path")


class WebSocket(object):
    """The smallest client that can carry a DevTools session.

    Text frames only, one connection per page, no extensions and no
    compression -- DevTools needs none of it. Client frames are masked because
    the protocol requires it; server frames never are.
    """

    def __init__(self, url, timeout=DEFAULT_LOAD_TIMEOUT):
        if not url.startswith("ws://"):
            raise ValueError("only ws:// is supported, got " + url)
        rest = url[len("ws://"):]
        hostport, _, path = rest.partition("/")
        host, _, port = hostport.partition(":")
        self._socket = socket.create_connection((host, int(port or 80)), timeout)
        self._socket.settimeout(timeout)
        self._buffer = b""

        key = base64.b64encode(os.urandom(16)).decode("ascii")
        handshake = (
            "GET /{0} HTTP/1.1\r\n"
            "Host: {1}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: {2}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        ).format(path, hostport, key)
        self._socket.sendall(handshake.encode("ascii"))

        while b"\r\n\r\n" not in self._buffer:
            chunk = self._socket.recv(4096)
            if not chunk:
                raise RuntimeError("browser closed the connection during handshake")
            self._buffer += chunk
        head, _, self._buffer = self._buffer.partition(b"\r\n\r\n")
        if b"101" not in head.split(b"\r\n")[0]:
            raise RuntimeError("browser refused the websocket upgrade: "
                               + head.split(b"\r\n")[0].decode("ascii", "replace"))

    def _recv_exactly(self, count):
        while len(self._buffer) < count:
            chunk = self._socket.recv(65536)
            if not chunk:
                raise RuntimeError("browser closed the connection")
            self._buffer += chunk
        out, self._buffer = self._buffer[:count], self._buffer[count:]
        return out

    def send(self, payload):
        data = payload.encode("utf-8")
        header = bytearray([0x81])  # FIN + text
        length = len(data)
        if length < 126:
            header.append(0x80 | length)
        elif length < (1 << 16):
            header.append(0x80 | 126)
            header += struct.pack(">H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", length)
        mask = os.urandom(4)
        header += mask
        masked = bytearray(data)
        for index in range(len(masked)):
            masked[index] ^= mask[index % 4]
        self._socket.sendall(bytes(header) + bytes(masked))

    def recv(self):
        """One whole message, reassembled across continuation frames."""
        chunks = []
        while True:
            first, second = self._recv_exactly(2)
            final = bool(first & 0x80)
            opcode = first & 0x0F
            length = second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._recv_exactly(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._recv_exactly(8))[0]
            payload = self._recv_exactly(length) if length else b""

            if opcode == 0x8:
                raise RuntimeError("browser closed the websocket")
            if opcode == 0x9:  # ping; DevTools does not send these, but be safe
                continue
            chunks.append(payload)
            if final:
                return b"".join(chunks).decode("utf-8", "replace")

    def close(self):
        try:
            self._socket.close()
        except Exception:
            pass


class Browser(object):
    """A Chrome with the DevTools port open, and the tabs in it."""

    def __init__(self, port=DEFAULT_PORT, browser_path=None, profile_dir=None,
                 headless=False, launch=True):
        self.port = port
        self._process = None
        if launch:
            self._launch(browser_path, profile_dir, headless)
        self._wait_for_port()
        self._browser_socket = WebSocket(self._browser_ws_url())
        self._next_id = 0

    # -- lifecycle ---------------------------------------------------------
    def _launch(self, browser_path, profile_dir, headless):
        profile_dir = profile_dir or os.path.join(
            os.environ.get("TEMP", "/tmp"), "recipe-registry-browser-profile")
        args = [
            find_browser(browser_path),
            "--remote-debugging-port={0}".format(self.port),
            "--user-data-dir=" + profile_dir,
            "--no-first-run",
            "--no-default-browser-check",
            "about:blank",
        ]
        if headless:
            args.insert(1, "--headless=new")
        self._process = subprocess.Popen(
            args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def _wait_for_port(self, timeout=30.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                self._get("/json/version")
                return
            except Exception:
                time.sleep(0.3)
        raise RuntimeError(
            "the browser never opened its debugging port. If Chrome was "
            "already running, it ignores --remote-debugging-port on a profile "
            "that is already open: close it, or pass a different --port.")

    def _get(self, path):
        with urlopen("http://127.0.0.1:{0}{1}".format(self.port, path), timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))

    def _browser_ws_url(self):
        return self._get("/json/version")["webSocketDebuggerUrl"]

    def close(self):
        try:
            self._browser_socket.close()
        finally:
            if self._process:
                self._process.terminate()

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.close()

    # -- protocol ----------------------------------------------------------
    def _command(self, socket_, method, params=None, session=None):
        self._next_id += 1
        message = {"id": self._next_id, "method": method, "params": params or {}}
        if session:
            message["sessionId"] = session
        socket_.send(json.dumps(message))
        while True:
            reply = json.loads(socket_.recv())
            # Events share the channel with replies; only the matching id is
            # an answer to this call.
            if reply.get("id") != self._next_id:
                continue
            if "error" in reply:
                raise RuntimeError("{0}: {1}".format(method, reply["error"]))
            return reply.get("result", {})

    # -- tabs --------------------------------------------------------------
    def open_tab(self, url):
        result = self._command(self._browser_socket, "Target.createTarget", {"url": url})
        return result["targetId"]

    def close_tab(self, target_id):
        try:
            self._command(self._browser_socket, "Target.closeTarget",
                          {"targetId": target_id})
        except Exception:
            pass

    def _page_socket(self, target_id):
        for entry in self._get("/json/list"):
            if entry.get("id") == target_id and entry.get("webSocketDebuggerUrl"):
                return WebSocket(entry["webSocketDebuggerUrl"])
        raise RuntimeError("tab {0} has no debugging endpoint".format(target_id))

    def read_html(self, target_id, load_timeout=DEFAULT_LOAD_TIMEOUT):
        """The rendered DOM of one tab, once the page has settled.

        A tab reports readyState "complete" before it has begun navigating --
        the empty document it starts life with is, correctly, fully loaded.
        Waiting on that alone reads back an empty page, so the wait is for the
        tab to have left about:blank as well.
        """
        page = self._page_socket(target_id)
        try:
            deadline = time.time() + load_timeout
            while time.time() < deadline:
                state = self._evaluate(page, "document.readyState")
                location = self._evaluate(page, "location.href") or ""
                if state == "complete" and not location.startswith("about:"):
                    break
                time.sleep(0.4)
            return self._evaluate(page, "document.documentElement.outerHTML") or ""
        finally:
            page.close()

    def _evaluate(self, page, expression):
        result = self._command(page, "Runtime.evaluate", {
            "expression": expression,
            "returnByValue": True,
            # A page-load navigation can invalidate the context mid-call;
            # awaiting the promise keeps the reply on the same execution.
            "awaitPromise": False,
        })
        return (result.get("result") or {}).get("value")

    # -- the useful shape --------------------------------------------------
    def read_pages(self, urls, batch=DEFAULT_BATCH, batch_delay=DEFAULT_BATCH_DELAY,
                   load_timeout=DEFAULT_LOAD_TIMEOUT, on_page=None):
        """Open the URLs a batch at a time and yield (url, html) for each.

        Tabs are closed as their batch finishes, so the browser holds a batch
        at a time rather than a hundred pages of open tabs.
        """
        urls = list(urls)
        for start in range(0, len(urls), batch):
            window = urls[start:start + batch]
            targets = [(url, self.open_tab(url)) for url in window]
            for url, target_id in targets:
                try:
                    html = self.read_html(target_id, load_timeout=load_timeout)
                except Exception as error:
                    html = None
                    if on_page:
                        on_page(url, None, str(error))
                else:
                    if on_page:
                        on_page(url, html, None)
                yield url, html
                self.close_tab(target_id)
            if batch_delay and start + batch < len(urls):
                time.sleep(batch_delay)
