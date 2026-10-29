import SwiftUI

/// 掃描文件共享中的成品；檔案 App 的增刪於重新整理時反映，不維護第二份索引。
struct CompressedVideoLibraryView: View {
    @ObservedObject private var model = VideoCompressionModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var files: [URL] = []
    @State private var selected: Set<URL> = []
    @State private var dates: [URL: Date] = [:]
    @State private var sizes: [URL: Int64] = [:]
    @State private var abandonedBytes: Int64 = 0
    @State private var currentBytes: Int64 = 0
    @State private var message = ""
    @State private var deleting = false
    @State private var cleaning = false

    private var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CompressedVideos", isDirectory: true)
    }

    var body: some View {
        List {
            Section("空間摘要") {
                Text("壓縮成品：" + bytes(sizes.values.reduce(0, +)))
                Text("本次程序暫存：" + bytes(currentBytes))
                Text("前次程序暫存：" + bytes(abandonedBytes))
                Text("不含本地錄影、日誌及舊版未分類暫存；不是 App 文件與資料總量。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("清理前次程序暫存") { cleaning = true }
                    .disabled(abandonedBytes == 0)
            }
            Section("已壓縮影片（\(files.count)）") {
                if files.isEmpty { Text("尚無壓縮成品") }
                ForEach(files, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(get: { selected.contains(url) }, set: {
                            if $0 { selected.insert(url) } else { selected.remove(url) }
                        })) { Text(url.lastPathComponent).lineLimit(3) }
                        Text(bytes(sizes[url] ?? 0)).font(.caption)
                        if let date = dates[url] { Text(date, style: .date).font(.caption) }
                        HStack {
                            NavigationLink("播放") { CompressionPlaybackView(url: url) }
                            ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                        }
                        CompressedVideoDuration(url: url)
                    }
                }
                Button("刪除所選 \(selected.count) 支影片", role: .destructive) { deleting = true }
                    .disabled(selected.isEmpty || model.busy || selected.contains(where: { $0 == model.source }))
                if selected.contains(where: { $0 == model.source }) {
                    Text("所選包含目前壓縮來源；請先在壓縮頁清除來源。")
                        .font(.caption)
                }
            }
            if !message.isEmpty { Section { Text(message) } }
        }
        .navigationTitle("已壓縮影片")
        .toolbar { Button("重新整理", action: reload) }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { if $0 == .active { reload() } }
        .confirmationDialog("永久刪除所選 \(selected.count) 支成品？無法復原。", isPresented: $deleting, titleVisibility: .visible) {
            Button("永久刪除", role: .destructive, action: deleteSelected)
        }
        .confirmationDialog("清除前次程序暫存（\(bytes(abandonedBytes)))？成品與本次程序暫存保留。", isPresented: $cleaning, titleVisibility: .visible) {
            Button("清除暫存", role: .destructive, action: cleanAbandoned)
        }
    }

    /// 每次重新掃描，拒絕符號連結；失敗保留錯誤提示而非顯示成功。
    private func reload() {
        do {
            let fm = FileManager.default
            files = try fm.fileExists(atPath: folder.path) ? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]).filter {
                let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return $0.pathExtension.lowercased() == "mp4" && values.isRegularFile == true && values.isSymbolicLink != true
            }.sorted { lhs, rhs in
                let left = try lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                let right = try rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                return left > right
            } : []
            sizes = try Dictionary(uniqueKeysWithValues: files.map { ($0, try VideoWorkFiles.bytes(at: $0)) })
            dates = try Dictionary(uniqueKeysWithValues: files.map { ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) })
            selected.formIntersection(Set(files))
            abandonedBytes = try VideoWorkFiles.abandoned().reduce(0) { try $0 + VideoWorkFiles.bytes(at: $1) }
            let current = VideoWorkFiles.root.appendingPathComponent(VideoWorkFiles.session)
            currentBytes = try fm.fileExists(atPath: current.path) ? VideoWorkFiles.bytes(at: current) : 0
        } catch { report(error) }
    }

    /// 只刪除仍在成品目錄的明確選取項目；任務與來源於確認後再檢查。
    private func deleteSelected() {
        guard !model.busy, !selected.contains(where: { $0 == model.source }) else { return }
        var removed = 0
        for url in selected {
            do {
                guard url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { continue }
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch { report(error); reload(); return }
        }
        message = "已刪除 \(removed) 支成品。"
        selected = []
        reload()
    }

    /// 只刪除前次程序專屬目錄，保留本程序所有任務的檔案。
    private func cleanAbandoned() {
        do {
            var released: Int64 = 0
            for url in try VideoWorkFiles.abandoned() {
                let size = try VideoWorkFiles.bytes(at: url)
                try FileManager.default.removeItem(at: url)
                released += size
            }
            message = "已清理暫存：" + bytes(released)
            reload()
        } catch { report(error); reload() }
    }

    private func report(_ error: Error) {
        message = "檔案操作失敗：" + error.localizedDescription
        sendlog(message: "[VideoStorage] " + message)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

/// 延後讀取時長，避免載入清單時逐一同步解析影片。
private struct CompressedVideoDuration: View {
    let url: URL
    @State private var duration = "讀取時長…"
    var body: some View {
        Text(duration).font(.caption).foregroundStyle(.secondary)
            .task(id: url) {
                do {
                    let details = try await RecordingFileDetails.read(url)
                    duration = String(format: "時長 %.1f 秒", details.duration)
                } catch { duration = "時長讀取失敗：" + error.localizedDescription }
            }
    }
}
