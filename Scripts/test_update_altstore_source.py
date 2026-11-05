"""AltStore 來源更新：版本鍵去重、上限與欄位保留。"""
import json
import tempfile
import unittest
from pathlib import Path

from update_altstore_source import main, make_entry, update_source


def sample_source():
    return {
        "name": "松鼠推流",
        "apps": [{
            "bundleIdentifier": "nuclear.liveAPP",
            "localizedDescription": "app",
            "versions": [{
                "downloadURL": "https://example/old.ipa",
                "size": 1,
                "version": "17.2.2",
                "buildVersion": "2026100601",
                "date": "2026-10-06T04:00:00+08:00",
                "minOSVersion": "16.0",
            }],
        }],
    }


class AltStoreSourceTests(unittest.TestCase):
    def test_new_version_is_prepended_and_keeps_other_fields(self):
        source = sample_source()
        entry = make_entry(tag="17.3.0", version="17.3.0", build="2026110101",
                           size=123, repo="o/r", date="2026-11-01T00:00:00+08:00",
                           min_os="16.0")
        update_source(source, bundle_id="nuclear.liveAPP", entry=entry, max_versions=10)
        versions = source["apps"][0]["versions"]
        self.assertEqual(versions[0]["downloadURL"],
                         "https://github.com/o/r/releases/download/17.3.0/liveApp_17.3.0.ipa")
        self.assertEqual(versions[0]["size"], 123)
        self.assertEqual(versions[0]["localizedDescription"], "app")
        self.assertEqual(versions[1]["version"], "17.2.2")
        self.assertEqual(source["name"], "松鼠推流")

    def test_same_version_and_build_replaces_instead_of_duplicating(self):
        source = sample_source()
        entry = make_entry(tag="17.2.4", version="17.2.2", build="2026100601",
                           size=999, repo="o/r", date="2026-11-02T00:00:00+08:00",
                           min_os="16.0")
        update_source(source, bundle_id="nuclear.liveAPP", entry=entry, max_versions=10)
        versions = source["apps"][0]["versions"]
        self.assertEqual(len(versions), 1)
        self.assertEqual(versions[0]["size"], 999)
        self.assertIn("17.2.4", versions[0]["downloadURL"])

    def test_versions_are_capped(self):
        source = sample_source()
        for index in range(15):
            entry = make_entry(tag=f"17.9.{index}", version=f"17.9.{index}",
                               build=f"2026{index:02d}01", size=1, repo="o/r",
                               date="2026-11-01T00:00:00+08:00", min_os="16.0")
            update_source(source, bundle_id="nuclear.liveAPP", entry=entry,
                          max_versions=5)
        self.assertEqual(len(source["apps"][0]["versions"]), 5)

    def test_output_copy_leaves_template_untouched(self):
        source = sample_source()
        original = json.dumps(source, ensure_ascii=False, indent=2) + "\n"
        with tempfile.TemporaryDirectory() as folder:
            template = Path(folder) / "AltStoreTest.json"
            output = Path(folder) / "build" / "AltStoreTest.json"
            template.write_text(original, encoding="utf-8")
            code = main([
                "--path", str(template), "--output", str(output),
                "--tag", "17.3.0", "--version", "17.3.0", "--build", "2",
                "--size", "1", "--repo", "o/r",
                "--date", "2026-01-01T00:00:00+08:00",
            ])
            self.assertEqual(code, 0)
            self.assertEqual(template.read_text(encoding="utf-8"), original)
            composed = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(composed["apps"][0]["versions"][0]["version"], "17.3.0")

    def test_older_release_is_ignored(self):
        source = sample_source()
        source["apps"][0]["versions"][0]["downloadURL"] = (
            "https://github.com/o/r/releases/download/17.3.0/liveApp_17.3.0.ipa")
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "AltStoreTest.json"
            path.write_text(json.dumps(source), encoding="utf-8")
            code = main([
                "--path", str(path), "--tag", "17.2.9",
                "--version", "1", "--build", "1", "--size", "1",
                "--repo", "o/r", "--date", "2026-01-01T00:00:00+08:00",
            ])
            self.assertEqual(code, 0)
            after = json.loads(path.read_text(encoding="utf-8"))
            self.assertIn("17.3.0",
                          after["apps"][0]["versions"][0]["downloadURL"])

    def test_missing_bundle_identifier_fails(self):
        source = sample_source()
        entry = make_entry(tag="17.3.0", version="17.3.0", build="1", size=1,
                           repo="o/r", date="2026-11-01T00:00:00+08:00", min_os="16.0")
        with self.assertRaises(ValueError):
            update_source(source, bundle_id="other.app", entry=entry, max_versions=10)


if __name__ == "__main__":
    unittest.main()
