import UIKit

struct PIPTextItem {
    let text: String
    let font: UIFont
    let color: UIColor
    let point: CGPoint
    let alpha: CGFloat
}

struct PIPImageItem {
    let image: UIImage?
    let frame: CGRect
    let alpha: CGFloat
    let cornerRadius: CGFloat
}

struct PIPRenderData {
    var textItems: [PIPTextItem]
    var imageItems: [PIPImageItem]
}
