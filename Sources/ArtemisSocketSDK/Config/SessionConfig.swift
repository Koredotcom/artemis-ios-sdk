import Foundation

public struct SessionConfig: Sendable {
    public let idleDisconnectTimeoutMs: Int
    public let endSessionOnIdle: Bool
    public let staleSessionRefreshMs: Int
    public let endSessionOnClose: Bool

    public init(
        idleDisconnectTimeoutMs: Int = 0, endSessionOnIdle: Bool = false,
        staleSessionRefreshMs: Int = 0, endSessionOnClose: Bool = false
    ) {
        self.idleDisconnectTimeoutMs = max(0, idleDisconnectTimeoutMs)
        self.endSessionOnIdle = endSessionOnIdle
        self.staleSessionRefreshMs = max(0, staleSessionRefreshMs)
        self.endSessionOnClose = endSessionOnClose
    }
}

public struct AttachmentConfig: Sendable {
    public static let maxFilesPerMessage = 5
    public let maxFileSizeBytes: Int64
    public let allowedMimeTypes: [String]
    public init(
        maxFileSizeBytes: Int64 = 20 * 1024 * 1024,
        allowedMimeTypes: [String] = [
            "image/*", "audio/*", "video/*", "application/pdf", "text/plain", "text/csv",
            "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.ms-powerpoint",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        ]
    ) {
        self.maxFileSizeBytes = min(max(1, maxFileSizeBytes), 20 * 1024 * 1024)
        self.allowedMimeTypes = allowedMimeTypes
    }
    public func accepts(mimeType: String, sizeBytes: Int64) -> Bool {
        sizeBytes > 0 && sizeBytes <= maxFileSizeBytes
            && allowedMimeTypes.contains {
                $0 == mimeType || ($0.hasSuffix("/*") && mimeType.hasPrefix(String($0.dropLast())))
            }
    }
}
