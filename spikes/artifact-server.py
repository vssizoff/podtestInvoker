import base64
import hashlib
import http.server
import pathlib
import socket
import ssl
import sys
import time


PAYLOAD = b"verified artifact\n"
CHECKSUM = base64.b64encode(hashlib.sha256(PAYLOAD).digest()).decode()


class Handler(http.server.BaseHTTPRequestHandler):
    retry_seen = False
    put_seen = False

    def do_GET(self):
        if self.path == "/ok?signature=test%2Fvalue":
            self.reply(200, PAYLOAD)
        elif self.path in BUNDLES:
            self.reply(200, BUNDLES[self.path])
        elif self.path == "/large":
            self.reply(200, PAYLOAD + b"!")
        elif self.path == "/short":
            self.reply(200, PAYLOAD[:-1])
        elif self.path == "/wrong":
            self.reply(200, b"!" + PAYLOAD[1:])
        elif self.path == "/partial":
            self.reply(206, PAYLOAD)
        elif self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/unexpected-follow")
            self.send_header("Content-Length", "64")
            self.end_headers()
            self.write_body(b"x" * 64)
        elif self.path == "/slow":
            self.send_response(200)
            self.send_header("Content-Length", str(len(PAYLOAD)))
            self.end_headers()
            for byte in PAYLOAD:
                time.sleep(0.03)
                self.write_body(bytes([byte]))
        elif self.path == "/temporary":
            self.reply(503, b"")
        elif self.path == "/retry":
            first = not Handler.retry_seen
            Handler.retry_seen = True
            self.reply(503 if first else 200, b"" if first else PAYLOAD)
        elif self.path == "/unexpected-follow":
            self.reply(200, PAYLOAD)
        else:
            self.reply(403, b"")

    def do_PUT(self):
        if self.path not in ("/upload?signature=fixture", "/upload-retry") or self.headers.get("x-amz-checksum-sha256") != CHECKSUM:
            self.reply(403, b"")
            return
        if self.headers.get("Content-Length") != str(len(PAYLOAD)):
            self.reply(400, b"")
            return
        body = self.rfile.read(len(PAYLOAD))
        if body != PAYLOAD:
            self.reply(400, b"")
            return
        if self.path == "/upload-retry" and not Handler.put_seen:
            Handler.put_seen = True
            self.reply(503, b"")
            return
        self.reply(200, b"")

    def reply(self, code, payload):
        self.send_response(code)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.write_body(payload)

    def write_body(self, payload):
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            pass

    def log_message(self, *args):
        pass


class Server(http.server.ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        if not isinstance(sys.exception(), (BrokenPipeError, ConnectionResetError, ssl.SSLEOFError)):
            super().handle_error(request, client_address)


BUNDLES = {
    f"/bundle/{name}?signature=fixture": pathlib.Path(path).read_bytes()
    for name, path in zip(("standard", "lua", "lua-unsupported"), sys.argv[4:], strict=True)
}
server = Server(("127.0.0.1", 0), Handler)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = tls.wrap_socket(server.socket, server_side=True)
pathlib.Path(sys.argv[3]).write_text(f"https://127.0.0.1:{server.server_port}\n")
server.serve_forever()
