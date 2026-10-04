#if os(iOS)
import Foundation
import SwiftUI
import AVKit
import Photos

@MainActor final class RecordingLibrary: ObservableObject {
    static let shared = RecordingLibrary()
    @Published private(set) var recordings: [LocalRecording] = []
    @Published var errorMessage: String?
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenRecordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            for url in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                do {
                    var item = try JSONDecoder().decode(LocalRecording.self, from: Data(contentsOf: url))
                    guard url.deletingPathExtension().lastPathComponent == item.id.uuidString else { continue }
                    item.recoverAfterRelaunch()
                    recordings.append(item)
                    try persist(item)
                } catch { errorMessage = "部分錄影紀錄無法讀取，原檔案仍保留。" }
            }
            recordings.sort { $0.created > $1.created }
        } catch { errorMessage = "無法開啟錄影目錄。" }
    }
    func fileURL(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("mp4") }
    private func manifestURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
    private func persist(_ item: LocalRecording) throws {
        try JSONEncoder().encode(item).write(to: manifestURL(item.id), options: .atomic)
    }
    func create() throws -> LocalRecording {
        let item = LocalRecording(id: UUID(), created: Date())
        try persist(item)
        recordings.insert(item, at: 0)
        return item
    }
    func update(_ id: UUID, phase: RecordingPhase? = nil, duration: Double, bytes: Int64, message: String? = nil) {
        guard let index = recordings.firstIndex(where: { $0.id == id }), !recordings[index].phase.isTerminal else { return }
        var item = recordings[index]
        if let phase, !item.transition(to: phase) { return }
        item.duration = duration.isFinite ? max(0, duration) : 0
        item.bytes = max(0, bytes)
        item.message = message
        recordings[index] = item
        // 每秒的大小與時間只更新畫面，狀態轉移才落盤。
        if phase != nil {
            do { try persist(item) }
            catch { errorMessage = "錄影狀態無法儲存；請保留原檔並確認儲存空間。" }
        }
    }
    func delete(_ item: LocalRecording) throws {
        guard item.phase.isTerminal else { return }
        let file = fileURL(for: item.id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try FileManager.default.removeItem(at: manifestURL(item.id))
        recordings.removeAll { $0.id == item.id }
    }
    func saveToPhotos(_ item: LocalRecording) async throws {
        guard item.phase == .ready else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "LocalRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: "請允許加入照片，或使用分享匯出影片。"])
        }
        let url = fileURL(for: item.id)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}

@MainActor struct RecordingLibraryView: View {
    @ObservedObject private var library = RecordingLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var playing: LocalRecording?
    @State private var deleting: LocalRecording?
    @State private var saving: UUID?
    @State private var message: String?
    var body: some View {
        NavigationStack {
            List {
                if library.recordings.isEmpty { Text("尚無本地錄影") }
                if let error = library.errorMessage { Text(error).foregroundStyle(.red) }
                ForEach(library.recordings) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.created.formatted(date: .abbreviated, time: .standard))
                        Text("\(item.phase.title) · \(Int(item.duration)) 秒 · \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))")
                            .font(.caption)
                        if let error = item.message { Text(error).font(.caption).foregroundStyle(.secondary) }
                        if item.phase == .ready {
                            HStack {
                                Button("播放") { playing = item }
                                ShareLink("分享／匯出", item: library.fileURL(for: item.id))
                                Button(saving == item.id ? "儲存中…" : "存入照片") {
                                    saving = item.id
                                    Task {
                                        do { try await library.saveToPhotos(item); message = "已存入照片。" }
                                        catch { message = error.localizedDescription }
                                        saving = nil
                                    }
                                }.disabled(saving != nil)
                            }.buttonStyle(.borderless)
                        }
                        if item.phase.isTerminal {
                            Button("刪除", role: .destructive) { deleting = item }
                                .buttonStyle(.borderless).disabled(saving != nil)
                        }
                    }
                }
            }
            .navigationTitle("本地錄影")
            .toolbar { Button("完成") { dismiss() }.disabled(saving != nil) }
            .sheet(item: $playing) { item in RecordingPlayerView(url: library.fileURL(for: item.id)) }
            .alert("本地錄影", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            } message: { Text(message ?? "") }
            .confirmationDialog("刪除此錄影與紀錄？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    if let item = deleting {
                        do { try library.delete(item) } catch { message = "無法刪除錄影，請稍後再試。" }
                    }
                    deleting = nil
                }
            }
        }.interactiveDismissDisabled(saving != nil)
    }
}

@MainActor private struct RecordingPlayerView: View {
    @State private var player: AVPlayer
    init(url: URL) { _player = State(initialValue: AVPlayer(url: url)) }
    var body: some View { VideoPlayer(player: player).onDisappear { player.pause() } }
}
#endif
