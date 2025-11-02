//
//  PIPContent.swift
//  liveAPP
//
//  Created by user on 2025/10/18.
//

import SwiftUI
import UIKit

import CoreVideo

import AVFoundation
import AVKit






struct CustomChatView: View {
    var body: some View {
        VStack {
            Text("🟡 自訂聊天室")
                .font(.headline)
            ForEach(0..<5) { i in
                Text("訊息 \(i)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }
        }
        .frame(width: 300, height: 200)
        .background(Color.green.opacity(0.8))
        .foregroundColor(.white)
    }
}

struct PIPView: View {
    var body: some View {

        VStack(spacing: 20) {
            Text("Chat")

            Button("OpenPIP"){
                DispatchQueue.main.async {
                    PIPService.shared.tryStartPiP()
                }

            }
            Button("啟動 PiP") {

                // 設定 PiP 顯示尺寸
                let pipSize = CGSize(width: 300, height: 200)

                
                // 啟動 PiP
                PIPService.shared
                    .startPiP(
                        with: CustomChatView(),
                        size: pipSize,
                        enableDebugPreview: false
                    )

                //PIPServiceRR.shared.startPiP()


            }
            
            Button("停止 PiP") {
                PIPService.shared.stopPiP()

                //PIPServiceRR.shared.stopPIP()

            }
        }
    }
}
// 這是一個你自訂的內容（聊天室/動畫等）
