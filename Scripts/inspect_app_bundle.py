"""檢查 .app 或 IPA 的替換圖示宣告，並列出實際包體組成；不修改產物。"""
import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import plistlib
import zipfile


def inspect(path):
    """回傳產物檔案大小與 plist；IPA 只讀 ZIP，不解壓不執行內容。"""
    path = Path(path)
    if path.is_dir():
        entries = {p.relative_to(path).as_posix(): (p.stat().st_size, None)
                   for p in path.rglob('*') if p.is_file() and not p.is_symlink()}
        info = plistlib.loads((path / 'Info.plist').read_bytes())
        archive_size = None
    else:
        with zipfile.ZipFile(path) as archive:
            roots = [n for n in archive.namelist()
                     if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
            if len(roots) != 1:
                raise ValueError('IPA 必須包含唯一主 App Info.plist')
            root = roots[0][:-len('Info.plist')]
            info = plistlib.loads(archive.read(roots[0]))
            entries = {item.filename[len(root):]: (item.file_size, item.compress_size)
                       for item in archive.infolist() if item.filename.startswith(root) and not item.is_dir()}
        archive_size = path.stat().st_size
    return info, entries, archive_size


def check_icons(info, entries):
    """驗證 iPhone／iPad 宣告與可見資源；Assets.car 存在不等於已驗證其內部圖示。"""
    errors, declarations = [], {}
    families = info.get('UIDeviceFamily', [1, 2])
    for family, key in [(1, 'CFBundleIcons'), (2, 'CFBundleIcons~ipad')]:
        if family not in families:
            continue
        icons = info.get(key, {})
        alternate = icons.get('CFBundleAlternateIcons', {}) if isinstance(icons, dict) else {}
        declarations[key] = alternate
        entry = alternate.get('PersonalIcon') if isinstance(alternate, dict) else None
        if not isinstance(entry, dict) or not entry:
            errors.append(key + ' 缺少 PersonalIcon 宣告')
            continue
        names = entry.get('CFBundleIconFiles', [])
        icon_name = entry.get('CFBundleIconName')
        if names:
            for name in names:
                stem = str(name).removesuffix('.png')
                if not any('/' not in file and (file == stem + '.png' or file.startswith(stem + '@')
                                                or file.startswith(stem + '~')) for file in entries):
                    errors.append(key + ' 找不到圖示檔案：' + str(name))
        elif icon_name:
            # asset catalog 的標準產物：圖示編進 Assets.car，Info.plist 使用
            # CFBundleIconName，不會產生 PersonalIcon 的獨立 PNG。
            if 'Assets.car' not in entries:
                errors.append(key + ' 使用 CFBundleIconName 但找不到 Assets.car')
        else:
            errors.append(key + ' 缺少 CFBundleIconName 或 CFBundleIconFiles')
    return errors, declarations


def category(name, executable):
    """互斥分類，避免擴展內資源重複計入主 App。"""
    if name.startswith('PlugIns/'):
        return '擴展/' + name.split('/')[1]
    if name.startswith('Frameworks/'):
        return 'Frameworks/' + name.split('/')[1]
    if name == executable:
        return '主 App 執行檔（含靜態連結程式碼）'
    if name == 'Assets.car':
        return '主 App 資源目錄 Assets.car（無法僅按檔案拆出個別圖示）'
    if name.lower().endswith('.png'):
        return '主 App 獨立 PNG／圖示'
    if name.lower().endswith(('.py', '.bak', '.edit', '.swift', '.new')):
        return '疑似開發用檔案'
    return '其他資源／中繼資料／簽章'


def report(path):
    """產生可供 CI 分享的結構化報告，保留精確 bytes 與 ZIP 欄位。"""
    info, entries, archive_size = inspect(path)
    errors, icons = check_icons(info, entries)
    groups = defaultdict(lambda: {'bytes': 0, 'zipBytes': 0})
    for name, (size, compressed) in entries.items():
        group = groups[category(name, info.get('CFBundleExecutable', ''))]
        group['bytes'] += size
        group['zipBytes'] += compressed or 0
    return {'input': str(path), 'bundleID': info.get('CFBundleIdentifier'),
            'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'),
            'ipaBytes': archive_size, 'appBytes': sum(x[0] for x in entries.values()),
            'icons': icons, 'errors': errors, 'groups': dict(groups),
            'largestFiles': [{'path': name, 'bytes': size, 'zipBytes': compressed}
                             for name, (size, compressed) in sorted(entries.items(), key=lambda x: x[1][0], reverse=True)[:30]]}


def markdown(result):
    """以十進位 MB 顯示，明確區分壓縮下載量與檔案邏輯大小。"""
    def mb(n):
        return '未提供' if n is None else f'{n / 1_000_000:.3f} MB'
    lines = ['## App 圖示與包體檢查', '',
             f"- Bundle：{result['bundleID']}；版本：{result['version']} ({result['build']})",
             f"- IPA ZIP 大小：{mb(result['ipaBytes'])}",
             f"- 主 App 目錄檔案加總（含擴展）：{mb(result['appBytes'])}",
             '- 此加總不是 iOS 設定頁的實際占用，也不含使用者文件／快取。',
             '- Assets.car 內含多種編譯資源；不能將整個檔案直接算成新增圖示。', '',
             '### 圖示宣告', '', '```json', json.dumps(result['icons'], ensure_ascii=False, indent=2), '```', '']
    lines += ['- ❌ ' + e for e in result['errors']] or ['- 宣告與可見資源檢查通過；仍需實機切換驗證。']
    lines += ['', '| 分類 | 檔案大小 | ZIP 壓縮大小 |', '| ------ | ------ | ------ |']
    for name, sizes in sorted(result['groups'].items(), key=lambda x: x[1]['bytes'], reverse=True):
        lines.append(f"| {name} | {mb(sizes['bytes'])} | {mb(sizes['zipBytes']) if result['ipaBytes'] is not None else '未提供'} |")
    lines += ['', '### 最大檔案', '', '| 路徑 | 檔案大小 | ZIP 壓縮大小 |', '| ------ | ------ | ------ |']
    for item in result['largestFiles']:
        lines.append(f"| {item['path']} | {mb(item['bytes'])} | {mb(item['zipBytes'])} |")
    return '\n'.join(lines) + '\n'


def main():
    """CI 宣告缺失時失敗，同時保留診斷；也可離線檢查重簽後的 IPA。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--github-summary', action='store_true')
    args = parser.parse_args()
    result = report(args.input)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.with_suffix('.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    content = markdown(result)
    args.output.write_text(content, encoding='utf-8')
    if args.github_summary and os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as stream:
            stream.write(content)
    print('圖示檢查：' + ('失敗' if result['errors'] else '通過') + '；報告：' + str(args.output))
    return 1 if result['errors'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
