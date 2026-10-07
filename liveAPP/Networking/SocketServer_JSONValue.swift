import Foundation

/// 協定資料模型，保留 SocketServer.JSONValue 名稱以維持現有呼叫點。
extension SocketServer {
    /// Socket 訊息可攜帶的 JSON 值；值型別不持有共享可變資源。
    enum JSONValue: Codable, Sendable {

        /// JSON 字符串值
        case string(String)
        /// JSON 整數值
        case int(Int)
        /// JSON 浮點數值
        case double(Double)
        /// JSON 布爾值
        case bool(Bool)
        /// JSON 對象值
        case object([String: JSONValue])
        /// JSON 數組值
        case array([JSONValue])
        /// JSON 空值
        case null

        /// 從 JSON 解碼器初始化 JSONValue
        /// - Parameter decoder: JSON 解碼器
        /// - Throws: 解碼錯誤
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null; return }
            if let v = try? container.decode(Bool.self) { self = .bool(v); return }
            if let v = try? container.decode(Int.self) { self = .int(v); return }
            if let v = try? container.decode(Double.self) { self = .double(v); return }
            if let v = try? container.decode(String.self) { self = .string(v); return }
            if let v = try? container.decode([String: JSONValue].self) { self = .object(v); return }
            if let v = try? container.decode([JSONValue].self) { self = .array(v); return }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }

        /// 將 JSONValue 編碼到 JSON 編碼器
        /// - Parameter encoder: JSON 編碼器
        /// - Throws: 編碼錯誤
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let v): try container.encode(v)
            case .int(let v): try container.encode(v)
            case .double(let v): try container.encode(v)
            case .bool(let v): try container.encode(v)
            case .object(let v): try container.encode(v)
            case .array(let v): try container.encode(v)
            case .null: try container.encodeNil()
            }
        }
    }
}

extension SocketServer.JSONValue {
    /// JSONSerialization 可使用的值；巢狀 null 保留為 NSNull，不遺失欄位或陣列位置。
    var foundationValue: Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .object(let v): return v.mapValues { $0.foundationValue }
        case .array(let v): return v.map { $0.foundationValue }
        case .null: return NSNull()
        }
    }

    /// UserDefaults 可接受的值；任何層級含 null 或非有限浮點數時整筆拒絕，不局部刪除。
    var propertyListValue: Any? {
        switch self {
        case .null: return nil
        case .double(let v): return v.isFinite ? v : nil
        case .array(let values):
            var result: [Any] = []
            for value in values {
                guard let converted = value.propertyListValue else { return nil }
                result.append(converted)
            }
            return result
        case .object(let values):
            var result: [String: Any] = [:]
            for (key, value) in values {
                guard let converted = value.propertyListValue else { return nil }
                result[key] = converted
            }
            return result
        default: return foundationValue
        }
    }
}
