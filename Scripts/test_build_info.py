import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import build_info


class BuildInfoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="build-info-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "app"
        self.root.mkdir()

    def lock(self, revision="a" * 40):
        path = self.root / build_info.LOCK_PATH
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"version": 3, "pins": [{"identity": "haishinkitfixswfit", "state": {"revision": revision}}]}), encoding="utf-8")

    def test_missing_source_is_unknown_not_ci_sha(self):
        info = build_info.collect(self.root, {"GITHUB_SHA": "wrong-event-sha", "GITHUB_ACTIONS": "true", "GITHUB_RUN_ID": "42"})
        self.assertIsNone(info["appRevision"])
        self.assertIsNone(info["appDirty"])
        self.assertIsNone(info["appUntrackedCount"])
        self.assertIsNone(info["appModifiedCount"])
        self.assertEqual(info["ciRun"], "42")
        self.assertEqual(info["haishinVerification"], "missing")

    def test_project_lock_wins_over_root_lock(self):
        self.lock()
        (self.root / "Package.resolved").write_text("{}", encoding="utf-8")
        info = build_info.collect(self.root, {})
        self.assertEqual(info["haishinRevision"], "a" * 40)
        self.assertEqual(info["haishinVerification"], "unverified")

    def test_matching_and_modified_checkout_are_distinct(self):
        self.lock()
        packages = Path(self.temp.name) / "packages"
        checkout = packages / "checkouts" / "HaishinKitFixSwfit"
        checkout.mkdir(parents=True)
        with patch.object(build_info, "snapshot", side_effect=[("b" * 40, False, 0, 0), ("a" * 40, True, 1, 0)]):
            info = build_info.collect(self.root, {"BUILD_INFO_PACKAGES_DIR": str(packages)})
        self.assertEqual(info["haishinVerification"], "matched")
        self.assertTrue(info["haishinCheckoutDirty"])
        self.assertEqual(info["haishinCheckoutUntrackedCount"], 1)
        self.assertEqual(info["haishinCheckoutModifiedCount"], 0)

    def test_mismatch_is_not_reported_as_verified(self):
        self.lock()
        packages = Path(self.temp.name) / "packages"
        (packages / "checkouts" / "HaishinKitFixSwfit").mkdir(parents=True)
        with patch.object(build_info, "snapshot", side_effect=[("b" * 40, False, 0, 0), ("c" * 40, False, 0, 0)]):
            info = build_info.collect(self.root, {"BUILD_INFO_PACKAGES_DIR": str(packages)})
        self.assertEqual(info["haishinVerification"], "mismatch")
        self.assertEqual(info["haishinCheckoutRevision"], "c" * 40)

    def test_real_git_dirty_and_nested_nonrepository(self):
        def git(*args):
            subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)
        git("init")
        git("-c", "user.name=BuildInfo Test", "-c", "user.email=build-info@example.invalid", "commit", "--allow-empty", "-m", "fixture")
        revision, dirty, untracked, modified = build_info.snapshot(self.root)
        self.assertEqual(len(revision), 40)
        self.assertFalse(dirty)
        self.assertEqual((untracked, modified), (0, 0))
        (self.root / "untracked.txt").write_text("test", encoding="utf-8")
        after = build_info.snapshot(self.root)
        self.assertTrue(after[1])
        self.assertEqual((after[2], after[3]), (1, 0))
        nested = self.root / "nested"
        nested.mkdir()
        self.assertEqual(build_info.snapshot(nested), (None, None, None, None))

    def test_malformed_lock_and_distinct_build_ids(self):
        self.lock()
        (self.root / build_info.LOCK_PATH).write_text("not json", encoding="utf-8")
        first = build_info.collect(self.root, {})
        second = build_info.collect(self.root, {})
        self.assertEqual(first["haishinVerification"], "missing")
        self.assertNotEqual(first["buildID"], second["buildID"])
        self.assertTrue(first["builtAt"].endswith("+00:00"))


if __name__ == "__main__":
    unittest.main()
