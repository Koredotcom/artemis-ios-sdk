import Foundation
import SwiftUI
#if canImport(ArtemisSocketSDK)
import ArtemisSocketSDK
#endif

struct FileTemplate: View {
    let file: FileContent
    let accentColor: Color

    var body: some View {
        FileDownloadCard(title: file.filename.isEmpty ? "Attachment" : file.filename, subtitle: fileSubtitle, url: file.url, accentColor: accentColor)
    }

    private var fileSubtitle: String {
        file.sizeBytes.map(Self.formatBytes) ?? ""
    }

    private static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
