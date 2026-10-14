"""驗證 Swift Testing 問題、測試終態與 runner 逾時不混算。"""
import unittest
from ci_test_summary import parse, render_markdown


class SummaryTests(unittest.TestCase):
    def test_parameterized_issues_are_not_extra_failed_tests(self):
        log = """
✘ Test lateAudio(crossesBoundary:) recorded an issue with 1 argument crossesBoundary → false at SegmentedRecordingTests.swift:93:13: Expectation failed: abs(delta) < 0.1
↳ abs(delta) → 0.5
✘ Test lateAudio(crossesBoundary:) recorded an issue with 1 argument crossesBoundary → false at SegmentedRecordingTests.swift:93:13: Expectation failed: abs(delta) < 0.1
↳ abs(delta) → 59.5
✘ Test lateAudio(crossesBoundary:) recorded an issue with 1 argument crossesBoundary → true at SegmentedRecordingTests.swift:93:13: Expectation failed: abs(delta) < 0.1
↳ abs(delta) → 59.99
✘ Test lateAudio(crossesBoundary:) with 2 test cases failed after 0.507 seconds with 3 issues.
✘ Test run with 100 tests in 23 suites failed after 2.978 seconds with 3 issues.
Executed 0 tests, with 0 failures
"""
        result = parse(log)
        self.assertEqual(result["tests_failed"], ["lateAudio(crossesBoundary:)"])
        self.assertEqual(len(result["issues"]), 3)
        self.assertEqual(result["verdict"], "failed")
        markdown = render_markdown(result)
        self.assertIn("59.99", markdown)
        self.assertIn("crossesBoundary → true", markdown)
        self.assertNotIn("Executed 0 tests", markdown)
        self.assertEqual(result["errors"], [])

    def test_caught_error_is_a_test_issue_not_compile_error(self):
        result = parse("✘ Test slice() recorded an issue at Test.swift:4:2: Caught error: PCM failure")
        self.assertEqual(len(result["issues"]), 1)
        self.assertEqual(result["other_errors"], [])

    def test_runner_timeout_is_separate(self):
        result = parse("Failure collecting diagnostics from simulator: Timed out after 600.0 seconds")
        self.assertEqual(len(result["infrastructure"]), 1)
        self.assertEqual(result["tests_failed"], [])
        self.assertIn("Runner／診斷收集", render_markdown(result))
        self.assertIn("❌ 失敗", render_markdown(result))

    def test_overall_pass_is_not_a_test_function(self):
        result = parse("✔ Test example() passed after 0.1 seconds.\n✔ Test run with 1 test passed after 0.1 seconds.")
        self.assertEqual(result["tests_passed"], ["example()"])
        self.assertEqual(result["verdict"], "passed")
        self.assertIn("<details>", render_markdown(result))

    def test_compile_failure_keeps_file_location(self):
        result = parse("/repo/File.swift:54:56: error: missing argument label")
        self.assertEqual(result["errors"][0].line, "54")
        self.assertEqual(result["tests_failed"], [])

    def test_ansi_and_multiline_details(self):
        result = parse("\x1b[31m✘ Test example() recorded an issue at Test.swift:5:2: Expectation failed\x1b[0m\n↳ actualPTS=0\n    expectedPTS=59.5")
        self.assertIn("expectedPTS=59.5", render_markdown(result))


if __name__ == "__main__":
    unittest.main()
