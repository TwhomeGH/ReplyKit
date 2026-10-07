import ReplayKit
import SwiftUI
import Combine
import os
import Foundation

/// 封裝按壓動畫與呼叫端操作，不持有業務服務。
struct AnimatedButton: View {
    var title: String
    var color: Color = .blue
    var action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: { action() }) {
            Text(title)
                .frame(maxWidth: .infinity)
                .padding()
                .background(isPressed ? color.opacity(0.6) : color)
                .foregroundColor(.white)
                .cornerRadius(8)
                .scaleEffect(isPressed ? 0.95 : 1.0)
        }
#if os(iOS)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                        isPressed = true

                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                        isPressed = false
                        action()
                    }
                }
        )
#elseif os(macOS)
        .onHover { hovering in withAnimation { isPressed = hovering } }
        .onTapGesture { action() }
#endif
    }
}
