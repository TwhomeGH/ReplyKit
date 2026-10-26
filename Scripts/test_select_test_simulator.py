"""裝置選擇回歸：新 runtime 不代表 scheme 可測試。"""
import unittest
from select_test_simulator import select_device

OLD = "EDEEE952-145B-48B2-BFB4-A31429F8FB04"
NEW = "4C56FCAC-377C-469C-B415-8ABBC4375CBA"


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.devices = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                {"name": "iPhone 17", "udid": OLD, "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
                {"name": "iPhone 18", "udid": NEW, "isAvailable": True}]}}

    def test_newer_runtime_excluded_when_not_compatible(self):
        for heading in ['Available destinations for the "liveAPP" scheme:',
                        'Destinations compatible with the "liveAPP" scheme:']:
            text = heading + f"\n {{ platform:iOS Simulator, id:{OLD}, OS:27.0 }}"
            text += f"\nDestinations incompatible with the scheme:\n {{ platform:iOS Simulator, id:{NEW} }}"
            self.assertEqual(select_device(self.devices, text)[3], OLD)

    def test_other_platform_and_placeholder_do_not_match(self):
        text = f"Available destinations for scheme:\n {{ platform:visionOS Simulator, id:{NEW} }}"
        text += "\n { platform:iOS Simulator, id:placeholder }"
        with self.assertRaises(ValueError):
            select_device(self.devices, text)

    def test_unavailable_device_is_rejected(self):
        self.devices["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-27-0"][0]["isAvailable"] = False
        with self.assertRaises(ValueError):
            select_device(self.devices, f"Available destinations for scheme:\n {{ platform:iOS Simulator, id:{OLD} }}")


if __name__ == "__main__":
    unittest.main()
