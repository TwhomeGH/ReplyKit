import CoreTransferable
import Foundation
import PhotosUI
import UniformTypeIdentifiers

/// 相簿影片的暫存副本；以檔案表示載入，避免整段影片進入記憶體。
struct ImportedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let source = received.file
            let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: source, to: copy)
            return Self(url: copy)
        }
    }
}

/// 從相簿取得可讀的影片暫存檔；呼叫端負責在不再使用時刪除。
enum PhotoVideoImport {
    static func load(_ item: PhotosPickerItem) async throws -> URL {
        guard let video = try await item.loadTransferable(type: ImportedVideo.self) else {
            throw NSError(domain: "PhotoVideoImport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "無法讀取所選影片。"])
        }
        return video.url
    }
}
