import SwiftUI
import UIKit

/// 偏好設定只存 #RRGGBB，避免把 UIColor／Color 直接放進 UserDefaults。
extension UIColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1)
    }

    var hexRGB: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if !getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0
            getWhite(&white, alpha: &alpha)
            red = white; green = white; blue = white
        }
        return String(format: "#%02X%02X%02X",
                      Int(round(red * 255)), Int(round(green * 255)), Int(round(blue * 255)))
    }
}

extension Color {
    init?(hex: String) {
        guard let color = UIColor(hex: hex) else { return nil }
        self.init(uiColor: color)
    }

    var hexRGB: String { UIColor(self).hexRGB }
    /// 舊呼叫端名稱；與 `hexRGB` 共用同一套四捨五入。
    var hexString: String { hexRGB }
}
