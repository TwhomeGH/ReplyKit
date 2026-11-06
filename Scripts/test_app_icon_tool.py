"""圖示工具回歸測試：拒絕無效原稿、保留來源、固定產物與套用前備份。"""
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.request import Request, urlopen
from urllib.error import HTTPError

from PIL import Image
from app_icon_tool import generate, apply, source_path, IconServer, ICON


class IconToolTests(unittest.TestCase):
    def prepare(self, root):
        """生成不含外部圖片的測試來源。"""
        folder = root / 'Artwork/AppIcons'
        folder.mkdir(parents=True)
        Image.new('RGB', (1024, 1024), '#1f4070').save(folder / 'sample.png')
        return folder / 'sample.png'

    def test_preview_then_apply_preserves_source_and_backup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = self.prepare(root)
            original = source.read_bytes()
            old = root / ICON / 'PersonalIcon.png'
            old.parent.mkdir(parents=True)
            old.write_bytes(b'old')
            output, details = generate(root, 'sample.png')
            self.assertEqual(old.read_bytes(), b'old')
            self.assertEqual(len(output), 9)
            backup = root / apply(root, output, details)
            self.assertEqual((backup / ICON / 'PersonalIcon.png').read_bytes(), b'old')
            self.assertEqual(source.read_bytes(), original)
            with Image.open(old) as icon:
                self.assertEqual(icon.size, (1024, 1024))
                self.assertEqual(icon.mode, 'RGB')

    def test_rejects_transparency_and_path_escape(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = self.prepare(root)
            with self.assertRaises(ValueError):
                source_path(root, '../../outside.png')
            Image.new('RGBA', (1024, 1024), (255, 0, 0, 0)).save(source)
            with self.assertRaises(ValueError):
                generate(root, 'sample.png')

    def test_source_change_requires_new_preview(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = self.prepare(root)
            output, details = generate(root, 'sample.png')
            source.write_bytes(b'changed')
            with self.assertRaises(ValueError):
                apply(root, output, details)
            self.assertFalse((root / ICON / 'PersonalIcon.png').exists())

    def test_http_token_and_preview(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.prepare(root)
            server = IconServer(root)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            address = f'http://127.0.0.1:{server.server_port}'
            try:
                with urlopen(address + '/api/list') as response:
                    self.assertEqual(json.load(response)['files'], ['sample.png'])
                request = Request(address + '/api/preview', data=b'{"name":"sample.png","mode":"lossless"}')
                with self.assertRaises(HTTPError) as caught:
                    urlopen(request)
                self.assertEqual(caught.exception.code, 403)
                request.add_header('X-Icon-Token', server.token)
                with urlopen(request) as response:
                    result = json.load(response)
                self.assertIn('draftID', result)
                self.assertFalse((root / ICON / 'PersonalIcon.png').exists())
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


if __name__ == '__main__':
    unittest.main()
