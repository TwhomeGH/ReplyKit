import Foundation
import HaishinKit

/// 音量控制專用串行工作：通知合併、兩軌快照、一次 Mixer 更新、套用回報。
/// Socket 失敗保留目前音量；每五秒補查可補回漏掉的通知與重連後的設定。
actor ReplayVolumeSynchronizer {
    private let mixer: MediaMixer
    private let updateProcessor: @Sendable (Float, Float, Float) async -> Void
    private let session = UUID().uuidString
    private var worker: Task<Void, Never>?
    private var dirty = true
    private var ended = false
    private var revision = 0
    private var lastApp: Float?
    private var lastMic: Float?
    private var lastGain: Float?

    init(mixer: MediaMixer, updateProcessor: @escaping @Sendable (Float, Float, Float) async -> Void) {
        self.mixer = mixer
        self.updateProcessor = updateProcessor
    }

    func requestRefresh() { dirty = true }

    /// 一個 session 只建立一條消費工作，避免 actor 在 await 時重入並平行寫設定。
    func start() {
        guard worker == nil, !ended else { return }
        worker = Task { await run() }
    }

    func stop() {
        ended = true
        worker?.cancel()
        worker = nil
        report(status: "stopped")
    }

    private func report(status: String) {
        var payload: [String: Any] = ["type": "audioVolumeApplied", "schema": 1,
            "session": session, "revision": revision, "status": status,
            "reportedAt": Date().timeIntervalSince1970]
        if let lastApp { payload["app"] = lastApp }
        if let lastMic { payload["mic"] = lastMic }
        if let lastGain { payload["micGain"] = lastGain }
        SocketClient.shared.sendPayload(payload)
    }

    /// 每輪等完整讀取與套用結束才接受下一輪；失敗不以 1.0 覆蓋既有值。
    private func run() async {
        var nextPoll = 0.0
        while !Task.isCancelled, !ended {
            let now = ProcessInfo.processInfo.systemUptime
            if dirty || now >= nextPoll {
                dirty = false
                nextPoll = now + 5
                do {
                    let values = try await readSnapshot()
                    guard !Task.isCancelled, !ended else { return }
                    let app = values.app
                    let mic = values.mic
                    if app != lastApp || mic != lastMic || values.micGain != lastGain {
                        var settings = await mixer.audioMixerSettings
                        guard !Task.isCancelled, !ended else { return }
                        // App 軌是必要輸出；mic 被停用時仍要套用 App 音量。
                        guard settings.tracks[0] != nil else {
                            report(status: "tracksUnavailable")
                            try await Task.sleep(nanoseconds: 200_000_000)
                            continue
                        }
                        settings.tracks[0]?.volume = app
                        settings.tracks[1]?.volume = mic
                        await mixer.setAudioMixerSettings(settings)
                        guard !Task.isCancelled, !ended else { return }
                        await updateProcessor(app, mic, values.micGain)
                        guard !Task.isCancelled, !ended else { return }
                        lastApp = app
                        lastMic = mic
                        lastGain = values.micGain
                        revision += 1
                        sendlog(message: "[AudioControl] session=\(session) revision=\(revision) app=\(app) mic=\(mic) mixerApplied=true")
                    }
                    // 重連後即使值相同也重送，避免主 App 永遠停留在等待狀態。
                    report(status: "applied")
                } catch {
                    guard !Task.isCancelled, !ended else { return }
                    report(status: "syncFailed")
                    sendlog(message: "[AudioControl] 同步失敗，保留現有音量：\(error)")
                }
            }
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
        }
    }

    private func readSnapshot() async throws -> AudioControlSettings {
        let snapshot: AudioControlSettings
        if RPConfig.shared.enableSocketLog || RPConfig.isSideload {
            guard let json = try await SocketClient.shared.requestSet(for: "audioVolumeSnapshot", type: "String") as? String,
                  let data = json.data(using: .utf8) else {
                throw NSError(domain: "AudioControl", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "主 App 未提供音量快照；請確認連線與版本"])
            }
            snapshot = try JSONDecoder().decode(AudioControlSettings.self, from: data)
        } else {
            guard let defaults = SharedDefaults.group else { throw NSError(domain: "AudioControl", code: 2) }
            snapshot = AudioControlSettings(defaults: defaults)
        }
        guard snapshot.isValid else { throw NSError(domain: "AudioControl", code: 3) }
        return snapshot
    }
}
