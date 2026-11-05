"""裝置選擇回歸：新 runtime 或殘留裝置都不能繞過實際安裝狀態。"""
import unittest
from select_test_simulator import select_device

OLD = "EDEEE952-145B-48B2-BFB4-A31429F8FB04"
NEW = "4C56FCAC-377C-469C-B415-8ABBC4375CBA"
STALE = "0B0B0B0B-0000-0000-0000-000000000000"


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.devices = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                {"name": "iPhone 17", "udid": OLD, "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
                {"name": "iPhone 18", "udid": NEW, "isAvailable": True}]}}
        self.runtimes = {"runtimes": [
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
             "version": "27.0", "isAvailable": True, "platform": "iOS"},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1",
             "version": "27.1", "isAvailable": True, "platform": "iOS"}]}

    def test_newer_runtime_excluded_when_not_compatible(self):
        for heading in ['Available destinations for the "liveAPP" scheme:',
                        'Destinations compatible with the "liveAPP" scheme:']:
            text = heading + f"\n {{ platform:iOS Simulator, id:{OLD}, OS:27.0 }}"
            text += f"\nDestinations incompatible with the scheme:\n {{ platform:iOS Simulator, id:{NEW} }}"
            self.assertEqual(select_device(self.devices, text, self.runtimes)[3], OLD)

    def test_other_platform_and_placeholder_do_not_match(self):
        text = f"Available destinations for scheme:\n {{ platform:visionOS Simulator, id:{NEW} }}"
        text += "\n { platform:iOS Simulator, id:placeholder }"
        with self.assertRaises(ValueError):
            select_device(self.devices, text, self.runtimes)

    def test_unavailable_device_is_rejected(self):
        self.devices["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-27-0"][0]["isAvailable"] = False
        with self.assertRaises(ValueError):
            select_device(self.devices,
                          f"Available destinations for scheme:\n {{ platform:iOS Simulator, id:{OLD} }}",
                          self.runtimes)

    def test_missing_runtime_is_ignored_even_if_device_says_available(self):
        self.devices["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-27-2"] = [
            {"name": "iPhone Air", "udid": STALE, "isAvailable": True}]
        text = (f"Available destinations for scheme:\n {{ platform:iOS Simulator, id:{STALE}, OS:27.2 }}"
                f"\n {{ platform:iOS Simulator, id:{OLD}, OS:27.0 }}")
        self.assertEqual(select_device(self.devices, text, self.runtimes)[3], OLD)

    def test_sdk_matching_runtime_is_preferred(self):
        devices = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                {"name": "iPhone 17", "udid": OLD, "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
                {"name": "iPhone Air", "udid": STALE, "isAvailable": True}]}}
        runtimes = {"runtimes": [
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
             "version": "27.0", "isAvailable": True, "platform": "iOS"},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
             "version": "27.2", "isAvailable": True, "platform": "iOS"}]}
        text = (f"Available destinations for scheme:\n {{ platform:iOS Simulator, id:{OLD}, OS:27.0 }}"
                f"\n {{ platform:iOS Simulator, id:{STALE}, OS:27.2 }}")
        self.assertEqual(select_device(devices, text, runtimes, sdk_version="27.0")[3], OLD)
        self.assertEqual(select_device(devices, text, runtimes)[3], STALE)

    def test_runtime_with_missing_path_is_ignored(self):
        self.runtimes["runtimes"][1]["runtimeRoot"] = "/nonexistent/ReplyKit/iOS27.simruntime"
        text = (f"Available destinations for scheme:\n {{ platform:iOS Simulator, id:{OLD}, OS:27.0 }}"
                f"\n {{ platform:iOS Simulator, id:{NEW}, OS:27.1 }}")
        self.assertEqual(select_device(self.devices, text, self.runtimes)[3], OLD)

    def test_falls_back_to_newest_available_ios_runtime(self):
        runtimes = {"runtimes": [
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
             "version": "26.4", "isAvailable": True, "platform": "iOS"}]}
        devices = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
                {"name": "iPhone 16", "udid": OLD, "isAvailable": True}]}}
        self.assertEqual(select_device(devices,
                                       f"Available destinations for scheme:\n {{ platform:iOS Simulator, id:{OLD} }}",
                                       runtimes)[0], (26, 4))


if __name__ == "__main__":
    unittest.main()
