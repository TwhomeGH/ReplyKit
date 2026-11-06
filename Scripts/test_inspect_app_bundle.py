"""使用合成 IPA 驗證宣告檢查與 ZIP 大小統計，不依賴 Xcode。"""
import plistlib
from pathlib import Path
import tempfile
import unittest
import zipfile

from inspect_app_bundle import (check_icons, content_report, report,
                                suspicious_reason)


class BundleReportTests(unittest.TestCase):
    def make_ipa(self, root, pad=True, resource=True):
        """建立雙裝置宣告，模擬簽署工具遺漏 iPad 分支或資源的產物。"""
        icons = {'CFBundleAlternateIcons': {'PersonalIcon': {'CFBundleIconFiles': ['PersonalIcon60x60']}}}
        info = {'CFBundleIdentifier': 'test.app', 'CFBundleExecutable': 'App',
                'UIDeviceFamily': [1, 2], 'CFBundleIcons': icons}
        if pad:
            info['CFBundleIcons~ipad'] = icons
        path = Path(root) / 'app.ipa'
        with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('Payload/App.app/Info.plist', plistlib.dumps(info))
            archive.writestr('Payload/App.app/App', b'program' * 100)
            archive.writestr('Payload/App.app/PlugIns/Extension.appex/Extension', b'extension')
            if resource:
                archive.writestr('Payload/App.app/PersonalIcon60x60@2x.png', b'png')
        return path

    def test_valid_ipa_and_sizes(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.make_ipa(root)
            result = report(path)
            self.assertEqual(result['errors'], [])
            self.assertEqual(result['ipaBytes'], path.stat().st_size)
            self.assertEqual(sum(x['bytes'] for x in result['groups'].values()), result['appBytes'])
            self.assertEqual(result['groups']['擴展/Extension.appex']['bytes'], 9)

    def test_missing_ipad_declaration(self):
        with tempfile.TemporaryDirectory() as root:
            result = report(self.make_ipa(root, pad=False))
            self.assertTrue(any('CFBundleIcons~ipad' in error for error in result['errors']))

    def test_missing_png(self):
        with tempfile.TemporaryDirectory() as root:
            result = report(self.make_ipa(root, resource=False))
            self.assertTrue(any('找不到圖示檔案' in error for error in result['errors']))

    def test_suspicious_file_detection(self):
        self.assertEqual(suspicious_reason('_fix_video.py'), 'dev/source')
        self.assertEqual(suspicious_reason('PlugIns/ReplyKIT.appex/AudioProcess.swift.new'), 'dev/source')
        self.assertEqual(suspicious_reason('.last_build'), 'dotfile')
        self.assertIsNone(suspicious_reason('Assets.car'))
        self.assertIsNone(suspicious_reason('RTMPPresets.json'))

    def test_expected_exclusions_report_included_and_excluded(self):
        suspicious, exclusions = content_report({
            'PlugIns/ReplyKIT.appex/AudioProcess.swift.new': (10, None),
            'Assets.car': (100, 80),
        }, ['AudioProcess.swift.new', 'PIPContent.swift.bak'])
        self.assertEqual([item['path'] for item in suspicious],
                         ['PlugIns/ReplyKIT.appex/AudioProcess.swift.new'])
        self.assertEqual(exclusions['included'], ['AudioProcess.swift.new'])
        self.assertEqual(exclusions['excluded'], ['PIPContent.swift.bak'])

    def test_name_only_catalog_with_assets_passes(self):
        icons = {'CFBundleAlternateIcons': {'PersonalIcon': {'CFBundleIconName': 'PersonalIcon'}}}
        errors, _ = check_icons({'UIDeviceFamily': [1, 2], 'CFBundleIcons': icons,
                                'CFBundleIcons~ipad': icons}, {'Assets.car': (100, 80)})
        self.assertEqual(errors, [])

    def test_name_only_catalog_without_assets_fails(self):
        icons = {'CFBundleAlternateIcons': {'PersonalIcon': {'CFBundleIconName': 'PersonalIcon'}}}
        errors, _ = check_icons({'UIDeviceFamily': [1, 2], 'CFBundleIcons': icons,
                                'CFBundleIcons~ipad': icons}, {})
        self.assertEqual(len(errors), 2)
        self.assertTrue(all('Assets.car' in error for error in errors))


if __name__ == '__main__':
    unittest.main()
