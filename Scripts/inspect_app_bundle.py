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


SUSPICIOUS_SUFFIXES = (
    '.py', '.pyc', '.bak', '.edit', '.swift', '.new', '.md', '.sh', '.command',
    '.orig', '.rej', '.tmp', '.entitlements', '.xcconfig')

def suspicious_reason(name):
    """回傳可疑原因；一般 JSON／plist／lproj／圖片不在此列。"""
    base = name.rsplit('/', 1)[-1]
    if base.startswith('.'):
        return 'dotfile'
    if name.lower().endswith(SUSPICIOUS_SUFFIXES):
        return 'dev/source'
    return None


def content_report(entries, expected_exclusions):
    """列出實際出現的可疑檔，以及預期排除清單中仍存在／已消失的項目。"""
    suspicious = [{'path': name, 'bytes': size, 'reason': suspicious_reason(name)}
                  for name, (size, compressed) in sorted(entries.items())
                  if suspicious_reason(name)]
    exclusions = None
    if expected_exclusions:
        expected = list(dict.fromkeys(expected_exclusions))
        names = {name.rsplit('/', 1)[-1] for name in entries}
        included = [name for name in expected if name in names]
        excluded = [name for name in expected if name not in names]
        exclusions = {'expected': expected, 'included': included, 'excluded': excluded}
    return suspicious, exclusions


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
    if suspicious_reason(name):
        return '疑似開發用檔案'
    return '其他資源／中繼資料／簽章'


def report(path, expected_exclusions=None):
    """產生可供 CI 分享的結構化報告，保留精確 bytes 與 ZIP 欄位。"""
    info, entries, archive_size = inspect(path)
    errors, icons = check_icons(info, entries)
    suspicious, exclusions = content_report(entries, expected_exclusions)
    if suspicious:
        errors.append('發現疑似開發／無關檔案：' + '、'.join(item['path'] for item in suspicious))
    if exclusions and exclusions['included']:
        errors.append('預期排除但仍包含：' + '、'.join(exclusions['included']))
    groups = defaultdict(lambda: {'bytes': 0, 'zipBytes': 0})
    for name, (size, compressed) in entries.items():
        group = groups[category(name, info.get('CFBundleExecutable', ''))]
        group['bytes'] += size
        group['zipBytes'] += compressed or 0
    return {'input': str(path), 'bundleID': info.get('CFBundleIdentifier'),
            'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'),
            'ipaBytes': archive_size, 'appBytes': sum(x[0] for x in entries.values()),
            'icons': icons, 'errors': errors, 'groups': dict(groups),
            'suspicious': suspicious, 'exclusions': exclusions,
            'largestFiles': [{'path': name, 'bytes': size, 'zipBytes': compressed}
                             for name, (size, compressed) in sorted(entries.items(), key=lambda x: x[1][0], reverse=True)[:30]]}


def markdown(result):
    """以十進位 MB 顯示；ZIP 只提供整包 IPA 大小，不捏造逐檔下載量。"""
    def mb(n):
        return '未提供' if n is None else f'{n / 1_000_000:.3f} MB'
    has_zip = result['ipaBytes'] is not None
    lines = ['## App 圖示與包體檢查', '',
             f"- Bundle：{result['bundleID']}；版本：{result['version']} ({result['build']})"]
    lines.append(f"- IPA ZIP 大小：{mb(result['ipaBytes'])}" if has_zip
                 else '- 檢查來源：封存 .app（沒有 IPA ZIP；不列逐檔壓縮量）')
    lines += [f"- 主 App 目錄檔案加總（含擴展）：{mb(result['appBytes'])}",
              '- 此加總不是 iOS 設定頁的實際占用，也不含使用者文件／快取。',
              '- Assets.car 內含多種編譯資源；不能將整個檔案直接算成新增圖示。']
    if has_zip:
        lines.append('- ZIP 大小只代表整包 IPA 的下載／儲存大小；逐檔壓縮量不等於下載量。')
    lines += ['', '### 圖示宣告', '', '```json', json.dumps(result['icons'], ensure_ascii=False, indent=2), '```', '']
    lines += ['- ❌ ' + e for e in result['errors']] or ['- 圖示宣告與套件內容檢查通過；仍需實機切換驗證。']

    lines += ['', '### 套件內容', '']
    if result['suspicious']:
        lines += ['| 路徑 | 大小 | 原因 |', '| ------ | ------ | ------ |']
        for item in result['suspicious']:
            lines.append(f"| `{item['path']}` | {mb(item['bytes'])} | {item['reason']} |")
    else:
        lines.append('- 未發現 `.py`／`.bak`／`.edit`／`.swift`／`.new`／dotfile 等開發用檔案。')

    exclusions = result.get('exclusions')
    if exclusions:
        lines += ['', '### 預期排除清單', '',
                  f"- 已排除 {len(exclusions['excluded'])}／{len(exclusions['expected'])}。",
                  '| 檔案 | 狀態 |', '| ------ | ------ |']
        for name in exclusions['expected']:
            status = '❌ 仍包含' if name in exclusions['included'] else '✅ 已排除'
            lines.append(f"| `{name}` | {status} |")

    lines += ['', '### 分類', '', '| 分類 | 檔案大小 |', '| ------ | ------ |']
    for name, sizes in sorted(result['groups'].items(), key=lambda x: x[1]['bytes'], reverse=True):
        lines.append(f"| {name} | {mb(sizes['bytes'])} |")
    lines += ['', '### 最大檔案', '', '| 路徑 | 檔案大小 |', '| ------ | ------ |']
    for item in result['largestFiles']:
        lines.append(f"| `{item['path']}` | {mb(item['bytes'])} |")
    return '\n'.join(lines) + '\n'


def main():
    """CI 宣告缺失時失敗，同時保留診斷；也可離線檢查重簽後的 IPA。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--github-summary', action='store_true')
    parser.add_argument('--expect-excluded', type=Path,
                        help='預期不應出現在產物中的檔名清單，一行一項')
    args = parser.parse_args()
    expected = None
    if args.expect_excluded:
        expected = [line.strip() for line in args.expect_excluded.read_text(encoding='utf-8').splitlines()
                    if line.strip() and not line.lstrip().startswith('#')]
    result = report(args.input, expected)
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
