import sys
import unittest
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


if __name__ == "__main__":
    unittest.main()
