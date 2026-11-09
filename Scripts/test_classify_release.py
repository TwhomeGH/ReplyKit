#!/usr/bin/env python3
"""Release classifier unit tests."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import classify_release as classifier


CONFIG = {
    "expWindowReleases": 5,
    "maxAreas": 3,
    "tiers": {
        "Core": ["liveAPP/Audio/**", "Package.resolved"],
        "UI": ["liveAPP/**/*View.swift", "liveAPP/Localizable.xcstrings"],
    },
    "areas": {
        "Audio": ["liveAPP/Audio/**"],
        "Video": ["liveAPP/Capture/**"],
        "RTMP": ["Package.resolved"],
        "PiP": ["liveAPP/PIP*.swift"],
    },
    "ignored": ["Docs/**", "*.md", "liveAPPTests/**"],
}


class ReleaseClassifierTests(unittest.TestCase):
    def test_paths_produce_tier_and_areas(self):
        result = classifier.classify_paths(
            ["liveAPP/Audio/LiveVolumeView.swift"],
            CONFIG,
        )
        self.assertIn("Core", result["tiers"])
        self.assertEqual(result["areas"], ["Audio"])
        self.assertIn("liveAPP/Audio/LiveVolumeView.swift", result["paths"])

    def test_ui_only_is_not_core(self):
        result = classifier.classify_paths(
            ["liveAPP/Settings/AppIconSettingsView.swift", "liveAPP/Localizable.xcstrings"],
            CONFIG,
        )
        self.assertNotIn("Core", result["tiers"])
        self.assertIn("UI", result["tiers"])

    def test_ignored_docs_do_not_affect_release(self):
        result = classifier.classify_paths(["Docs/ChangeHistory.md", "README.md"], CONFIG)
        self.assertEqual(result["tiers"], [])
        self.assertEqual(result["areas"], [])
        self.assertEqual(result["paths"], [])

    def test_exp_window_counts_current_and_previous_four(self):
        self.assertEqual(classifier.exp_window([True, False, False, False, False], 5), (True, 5))
        self.assertEqual(classifier.exp_window([False, False, False, False, True], 5), (True, 1))
        self.assertEqual(classifier.exp_window([False, False, False, False, False], 5), (False, 0))

    def test_name_is_built_from_parts(self):
        self.assertEqual(
            classifier.build_name(
                "17.5.5", ["Core"], ["Audio", "RTMP"], ["Exp"], 3),
            "17.5.5 · Core · Audio+RTMP · Exp",
        )

    def test_release_label_trailer(self):
        self.assertIn("Hotfix", classifier.labels_from_commits(
            "修正音訊\n\nRelease-Label: Hotfix\n"))
        self.assertIn("Major", classifier.labels_from_commits(
            "Release-Label: Major, UIFix\n"))

    def test_integration_uses_tag_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=root, check=True)
            (root / "README.md").write_text("first\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "init"], cwd=root, check=True)
            subprocess.run(["git", "tag", "17.5.0"], cwd=root, check=True)

            (root / "liveAPP").mkdir()
            (root / "liveAPP" / "Audio").mkdir()
            (root / "liveAPP" / "Audio" / "Voice.swift").write_text("// fix\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "fix: audio"], cwd=root, check=True)
            subprocess.run(["git", "tag", "17.5.1"], cwd=root, check=True)

            result = classifier.classify(root, "17.5.1", CONFIG, 5)
            self.assertEqual(result["labels"][:2], ["Core", "Audio"])
            self.assertIn("Exp", result["labels"])
            self.assertTrue(result["name"].startswith("17.5.1 · Core · Audio"))


if __name__ == "__main__":
    unittest.main()
