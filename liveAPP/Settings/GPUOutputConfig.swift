import ReplayKit
import SwiftUI
import Combine
import os
import Foundation

/// GPU 輸出方向；角度 rawValue 保留既有設定格式。
enum RotateDirection: Int, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case portrait = 0          // 直向
    case landscapeRight = 90   // 橫向，Home鍵右側
    case portraitUpsideDown = 180 // 反向直向
    case landscapeLeft = 270   // 橫向，Home鍵左側

    var id: Int { rawValue }


    var description: String {
        switch self {
        case .portrait: return "直向"
        case .landscapeRight: return "橫向  (Home鍵在右側)"
        case .portraitUpsideDown: return "反向直向"
        case .landscapeLeft: return "橫向 (Home鍵在左側)"
        }
    }
}


/// 可保存的 GPU 畫布配置，保留既有 Codable 格式與偏好鍵。
class GPUOutputConfig: Identifiable, ObservableObject, Codable {
    let id: UUID
    @Published var name: String
    @Published var width: Int
    @Published var height: Int

    @Published var owidth: Int
    @Published var oheight: Int
    @Published var originonly: Bool

    @Published var Rotate: RotateDirection

    init(
        id: UUID = UUID(),
        name: String,
        width: Int,
        height: Int,
        owidth:Int = 0,
        oheight:Int = 0,
        originonly:Bool = false,
        Rotate: RotateDirection = .landscapeRight
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height

        self.owidth = owidth
        self.oheight = oheight
        self.originonly = originonly

        self.Rotate = Rotate

    }

    // MARK: - Codable 支援
    enum CodingKeys: CodingKey {
        case id, name, width, height, owidth,oheight,originonly,Rotate
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)

        owidth = try container.decode(Int.self, forKey: .owidth)
        oheight = try container.decode(Int.self, forKey: .oheight)

        originonly = try container.decode(Bool.self, forKey: .originonly)

        Rotate = try container.decode(RotateDirection.self, forKey: .Rotate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)

        try container.encode(owidth, forKey: .owidth)
        try container.encode(oheight, forKey: .oheight)

        try container.encode(originonly, forKey: .originonly)


        try container.encode(Rotate, forKey: .Rotate)
    }

    // MARK: - 保存 & 讀取 整個配置列表
    static private let userDefaultsKey = "gpuConfigs"
    static private let userDefaultsSelectKey = "gpuConfigsSelect"

    static func save(_ configs: [GPUOutputConfig]) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(configs) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    static func load(defaults: [GPUOutputConfig]? = nil) -> [GPUOutputConfig] {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let savedConfigs = try? JSONDecoder().decode([GPUOutputConfig].self, from: data) {
            return savedConfigs
        } else {
            return defaults ?? []
        }
    }  


    // MARK: - 保存當前選擇的配置
    static func saveSelected(_ config: GPUOutputConfig?) {
        guard let config else {
            logger.debug("無配置！GPUOutConfig")
            return
        }

        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: userDefaultsSelectKey)
        }
    }


    // MARK: - 讀取當前選擇的配置
    static func loadSelected() -> GPUOutputConfig? {
        if let data = UserDefaults.standard.data(forKey: userDefaultsSelectKey),
           let config = try? JSONDecoder().decode(GPUOutputConfig.self, from: data) {
            return config
        }
        return nil
    }

    // MARK: - 快速清除所有記錄（可選）
    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: userDefaultsSelectKey)
    }
}
