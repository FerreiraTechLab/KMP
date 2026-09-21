import http.server
import json
import os
import subprocess
import threading
import unittest


class Handler(http.server.BaseHTTPRequestHandler):
    request_body = None

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        Handler.request_body = json.loads(self.rfile.read(length))
        body = json.dumps({"jsonrpc": "2.0", "id": "kmp", "result": "abcdef1234567890"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class RpcHttpTest(unittest.TestCase):
    def test_curl_transport(self):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            env = os.environ.copy()
            env["KMP_TEST_RPC_URL"] = f"http://127.0.0.1:{server.server_port}/jsonrpc"
            code = (
                "package.path='KMP/game/?.lua;'..package.path; "
                "local call=require('aria2_rpc').new(os.getenv('KMP_TEST_RPC_URL'), 'abc123'); "
                "assert(call('aria2.addUri', {{\"magnet:?xt=urn:btih:abc&dn=it's-safe\"}}) == 'abcdef1234567890')"
            )
            subprocess.run(["lua", "-e", code], env=env, check=True)
            self.assertEqual(Handler.request_body["params"][0], "token:abc123")
            self.assertEqual(
                Handler.request_body["params"][1][0],
                "magnet:?xt=urn:btih:abc&dn=it's-safe",
            )
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
