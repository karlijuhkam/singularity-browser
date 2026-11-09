# Local server for the frame probe: static files from www/, /slow answers after 4 s (so a frame
# stays on its initial about:blank document), /beacon counts as a network leak. Prints its port.
import http.server, socketserver, sys, time, urllib.parse
ROOT, LOG = sys.argv[1], sys.argv[2]

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=ROOT, **k)
    def log_message(self, fmt, *args):
        with open(LOG, "a") as f: f.write(self.path + "\n")
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/slow":
            time.sleep(4)
            body = b"<html><body>slow</body></html>"
            self.send_response(200); self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        if path == "/beacon":
            self.send_response(204); self.end_headers(); return
        return super().do_GET()

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
server = Server(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
