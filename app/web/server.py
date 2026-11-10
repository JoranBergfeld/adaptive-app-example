import os
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


API_ORIGIN = os.environ["SHOP_API_ORIGIN"].rstrip("/")


class ShopHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory="/opt/app-root/src", **kwargs)

    def do_GET(self):
        self._handle_request()

    def do_HEAD(self):
        self._handle_request()

    def do_PUT(self):
        self._handle_request()

    def do_DELETE(self):
        self._handle_request()

    def _handle_request(self):
        if not (self.path.startswith("/api/") or self.path in ("/healthz", "/readyz")):
            if self.command in ("GET", "HEAD"):
                return super().do_GET() if self.command == "GET" else super().do_HEAD()
            self.send_error(404)
            return

        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        request = Request(
            f"{API_ORIGIN}{self.path}",
            data=body or None,
            headers={
                key: value
                for key, value in self.headers.items()
                if key.lower() in ("accept", "content-type")
            },
            method=self.command,
        )
        try:
            with urlopen(request, timeout=10) as response:
                status = response.status
                response_body = response.read()
                content_type = response.headers.get("Content-Type")
        except HTTPError as response:
            status = response.code
            response_body = response.read()
            content_type = response.headers.get("Content-Type")
        except URLError as error:
            self.send_error(502, f"API service is unavailable: {error.reason}")
            return

        self.send_response(status)
        if content_type:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(response_body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(response_body)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), ShopHandler).serve_forever()
