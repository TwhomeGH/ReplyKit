import sys
import unittest
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import diagnostic_viewer as viewer


class DiagnosticViewerTests(unittest.TestCase):
    def parse(self, lines):
        return [viewer.parse_line(index + 1, line) for index, line in enumerate(lines)]

    def test_splits_category_session_and_fields(self):
        line = viewer.parse_line(
            1,
            "2026/11/13 中午12:29:30: liveApp:[AVLag] "
            "session=C3EE5722-74BF-4529-A5AE-8E5B1CB27D98 "
            "sourcePTSDelta=-0.062865 syncState=drifting frames=510345/445933",
        )
        self.assertEqual(line.category, "AVLag")
        self.assertEqual(line.session, "C3EE5722-74BF-4529-A5AE-8E5B1CB27D98")
        self.assertEqual(line.severity, "warn")
        self.assertEqual(line.fields["sourcePTSDelta"], "-0.062865")
        self.assertEqual(line.fields["syncState"], "drifting")

    def test_zero_failures_are_not_errors(self):
        line = viewer.parse_line(
            1,
            "2026/11/13 中午12:29:30: liveApp:[CaptureVideoProcessing] "
            "attempts=510345 processed=510345 failed=0 lastError=none",
        )
        self.assertEqual(line.severity, "info")

    def test_nonzero_errors_are_errors(self):
        line = viewer.parse_line(
            1,
            "2026/11/13 下午2:58:17: liveApp:[CaptureTransport] "
            "Reconnect attempt failed attempt 1/5 error=endOfStream",
        )
        self.assertEqual(line.severity, "error")

    def test_cumulative_dropped_counter_does_not_mark_every_line(self):
        line = viewer.parse_line(
            1,
            "2026/11/13 中午12:29:30: liveApp:[CaptureSource] "
            "capturePhase=streaming publishPhase=published "
            "video{accepted=170425 dropped=1 queued=0}",
        )
        self.assertEqual(line.severity, "info")

    def test_summary_counts_categories_and_sessions(self):
        lines = self.parse([
            "2026/11/13 中午12:29:30: liveApp:[AVLag] session=C3EE sourcePTSDelta=0",
            "2026/11/13 中午12:29:31: liveApp:[Memory] footprint=1",
            "2026/11/13 中午12:29:32: liveApp:[AVLag] session=C3EE syncState=drifting",
        ])
        summary = viewer.summarize(Path("sample.txt"), lines)
        self.assertEqual(summary["lines"], 3)
        self.assertEqual(summary["warn"], 1)
        self.assertEqual(summary["sessions"], ["C3EE"])
        self.assertEqual(summary["categories"][0]["name"], "AVLag")
        self.assertIsNotNone(summary["latest"])
        self.assertEqual(summary["latestTime"], "2026/11/13 中午12:29:32")

    def test_chinese_day_periods_parse_to_expected_hour(self):
        cases = {
            "2026/11/26 晚上9:35:11": 21,
            "2026/11/26 清晨5:59:43": 5,
            "2026/11/26 中午12:00:00": 12,
            "2026/11/26 下午5:00:00": 17,
            "2026/11/26 凌晨12:00:00": 0,
        }
        for text, expected in cases.items():
            epoch_ms = viewer.parse_local_timestamp(text)
            self.assertIsNotNone(epoch_ms, text)
            self.assertEqual(
                datetime.fromtimestamp(epoch_ms / 1000).hour,
                expected,
                text,
            )

    def test_time_range_excludes_lines_without_timestamp(self):
        lines = self.parse([
            "2026/11/26 晚上9:00:00: liveApp:[A] first",
            "2026/11/26 晚上9:30:00: liveApp:[A] second",
            "liveApp:[A] no timestamp",
        ])
        start = viewer.parse_local_timestamp("2026/11/26 晚上9:15:00")
        matched = viewer.filter_indices(lines, from_ms=start)
        self.assertEqual(matched, [1])

    def fake_lines(self, count=6):
        return [viewer.LogLine(i + 1, "t", "Other", "info", None, f"m{i}")
                for i in range(count)]

    def test_context_is_deduped_and_match_flag_is_explicit(self):
        lines = self.fake_lines()
        page = viewer.page_with_context(lines, [1, 2], 0, 2, 1)
        self.assertEqual([line.number for line, _ in page], [1, 2, 3, 4])
        self.assertEqual([is_match for _, is_match in page], [False, True, True, False])

    def test_context_respects_file_boundaries(self):
        lines = self.fake_lines()
        page = viewer.page_with_context(lines, [0, 5], 0, 2, 1)
        self.assertEqual([line.number for line, _ in page], [1, 2, 5, 6])

    def test_context_zero_returns_only_matches(self):
        lines = self.fake_lines()
        page = viewer.page_with_context(lines, [1, 4], 0, 1, 0)
        self.assertEqual([line.number for line, _ in page], [2])
        self.assertTrue(page[0][1])

    def test_context_respects_descending_order(self):
        lines = self.fake_lines()
        page = viewer.page_with_context(lines, [1, 2], 0, 1, 1, "desc")
        self.assertEqual([line.number for line, _ in page], [3, 2, 1])


if __name__ == "__main__":
    unittest.main()
