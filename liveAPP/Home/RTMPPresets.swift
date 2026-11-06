import Combine
import Foundation

/// 快速選擇的 RTMP 網址樣本；只含端點，不儲存串流金鑰。
struct RTMPPreset: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var rtmpURL: String
    var note: String?
}

/// 內建樣本唯讀、使用者樣本另存；匯入匯出都只處理 URL。
final class RTMPPresetStore: ObservableObject {
    static let userDefaultsKey = "rtmpUserPresets"
    static let maxUserPresets = 50

    private struct PresetFile: Codable {
        var version: Int
        var presets: [RTMPPreset]
    }

    struct ImportResult {
        var added: Int
        var skipped: Int
    }

    let builtIn: [RTMPPreset]
    @Published private(set) var userPresets: [RTMPPreset] = []

    private let defaults: UserDefaults
    private let bundle: Bundle

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
        builtIn = Self.loadBuiltIn(bundle: bundle)
        userPresets = Self.loadUser(defaults: defaults)
    }

    /// 允許 rtmp／rtmps 與非空主機；名稱、網址與備註都有長度上限。
    static func validated(_ preset: RTMPPreset, requireID: Bool) -> RTMPPreset? {
        let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = preset.rtmpURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, url.count <= 2048,
              let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              ["rtmp", "rtmps"].contains(scheme),
              let host = components.host, !host.isEmpty else { return nil }
        let id = preset.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requireID || !id.isEmpty else { return nil }
        let note = preset.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RTMPPreset(
            id: id.isEmpty ? "user.\(UUID().uuidString)" : id,
            name: name,
            rtmpURL: url,
            note: note?.isEmpty == true ? nil : note)
    }

    /// 加入目前輸入的網址；重複的名稱＋網址直接拒絕。
    @discardableResult
    func addUserPreset(name: String, rtmpURL: String, note: String? = nil) -> Bool {
        guard userPresets.count < Self.maxUserPresets else { return false }
        let candidate = RTMPPreset(id: "user.\(UUID().uuidString)", name: name,
                                   rtmpURL: rtmpURL, note: note)
        guard let valid = Self.validated(candidate, requireID: true) else { return false }
        let key = Self.identity(valid)
        guard !userPresets.contains(where: { Self.identity($0) == key }) else { return false }
        userPresets.append(valid)
        saveUser()
        return true
    }

    func removeUserPreset(_ preset: RTMPPreset) {
        userPresets.removeAll { $0.id == preset.id }
        saveUser()
    }

    /// 就地更新名稱與網址；保留原 id 與備註，重複或無效時不改資料。
    @discardableResult
    func updateUserPreset(id: String, name: String, rtmpURL: String) -> RTMPPreset? {
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else { return nil }
        var candidate = userPresets[index]
        candidate.name = name
        candidate.rtmpURL = rtmpURL
        guard let valid = Self.validated(candidate, requireID: true) else { return nil }
        let key = Self.identity(valid)
        let duplicate = userPresets.enumerated().contains {
            $0.offset != index && Self.identity($0.element) == key
        }
        guard !duplicate else { return nil }
        userPresets[index] = valid
        saveUser()
        return valid
    }

    /// 接受標準 envelope 或單純 preset 陣列；匯入項目一律換新 user id 並略過重複。
    func importPresets(from data: Data) -> ImportResult {
        guard data.count <= 1_000_000 else { return ImportResult(added: 0, skipped: 0) }
        let imported: [RTMPPreset]
        if let file = try? JSONDecoder().decode(PresetFile.self, from: data) {
            imported = file.presets
        } else if let array = try? JSONDecoder().decode([RTMPPreset].self, from: data) {
            imported = array
        } else {
            return ImportResult(added: 0, skipped: 0)
        }
        var added = 0
        var skipped = 0
        var keys = Set(userPresets.map(Self.identity))
        for item in imported {
            guard userPresets.count < Self.maxUserPresets else {
                skipped += 1
                continue
            }
            var candidate = item
            candidate = RTMPPreset(id: "user.\(UUID().uuidString)", name: candidate.name,
                                   rtmpURL: candidate.rtmpURL, note: candidate.note)
            guard let valid = Self.validated(candidate, requireID: true) else {
                skipped += 1
                continue
            }
            let key = Self.identity(valid)
            guard keys.insert(key).inserted else {
                skipped += 1
                continue
            }
            userPresets.append(valid)
            added += 1
        }
        if added > 0 { saveUser() }
        return ImportResult(added: added, skipped: skipped)
    }

    /// 匯出使用者樣本；內建樣本不重複匯出。
    func exportData() -> Data? {
        guard !userPresets.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(PresetFile(version: 1, presets: userPresets))
    }

    private func saveUser() {
        guard let data = try? JSONEncoder().encode(userPresets) else { return }
        defaults.set(data, forKey: Self.userDefaultsKey)
    }

    private static func identity(_ preset: RTMPPreset) -> String {
        preset.name.lowercased() + "\u{1F}" + preset.rtmpURL.lowercased()
    }

    private static func loadUser(defaults: UserDefaults) -> [RTMPPreset] {
        guard let data = defaults.data(forKey: userDefaultsKey), data.count <= 1_000_000,
              let decoded = try? JSONDecoder().decode([RTMPPreset].self, from: data) else {
            return []
        }
        return Array(decoded.compactMap { validated($0, requireID: true) }.prefix(maxUserPresets))
    }

    private static func loadBuiltIn(bundle: Bundle) -> [RTMPPreset] {
        let fallback = [
            RTMPPreset(id: "builtin.srs", name: "自訂 SRS",
                       rtmpURL: "rtmp://192.168.0.102/live", note: nil),
            RTMPPreset(id: "builtin.twitch", name: "Twitch",
                       rtmpURL: "rtmp://live.twitch.tv/app", note: nil),
        ]
        guard let url = bundle.url(forResource: "RTMPPresets", withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count <= 1_000_000,
              let file = try? JSONDecoder().decode(PresetFile.self, from: data) else {
            return fallback
        }
        let valid = file.presets.compactMap { validated($0, requireID: true) }
        return valid.isEmpty ? fallback : Array(valid.prefix(50))
    }
}
