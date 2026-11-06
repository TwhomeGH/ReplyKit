"""從 Artwork/AppIcons 選圖，預覽後更新固定 PersonalIcon；不新增替換圖示組。"""
import argparse
import base64
from datetime import datetime
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
from io import BytesIO
import json
import os
from pathlib import Path
import secrets
import shutil
import sys
from urllib.parse import urlparse
import webbrowser

from PIL import Image, ImageCms, ImageOps

ROOT = Path(__file__).resolve().parents[1]
ICON = 'liveAPP/Assets.xcassets/PersonalIcon.appiconset/'
PREVIEW = 'liveAPP/Assets.xcassets/PersonalIconPreview.imageset/'
SIZES = [('iphone', '60x60', '2x', 120), ('iphone', '60x60', '3x', 180),
         ('ipad', '76x76', '1x', 76), ('ipad', '76x76', '2x', 152),
         ('ipad', '83.5x83.5', '2x', 167), ('ios-marketing', '1024x1024', '1x', 1024)]


def source_path(root, name):
    """只允許原稿目錄的直接圖片檔，拒絕路徑跳脫與指向外部的連結。"""
    folder = (root / 'Artwork/AppIcons').resolve()
    path = (folder / name).resolve()
    if path.parent != folder or path.suffix.lower() not in {'.png', '.jpg', '.jpeg'} or not path.is_file():
        raise ValueError('請選擇 Artwork/AppIcons 裡的 PNG 或 JPEG')
    if path.stat().st_size > 30_000_000:
        raise ValueError('原稿超過 30 MB，請先縮小')
    return path


def encode_png(image):
    """輸出不透明 RGB PNG，以最大壓縮等級保存，不加入原稿的額外中繼資料。"""
    stream = BytesIO()
    image.save(stream, format='PNG', optimize=True, compress_level=9)
    return stream.getvalue()


