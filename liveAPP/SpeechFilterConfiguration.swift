import Foundation

struct SpeechBlockRule: Codable, Equatable {
    var word: String
    var enabled: Bool
    init(word: String, enabled: Bool = true) { self.word = word; self.enabled = enabled }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        word = try c.decode(String.self, forKey: .word)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct SpeechReplacement: Codable, Equatable {
    var word: String
    var replacement: String
    var enabled: Bool
    init(word: String, replacement: String, enabled: Bool = true) {
        self.word = word; self.replacement = replacement; self.enabled = enabled
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        word = try c.decode(String.self, forKey: .word)
        replacement = try c.decode(String.self, forKey: .replacement)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

enum SpeechFilterImportError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let reason): return reason }
    }
}

/// 可交換的格式；舊版 Dictionary 依字典序遷移，新版陣列保留順序。
struct SpeechFilterConfiguration: Codable, Equatable {
    var version = 1
    var blockKeywords: [String]
    var disabledBlockKeywords: [String] = []
    var replaceKeywords: [SpeechReplacement]
    var removeURLs: Bool?
    var removeEmoji: Bool?
    var removePureNumbers: Bool?
    static let maximumBytes = 2 * 1024 * 1024

    init(blockKeywords: [String], replaceKeywords: [SpeechReplacement], removeURLs: Bool? = nil,
         removeEmoji: Bool? = nil, removePureNumbers: Bool? = nil) {
        self.blockKeywords = blockKeywords; self.replaceKeywords = replaceKeywords
        self.removeURLs = removeURLs; self.removeEmoji = removeEmoji; self.removePureNumbers = removePureNumbers
    }
    private enum CodingKeys: String, CodingKey {
        case version, blockKeywords, replaceKeywords, removeURLs, removeEmoji, removePureNumbers
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        let disabled = Set(disabledBlockKeywords)
        try c.encode(blockKeywords.map { SpeechBlockRule(word: $0, enabled: !disabled.contains($0)) }, forKey: .blockKeywords)
        try c.encode(replaceKeywords, forKey: .replaceKeywords)
        try c.encodeIfPresent(removeURLs, forKey: .removeURLs)
        try c.encodeIfPresent(removeEmoji, forKey: .removeEmoji)
        try c.encodeIfPresent(removePureNumbers, forKey: .removePureNumbers)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == 1 else { throw SpeechFilterImportError.invalid("不支援此配置版本：\(version)。") }
        if let legacy = try? c.decode([String].self, forKey: .blockKeywords) {
            blockKeywords = legacy
        } else {
            let rules = try c.decode([SpeechBlockRule].self, forKey: .blockKeywords)
            var states: [String: Bool] = [:]
            for rule in rules {
                if let prior = states[rule.word], prior != rule.enabled {
                    throw SpeechFilterImportError.invalid("檔案內同一排除字有不同啟用狀態：\(rule.word)")
                }
                states[rule.word] = rule.enabled
            }
            blockKeywords = rules.map(\.word)
            disabledBlockKeywords = rules.filter { !$0.enabled }.map(\.word)
        }
        if let legacy = try? c.decode([String: String].self, forKey: .replaceKeywords) {
            replaceKeywords = legacy.keys.sorted().map { SpeechReplacement(word: $0, replacement: legacy[$0]!) }
        } else { replaceKeywords = try c.decode([SpeechReplacement].self, forKey: .replaceKeywords) }
        removeURLs = try c.decodeIfPresent(Bool.self, forKey: .removeURLs)
        removeEmoji = try c.decodeIfPresent(Bool.self, forKey: .removeEmoji)
        removePureNumbers = try c.decodeIfPresent(Bool.self, forKey: .removePureNumbers)
    }
    func validated() throws -> Self {
        guard version == 1 else { throw SpeechFilterImportError.invalid("不支援此配置版本。") }
        guard blockKeywords.count + replaceKeywords.count <= 10_000 else {
            throw SpeechFilterImportError.invalid("規則總數不可超過 10,000 條。")
        }
        for word in blockKeywords + replaceKeywords.map(\.word) {
            guard !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SpeechFilterImportError.invalid("排除字與替換原字不可為空白。")
            }
        }
        var result = self
        var seen = Set<String>()
        result.blockKeywords = blockKeywords.filter { seen.insert($0).inserted }
        result.disabledBlockKeywords = result.blockKeywords.filter { disabledBlockKeywords.contains($0) }
        var replacements: [String: SpeechReplacement] = [:]
        result.replaceKeywords = []
        for rule in replaceKeywords {
            if let prior = replacements[rule.word] {
                guard prior == rule else {
                    throw SpeechFilterImportError.invalid("檔案內同一原字有不同替換內容：\(rule.word)")
                }
            } else { replacements[rule.word] = rule; result.replaceKeywords.append(rule) }
        }
        return result
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw SpeechFilterImportError.invalid("配置檔不可超過 2 MiB。") }
        do { return try JSONDecoder().decode(Self.self, from: data).validated() }
        catch let error as SpeechFilterImportError { throw error }
        catch { throw SpeechFilterImportError.invalid("JSON 格式或欄位型別不正確，需包含 blockKeywords 與 replaceKeywords。") }
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(try validated())
        guard data.count <= Self.maximumBytes else { throw SpeechFilterImportError.invalid("配置檔不可超過 2 MiB。") }
        return data
    }
    func conflicts(with incoming: Self) -> [String] {
        let existing = Dictionary(uniqueKeysWithValues: replaceKeywords.map { ($0.word, $0) })
        return incoming.replaceKeywords.compactMap { rule in
            if let value = existing[rule.word], value != rule { return rule.word }
            return nil
        }
    }
    func blockConflicts(with incoming: Self) -> [String] {
        incoming.blockKeywords.filter {
            blockKeywords.contains($0) && disabledBlockKeywords.contains($0) != incoming.disabledBlockKeywords.contains($0)
        }
    }
    func merging(_ incoming: Self, useIncomingConflicts: Bool) throws -> Self {
        var result = try validated()
        let incoming = try incoming.validated()
        for word in incoming.blockKeywords {
            let exists = result.blockKeywords.contains(word)
            if !exists { result.blockKeywords.append(word) }
            if !exists || useIncomingConflicts {
                result.disabledBlockKeywords.removeAll { $0 == word }
                if incoming.disabledBlockKeywords.contains(word) { result.disabledBlockKeywords.append(word) }
            }
        }
        for rule in incoming.replaceKeywords {
            if let index = result.replaceKeywords.firstIndex(where: { $0.word == rule.word }) {
                if useIncomingConflicts { result.replaceKeywords[index] = rule }
            } else { result.replaceKeywords.append(rule) }
        }
        // 合併只更新清單；既有全域過濾開關保留。
        return try result.validated()
    }
    func write(to directory: URL, backup: Bool = false) throws -> URL {
        let data = try encoded()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let prefix = backup ? "tts-filters-backup" : "tts-filters"
        let url = directory.appendingPathComponent("\(prefix)-\(formatter.string(from: Date()))-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
