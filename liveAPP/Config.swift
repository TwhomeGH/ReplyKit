//
//  Config.swift
//  liveAPP
//
//  Created by user on 2025/10/3.
//


import Foundation

class ConfigManager<Key: Hashable & Codable, Value: Codable>: ObservableObject {
    @Published private(set) var config: [Key: Value] = [:]
    private var layers: [[Key: Value]] = []

    private let userDefaultsKey = "userConfig"
    private let maxLayers = 10

    init(defaultConfig: [Key: Value]) {
        layers.append(defaultConfig)
        loadUserConfig()
        refresh()
    }

    func push(_ newConfig: [Key: Value]) {
        while layers.count >= maxLayers {
            layers.remove(at: 1)
        }
        layers.append(newConfig)
        saveUserConfig(newConfig)
        refresh()
    }

    func value(forKey key: Key) -> Value? {
        config[key]
    }

    private func refresh() {
        config = layers.reduce([:]) { partial, next in
            partial.merging(next) { _, new in new }
        }
    }

    // MARK: - Persistence

    private func saveUserConfig(_ config: [Key: Value]) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(config) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private func loadUserConfig() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let saved = try? JSONDecoder().decode([Key: Value].self, from: data) {
            layers.append(saved)
        }
    }
}


struct StreamConfig: Identifiable, Codable {
    let id: UUID
    var name: String   // 組名，例如 "Twitch" 或 "自訂"
    var rtmpURL: String
    var streamKey: String

    init(id: UUID = UUID(), name: String, rtmpURL: String, streamKey: String) {
        self.id = id
        self.name = name
        self.rtmpURL = rtmpURL
        self.streamKey = streamKey
    }
}

class StreamConfigManager: ObservableObject {
    @Published var configs: [StreamConfig] = []
    @Published var activeConfigID: UUID? = nil

    private let configsKey = "streamConfigs"
    private let activeKey = "activeStreamConfigID"

    private let storage: UserDefaults
    private let endpointStorage: UserDefaults

    /// 注入儲存區供測試隔離；正式環境仍沿用原配置庫與共享端點偏好。
    init(storage: UserDefaults = .standard, endpointStorage: UserDefaults? = userDefaults) {
        self.storage = storage
        self.endpointStorage = endpointStorage ?? .standard
        load()
    }

    func addConfig(_ config: StreamConfig) {
        configs.append(config)
        save()
    }

    func removeConfig(_ config: StreamConfig) {
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs.remove(at: index)
            // 如果刪掉的是目前啟用的 config，順便清空
            if activeConfigID == config.id {
                activeConfigID = nil
            }
            save()
        }
    }
    

    func updateConfig(_ config: StreamConfig) {
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
            save()
        }
    }

    /// 明確保存草稿並套用正式端點；選取或離開編輯畫面不呼叫此入口。
    func saveAndActivate(_ config: StreamConfig) {
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
        } else { configs.append(config) }
        activeConfigID = config.id
        save()
        endpointStorage.set(config.rtmpURL, forKey: "rtmpURL")
        endpointStorage.set(config.streamKey, forKey: "rtmpKey")
    }

    func setActiveConfig(_ config: StreamConfig) {
        activeConfigID = config.id
        save()
    }

    var activeConfig: StreamConfig? {
        configs.first { $0.id == activeConfigID }
    }

    // MARK: - Persistence
    private func save() {
        if let data = try? JSONEncoder().encode(configs) {
            storage.set(data, forKey: configsKey)
        }
        storage.set(activeConfigID?.uuidString, forKey: activeKey)
    }

    private func load() {
        if let data = storage.data(forKey: configsKey),
           let decoded = try? JSONDecoder().decode([StreamConfig].self, from: data) {
            configs = decoded
        }
        if let idString = storage.string(forKey: activeKey),
           let uuid = UUID(uuidString: idString) {
            activeConfigID = uuid
        }
    }
}
