import SwiftUI

/// 手動測試工具；離頁停止獨立的 30 FPS 測試服務。
struct PIPDebugView: View {

    @ObservedObject private var pipService = PIPService.shared

    @State private var isTestPiPActive = false

    @State private var manualMessage: String = "test"
    @State private var manualUser: String = "User33"

    var body: some View {
        ScrollView {
        VStack(spacing: 20) {
            Text("Chat")

            HStack(spacing: 20) {
                VStack(spacing: 10) {
                    Button("[聊天組]啟動 PiP") {
                        let pipSize = CGSize(width: 300, height: 200)
                        PIPService.shared.startPiP(size: pipSize)
                    }
                    .disabled((pipService.isPiPActive && !pipService.isKeepaliveMode) || isTestPiPActive)

                    Button("[保活組]啟動 PiP 保活") {
                        let pipSize = CGSize(width: 300, height: 200)
                        PIPService.shared.startKeepalivePiP(size: pipSize)
                    }
                    .disabled(pipService.isPiPActive || isTestPiPActive)

                    Button("[聊天室]停止 PiP") {
                        PIPService.shared.stopPiP()
                    }
                    .disabled(!pipService.isPiPActive)
                }

                VStack(spacing: 10) {
                    Button("[測試組]啟動 PiP") {
                        PIPTestService.shared.startPiPTest(size: CGSize(width: 300, height: 200))
                        isTestPiPActive = true
                    }
                    .disabled(pipService.isPiPActive || isTestPiPActive)

                    Button("[測試組]停止 PiP") {
                        PIPTestService.shared.stopPiP()
                        isTestPiPActive = false
                    }
                    .disabled(!isTestPiPActive)
                }
            }

            VStack(spacing: 10) {
                TextField("輸入手動用戶名", text: $manualUser)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                TextField("輸入手動訊息", text: $manualMessage)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                Button("新增訊息") {
                    let imgA = "https://img.icons8.com/?size=100&id=12860&format=png&color=000000"
                    let imgG = "https://img.icons8.com/?size=100&id=y5xu7jml0MTU&format=png&color=000000"

                    PIPService.shared
                        .addMessage(
                            user: manualUser,
                            msg: manualMessage,
                            imgURL: imgA,
                            giftURL: imgG
                        )

                    TTSService.shared.speakStreamMessage(
                        user: manualUser,
                        message: manualMessage
                    )

                }

            }



            Button("測試長訊息") {

                let user =  "1阿呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵2阿呵呵呵阿3呵呵呵阿呵呵4呵阿呵呵呵阿呵呵呵阿呵呵呵阿5呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵測試5"

                let msg =  "1阿呵呵呵阿呵呵呵2阿呵呵呵阿3呵呵呵阿呵呵呵阿呵呵呵阿呵4呵呵阿呵呵呵阿呵呵呵阿呵呵呵5阿呵呵呵阿呵呵呵阿呵呵呵測試6"
                let img = "https://img.icons8.com/?size=100&id=L8HgZUgz2jWS&format=png&color=000000"

                let gift = "https://img.icons8.com/?size=100&id=tgLepcPbp6mP&format=png&color=000000"

                PIPService.shared
                    .addMessage(user: user, msg: msg,imgURL: img,giftURL: gift)


                TTSService.shared.speakStreamMessage(
                    user: user,
                    message: msg
                )

            }
            Button("TestB") {
                let imgA = "https://img.icons8.com/?size=100&id=12860&format=png&color=000000"
                let imgG = "https://img.icons8.com/?size=100&id=y5xu7jml0MTU&format=png&color=000000"


                let UNAME = "小明3"
                let UMSG = "Hello!"

                PIPService.shared.addMessage(user: UNAME, msg: UMSG, imgURL: imgA, giftURL: imgG)

                TTSService.shared.speakStreamMessage(
                    user: UNAME,
                    message: UMSG
                )

            }

            Button("Test次要訊息") {
                let imgA = "https://img.icons8.com/?size=100&id=12860&format=png&color=000000"
                let imgG = "https://img.icons8.com/?size=100&id=y5xu7jml0MTU&format=png&color=000000"

                let UNAME = "小明2"
                let UMSG = "Hello!"

                PIPService.shared.addMessage(user: UNAME , msg: UMSG , imgURL: imgA, giftURL: imgG, isMain: false)

                TTSService.shared.speakStreamMessage(
                    user: UNAME,
                    message: UMSG,
                    isMain:false
                )

            }

            Button("新增訊息") {

                let UNAME = ""
                let UMSG = "測試訊息圖片"
                let GIFTURL = "https://img.icons8.com/?size=100&id=y5xu7jml0MTU&format=png&color=000000"
                
                PIPService.shared.addMessage(
                    msg: UMSG,
                    imgURL: "https://img.icons8.com/?size=100&id=12860&format=png&color=000000",
                    giftURL: GIFTURL
                )


                TTSService.shared.speakStreamMessage(
                    user: UNAME,
                    message: UMSG
                )

            }

        }
        .padding()
        }
        .onDisappear {
            if isTestPiPActive { PIPTestService.shared.stopPiP(); isTestPiPActive = false }
        }
    }
}
