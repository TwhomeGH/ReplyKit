"""索引路徑安全、資料有效性與 HTTP 整合測試；不啟動瀏覽器。"""
import json
import threading
import unittest
from urllib.request import urlopen
from http.server import ThreadingHTTPServer
import dev_index
import change_log

class IndexTests(unittest.TestCase):
    def test_catalog(self):
        self.assertGreater(len(dev_index.validate()), 0)

    def test_paths(self):
        for repo, path in [("app", "../secret.swift"), ("missing", "README.md"), ("app", ".git/config")]:
            with self.assertRaises(ValueError):
                dev_index.safe_file(repo, path)

    def test_source_and_missing_file(self):
        code, page, mime = dev_index.route("/development/file", "repo=app&path=SharedCapture/StreamAudioBitrate.swift")
        self.assertEqual(code, 200)
        self.assertIn('id="L1"', page)
        self.assertIn("text/html", mime)
        self.assertEqual(dev_index.route("/development/file", "path=../secret.swift")[0], 400)

    def test_snapshot(self):
        data = dev_index.snapshot()
        self.assertTrue(data["lockedPackages"])
        self.assertTrue(any("StreamAudioBitrate" in symbol["name"] for symbol in data["symbols"]))
        self.assertTrue(data["repos"][0]["head"])

    def test_http_integration(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), change_log.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = "http://127.0.0.1:" + str(server.server_address[1])
            with urlopen(base + "/development", timeout=20) as response:
                self.assertIn("開發索引", response.read().decode())
            with urlopen(base + "/development/data", timeout=40) as response:
                self.assertTrue(json.load(response)["features"])
            with urlopen(base + "/assets/theme.css", timeout=20) as response:
                self.assertEqual(response.status, 200)
                self.assertIn("--accent", response.read().decode())
            with urlopen(base + "/", timeout=20) as response:
                self.assertIn('/development', response.read().decode())
        finally:
            server.shutdown(); server.server_close(); thread.join()

if __name__ == "__main__":
    unittest.main()
