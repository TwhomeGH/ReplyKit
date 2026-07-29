tmp = 'C:\\Users\\agp05\\AppData\\Local\\Temp\\ContentView.swift'
with open(tmp, 'r', encoding='utf-8') as f:
    c = f.read()

old = '''    private func resolveExtension() -> String? {
        // 1. 從 PlugIns 動態發現——只選 broadcast upload extension
        if let plugInsURL = Bundle.main.builtInPlugInsURL,
           let entries = try? FileManager.default.contentsOfDirectory(at: plugInsURL, includingPropertiesForKeys: nil) {
            let appexEntries = entries.filter { $0.pathExtension == "appex" }
            sendlog(title: "BroadcastButton", message: "Found \\(appexEntries.count) appex bundles in PlugIns")

            for entry in appexEntries {
                if let bundle = Bundle(url: entry), let bundleID = bundle.bundleIdentifier {
                    let isBroadcastUpload: Bool
                    if let extDict = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                       let pointID = extDict["NSExtensionPointIdentifier"] as? String {
                        isBroadcastUpload = (pointID == "com.apple.broadcast-services-upload")
                    } else {
                        isBroadcastUpload = false
                    }
                    sendlog(title: "BroadcastButton", message: "  \\(entry.lastPathComponent): bundleID=\\(bundleID) type=\\(isBroadcastUpload ? "broadcast-upload" : "other")")
                    if isBroadcastUpload {
                        sendlog(title: "BroadcastButton", message: "Selected broadcast upload extension: \\(bundleID)")
                        return bundleID
                    }
                }
            }
            sendlog(title: "BroadcastButton", message: "No broadcast upload extension found in PlugIns")
        } else {
            sendlog(title: "BroadcastButton", message: "No PlugIns directory or unable to read")
        }

        // 2. 使用使用者設定的值
        if !preferredExtension.isEmpty {
            sendlog(title: "BroadcastButton", message: "Fallback to user setting: '\\(preferredExtension)'")
            return preferredExtension
        } else {
            sendlog(title: "BroadcastButton", message: "preferredExtension is empty, skipping step 2")
        }

        // 3. 從主 App bundle ID 推測
        if let bundleID = Bundle.main.bundleIdentifier {
            let candidate = bundleID + ".ReplyKIT"
            sendlog(title: "BroadcastButton", message: "Fallback to constructed: \\(candidate)")
            return candidate
        }

        sendlog(title: "BroadcastButton", message: "Failed to resolve broadcast extension")
        return nil
    }'''

new = '''    private func resolveExtension() -> String? {
        Self.resolveCache
    }

    private static let resolveCache: String? = {
        if let plugInsURL = Bundle.main.builtInPlugInsURL,
           let entries = try? FileManager.default.contentsOfDirectory(at: plugInsURL, includingPropertiesForKeys: nil) {
            let appexEntries = entries.filter { $0.pathExtension == "appex" }
            sendlog(title: "BroadcastButton", message: "Found \\(appexEntries.count) appex bundles in PlugIns")
            for entry in appexEntries {
                if let bundle = Bundle(url: entry), let bundleID = bundle.bundleIdentifier {
                    let isBroadcastUpload: Bool
                    if let extDict = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                       let pointID = extDict["NSExtensionPointIdentifier"] as? String {
                        isBroadcastUpload = (pointID == "com.apple.broadcast-services-upload")
                    } else {
                        isBroadcastUpload = false
                    }
                    sendlog(title: "BroadcastButton", message: "  \\(entry.lastPathComponent): bundleID=\\(bundleID) type=\\(isBroadcastUpload ? "broadcast-upload" : "other")")
                    if isBroadcastUpload {
                        sendlog(title: "BroadcastButton", message: "Selected broadcast upload extension: \\(bundleID)")
                        return bundleID
                    }
                }
            }
            sendlog(title: "BroadcastButton", message: "No broadcast upload extension found in PlugIns")
        } else {
            sendlog(title: "BroadcastButton", message: "No PlugIns directory or unable to read")
        }
        if let bundleID = Bundle.main.bundleIdentifier {
            let candidate = bundleID + ".ReplyKIT"
            sendlog(title: "BroadcastButton", message: "Fallback to constructed: \\(candidate)")
            return candidate
        }
        sendlog(title: "BroadcastButton", message: "Failed to resolve broadcast extension")
        return nil
    }()'''

assert old in c, 'pattern not found'
c = c.replace(old, new, 1)

with open(tmp, 'w', encoding='utf-8') as f:
    f.write(c)
print('Patched temp file')