def generate(root, name, mode='lossless'):
    """產生記憶體預覽；不修改專案。縮圖用 Lanczos，色彩減量僅由明確選項啟用。"""
    if mode not in {'lossless', 'colors256'}:
        raise ValueError('不支援的壓縮模式')
    path = source_path(root, name)
    original = path.read_bytes()
    with Image.open(BytesIO(original)) as opened:
        if opened.width != opened.height or not 1024 <= opened.width <= 8192:
            raise ValueError('需要 1024～8192 像素的正方形原稿；工具不自動裁切或放大')
        if getattr(opened, 'n_frames', 1) != 1:
            raise ValueError('請使用靜態圖片')
        image = ImageOps.exif_transpose(opened).convert('RGBA')
        if image.getchannel('A').getextrema() != (255, 255):
            raise ValueError('圖片含透明像素，請先自行選擇背景並另存原稿')
        image = image.convert('RGB')
        if opened.info.get('icc_profile'):
            image = ImageCms.profileToProfile(image, ImageCms.ImageCmsProfile(BytesIO(opened.info['icc_profile'])),
                                             ImageCms.createProfile('sRGB'), outputMode='RGB')
        source_size = image.size
        image = image.resize((1024, 1024), Image.Resampling.LANCZOS)
    if mode == 'colors256':
        image = image.quantize(colors=256, method=Image.Quantize.MEDIANCUT).convert('RGB')
    output, entries = {}, []
    for idiom, size, scale, pixels in SIZES:
        filename = 'PersonalIcon.png' if pixels == 1024 else f'PersonalIcon-{pixels}.png'
        output[ICON + filename] = encode_png(image.resize((pixels, pixels), Image.Resampling.LANCZOS))
        entries.append({'idiom': idiom, 'size': size, 'scale': scale, 'filename': filename})
    def metadata(images):
        return (json.dumps({'images': images, 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n').encode()
    output[ICON + 'Contents.json'] = metadata(entries)
    output[PREVIEW + 'preview.png'] = encode_png(image.resize((168, 168), Image.Resampling.LANCZOS))
    output[PREVIEW + 'Contents.json'] = metadata([{'filename': 'preview.png', 'idiom': 'universal'}])
    details = {'source': name, 'mode': mode, 'sourceSize': list(source_size), 'sourceBytes': len(original),
               'sourceSHA256': hashlib.sha256(original).hexdigest(),
               'beforeBytes': sum((root / key).stat().st_size for key in output if (root / key).exists()),
               'afterBytes': sum(map(len, output.values())),
               'files': [{'path': key, 'bytes': len(value)} for key, value in output.items()],
               'preview': base64.b64encode(output[ICON + 'PersonalIcon.png']).decode()}
    return output, details


def apply(root, output, details):
    """先保存舊檔，再逐檔原子替換；只寫固定資源，原稿保持不變。"""
    path = source_path(root, details['source'])
    if hashlib.sha256(path.read_bytes()).hexdigest() != details['sourceSHA256']:
        raise ValueError('原稿已變更，請重新預覽後套用')
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + secrets.token_hex(3)
    backup = root / '.build/app-icon-tool/backups' / stamp
    backup.mkdir(parents=True)
    old = {}
    for key in output:
        destination = root / key
        old[key] = destination.read_bytes() if destination.exists() else None
        if old[key] is not None:
            saved = backup / key
            saved.parent.mkdir(parents=True, exist_ok=True)
            saved.write_bytes(old[key])
    manifest = {k: v for k, v in details.items() if k != 'preview'}
    (backup / 'selection.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    # 舊檔在預覽後可能由另一個編輯器更動，備份採套用當下內容。
    changed = []
    try:
        for key, value in output.items():
            destination = root / key
            destination.parent.mkdir(parents=True, exist_ok=True)
            staged = backup / ('stage-' + str(len(changed)))
            staged.write_bytes(value)
            os.replace(staged, destination)
            changed.append(key)
    except OSError:
        for key in reversed(changed):
            destination = root / key
            if old[key] is None:
                destination.unlink()
            else:
                shutil.copyfile(backup / key, destination)
        raise
    return str(backup.relative_to(root))


class IconServer(HTTPServer):
    """只監聽 loopback；單一預覽草稿與一次性套用 token，避免重複覆寫。"""
    def __init__(self, root, port=0):
        super().__init__(('127.0.0.1', port), Handler)
        self.root = root
        self.token = secrets.token_urlsafe(32)
        self.draft = None


class Handler(BaseHTTPRequestHandler):
    """本機頁面只提供列圖、預覽與確認套用，不開放任意路徑檔案服務。"""
    def log_message(self, *_):
        pass

    def send(self, status, body, kind='application/json; charset=utf-8'):
        if not isinstance(body, bytes):
            body = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(body)

    def trusted(self):
        expected = f'127.0.0.1:{self.server.server_port}'
        return self.headers.get('Host') == expected and self.headers.get('Origin', 'http://' + expected) == 'http://' + expected

    def do_GET(self):
        if not self.trusted():
            self.send(403, {'error': '拒絕非本機來源'})
            return
        if self.path == '/':
            page = (self.server.root / 'Scripts/app_icon_tool.html').read_text(encoding='utf-8')
            self.send(200, page.replace('__TOKEN__', self.server.token).encode(), 'text/html; charset=utf-8')
        elif self.path == '/api/list':
            folder = self.server.root / 'Artwork/AppIcons'
            self.send(200, {'files': sorted(p.name for p in folder.iterdir() if p.is_file() and p.suffix.lower() in {'.png', '.jpg', '.jpeg'})})
        else:
            self.send(404, {'error': '找不到頁面'})

    def do_POST(self):
        if not self.trusted() or self.headers.get('X-Icon-Token') != self.server.token:
            self.send(403, {'error': '請從本機工具頁面操作'})
            return
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 4096:
                raise ValueError('要求內容大小不正確')
            request = json.loads(self.rfile.read(size))
            if self.path == '/api/preview':
                self.server.draft = None
                output, details = generate(self.server.root, request['name'], request['mode'])
                draft_id = secrets.token_urlsafe(16)
                self.server.draft = (draft_id, output, details)
                self.send(200, dict(details, draftID=draft_id))
            elif self.path == '/api/apply':
                draft = self.server.draft
                if draft is None or request.get('draftID') != draft[0]:
                    raise ValueError('請先重新預覽')
                self.server.draft = None
                backup = apply(self.server.root, draft[1], draft[2])
                self.send(200, {'backup': backup})
            else:
                self.send(404, {'error': '找不到操作'})
        except (ValueError, KeyError, OSError, Image.DecompressionBombError) as error:
            self.send(400, {'error': str(error)})


def main():
    """無參數開啟本機 UI；CLI 明確指定 --apply 才寫入正式資源。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source')
    parser.add_argument('--mode', choices=['lossless', 'colors256'], default='lossless')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--no-browser', action='store_true')
    parser.add_argument('--port', type=int, default=0)
    args = parser.parse_args()
    if args.source:
        output, details = generate(ROOT, args.source, args.mode)
        print(json.dumps({k: v for k, v in details.items() if k != 'preview'}, ensure_ascii=False, indent=2))
        if args.apply:
            print('已套用；舊檔備份：' + apply(ROOT, output, details))
        return
    if args.apply:
        parser.error('--apply 需要 --source')
    server = IconServer(ROOT, args.port)
    url = f'http://127.0.0.1:{server.server_port}/'
    print('App 圖示工具：' + url, flush=True)
    print('關閉此視窗或按 Ctrl+C 即停止服務。', flush=True)
    if not args.no_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
