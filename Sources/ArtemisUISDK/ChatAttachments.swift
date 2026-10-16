import Foundation
import UniformTypeIdentifiers

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

public struct ChatAttachment: Identifiable, Equatable, Sendable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int64
    public let deliveryFailed: Bool
    public init(
        id: String, filename: String, mimeType: String = "application/octet-stream",
        sizeBytes: Int64 = 0,
        deliveryFailed: Bool = false
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.deliveryFailed = deliveryFailed
    }
    var fileType: String {
        let ext = (filename as NSString).pathExtension.uppercased()
        if !ext.isEmpty { return ext }
        return UTType(mimeType: mimeType)?.preferredFilenameExtension?.uppercased() ?? "FILE"
    }
    var icon: String {
        switch fileType {
        case "TXT", "CSV": return "doc.text"
        case "PDF": return "doc.richtext"
        case "DOC", "DOCX": return "doc.text.fill"
        case "XLS", "XLSX": return "tablecells"
        case "PPT", "PPTX": return "rectangle.on.rectangle"
        default:
            if mimeType.hasPrefix("image/") { return "photo" }
            if mimeType.hasPrefix("video/") { return "video" }
            if mimeType.hasPrefix("audio/") { return "waveform" }
            return "doc"
        }
    }
    var detail: String {
        fileType
            + (sizeBytes > 0
                ? " • " + ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) : "")
    }
    static func from(_ message: Message) -> [ChatAttachment] {
        let metadata = message.metadata?.mapValues(\.value) ?? [:]
        let custom = metadata["custom"] as? [String: Any]
        let raw =
            metadata["attachments"] as? [[String: Any]] ?? custom?["customerAttachments"]
            as? [[String: Any]] ?? []
        let failedIDs = metadata["agentTransferAttachmentFailedIds"] as? [String] ?? []
        func failed(_ id: String) -> Bool {
            metadata["agentTransferAttachmentDeliveryStatus"] as? String == "not_sent"
                || failedIDs.contains(id)
        }
        let refs = raw.compactMap { value -> ChatAttachment? in
            guard let id = value["id"] as? String ?? value["attachmentId"] as? String, !id.isEmpty else {
                return nil
            }
            return ChatAttachment(
                id: id,
                filename: value["filename"] as? String ?? value["fileName"] as? String ?? value["name"]
                    as? String
                    ?? "Attachment",
                mimeType: value["mimeType"] as? String ?? value["fileType"] as? String
                    ?? "application/octet-stream",
                sizeBytes: max(
                    0, (value["sizeBytes"] as? NSNumber ?? value["size"] as? NSNumber)?.int64Value ?? 0),
                deliveryFailed: failed(id))
        }
        var seen = Set<String>()
        if !refs.isEmpty { return refs.filter { seen.insert($0.id).inserted } }
        let ids = metadata["attachmentIds"] as? [String] ?? message.attachmentIds ?? []
        let names = metadata["attachmentFilenames"] as? [String] ?? []
        let types = metadata["attachmentMimeTypes"] as? [String] ?? []
        let sizes =
            metadata["attachmentSizeBytes"] as? [NSNumber] ?? metadata["attachmentSizes"] as? [NSNumber]
            ?? []
        return ids.enumerated().compactMap { i, id in
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return ChatAttachment(
                id: id, filename: names.indices.contains(i) ? names[i] : "Attachment",
                mimeType: types.indices.contains(i) ? types[i] : "application/octet-stream",
                sizeBytes: sizes.indices.contains(i) ? max(0, sizes[i].int64Value) : 0,
                deliveryFailed: failed(id))
        }
    }
}

public struct AttachmentDraft: Identifiable, Sendable {
    public enum Status: String, Sendable { case queued, uploading, ready, failed, cancelled }
    public let id: String
    public var attachment: ChatAttachment
    public internal(set) var status: Status = .queued
    public internal(set) var progress: Double = 0
    public internal(set) var error: String?
    let source: URL
    let sessionId: String
    let removesSource: Bool
    var revision = 0
}

@MainActor extension AgentChatViewModel {
    func updateAttachmentPolicy(_ scope: SDKSessionScope?) {
        let allowed =
            scope?.attachmentLimits?.enabled == true
            && scope?.permissions.contains("attachment:write") == true
            && !attachmentsUnavailable
        if attachmentsAllowed && !allowed { cancelAllUploads() }
        attachmentsAllowed = allowed
    }

    var allowedAttachmentContentTypes: [UTType] {
        let values = (sdk?.configuration.attachments ?? AttachmentConfig()).allowedMimeTypes.compactMap {
            mime -> UTType? in
            switch mime {
            case "image/*": return .image
            case "audio/*": return .audio
            case "video/*": return .movie
            default: return UTType(mimeType: mime)
            }
        }
        return values.isEmpty ? [.item] : values
    }
    public var canAttach: Bool { status == .connected && attachmentsAllowed && !isSending }
    public var canSend: Bool {
        status == .connected && !isSending
            && (attachmentDrafts.isEmpty
                ? !composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                : attachmentsAllowed && attachmentDrafts.allSatisfy { $0.status == .ready })
    }
    public func uploadAttachments(_ urls: [URL], removeTemporaryFiles: Bool = false) {
        guard canAttach, let sessionId = sdk?.getSessionId(), !urls.isEmpty else {
            if removeTemporaryFiles { urls.forEach(Self.removePickerFile) }
            return
        }
        var seen = Set(attachmentDrafts.map { $0.source.standardizedFileURL })
        let additions = urls.filter { seen.insert($0.standardizedFileURL).inserted }
        guard additions.count + attachmentDrafts.count <= AttachmentConfig.maxFilesPerMessage else {
            errorMessage = strings("You can attach up to five files per message.")
            if removeTemporaryFiles { urls.forEach(Self.removePickerFile) }
            return
        }
        attachmentSessionId = sessionId
        attachmentDrafts += additions.map { url in
            AttachmentDraft(
                id: UUID().uuidString, attachment: ChatAttachment(id: "", filename: url.lastPathComponent),
                source: url,
                sessionId: sessionId, removesSource: removeTemporaryFiles)
        }
        publishAttachments()
        startNextUpload()
    }
    public func cancelAttachment(_ id: String) {
        guard let index = attachmentDrafts.firstIndex(where: { $0.id == id }),
            [.queued, .uploading].contains(attachmentDrafts[index].status)
        else { return }
        let active = attachmentDrafts[index].status == .uploading
        attachmentDrafts[index].revision += 1
        attachmentDrafts[index].status = .cancelled
        attachmentDrafts[index].error = nil
        if active {
            uploadTask?.cancel()
            uploadTask = nil
        }
        publishAttachments()
        startNextUpload()
    }
    public func retryAttachment(_ id: String) {
        guard canAttach, let i = attachmentDrafts.firstIndex(where: { $0.id == id }),
            [.failed, .cancelled].contains(attachmentDrafts[i].status)
        else { return }
        attachmentDrafts[i].status = .queued
        attachmentDrafts[i].progress = 0
        attachmentDrafts[i].error = nil
        publishAttachments()
        startNextUpload()
    }
    public func removeAttachment(_ id: String) {
        guard !isSending,
            let draft = attachmentDrafts.first(where: { $0.id == id || $0.attachment.id == id })
        else {
            return
        }
        if draft.status == .uploading {
            uploadTask?.cancel()
            uploadTask = nil
        }
        attachmentDrafts.removeAll { $0.id == draft.id }
        if draft.removesSource { Self.removePickerFile(draft.source) }
        publishAttachments()
        startNextUpload()
    }
    func cancelAllUploads() {
        uploadTask?.cancel()
        uploadTask = nil
        for i in attachmentDrafts.indices
        where [.queued, .uploading].contains(attachmentDrafts[i].status) {
            attachmentDrafts[i].revision += 1
            attachmentDrafts[i].status = .cancelled
        }
        publishAttachments()
    }
    func resetAttachments() {
        uploadTask?.cancel()
        uploadTask = nil
        let old = attachmentDrafts
        attachmentDrafts.removeAll()
        pendingAttachments.removeAll()
        old.filter(\.removesSource).forEach { Self.removePickerFile($0.source) }
        isUploadingAttachment = false
        uploadingFilename = nil
    }
    private func publishAttachments() {
        pendingAttachments = attachmentDrafts.filter { $0.status == .ready }.map(\.attachment)
        isUploadingAttachment = attachmentDrafts.contains { $0.status == .uploading }
        uploadingFilename = attachmentDrafts.first { $0.status == .uploading }?.attachment.filename
    }
    private func startNextUpload() {
        guard uploadTask == nil, canAttach, let sdk,
            let index = attachmentDrafts.firstIndex(where: { $0.status == .queued })
        else { return }
        attachmentDrafts[index].status = .uploading
        let draft = attachmentDrafts[index]
        let policy = sdk.configuration.attachments
        publishAttachments()
        uploadTask = Task { [weak self] in
            guard let self else { return }
            let access = draft.source.startAccessingSecurityScopedResource()
            defer { if access { draft.source.stopAccessingSecurityScopedResource() } }
            do {
                let inspection = Task.detached { () throws -> (String, Int64) in
                    let values = try draft.source.resourceValues(forKeys: [
                        .fileSizeKey, .contentTypeKey, .isRegularFileKey,
                    ])
                    guard values.isRegularFile == true else {
                        throw AttachmentError("Select a file, not a folder")
                    }
                    let mime =
                        UTType(filenameExtension: draft.source.pathExtension)?.preferredMIMEType ?? values
                        .contentType?
                        .preferredMIMEType ?? "application/octet-stream"
                    let size = Int64(values.fileSize ?? 0)
                    guard policy.accepts(mimeType: mime, sizeBytes: size) else {
                        throw AttachmentError(
                            "This file type or size is not allowed (maximum \(ByteCountFormatter.string(fromByteCount: policy.maxFileSizeBytes, countStyle: .file)))."
                        )
                    }
                    return (mime, size)
                }
                let (mime, size) = try await inspection.value
                try Task.checkCancellation()
                guard let i = self.currentDraft(draft), self.sdk === sdk else { return }
                self.attachmentDrafts[i].attachment = ChatAttachment(
                    id: "", filename: draft.source.lastPathComponent, mimeType: mime, sizeBytes: size)
                let id = try await sdk.uploadAttachment(fileURL: draft.source, contentType: mime) {
                    [weak self] progress in
                    Task { @MainActor in
                        guard let self, let i = self.currentDraft(draft) else { return }
                        self.attachmentDrafts[i].progress = progress
                    }
                }
                try Task.checkCancellation()
                guard let i = self.currentDraft(draft), self.sdk === sdk else { return }
                self.attachmentDrafts[i].attachment = ChatAttachment(
                    id: id, filename: draft.source.lastPathComponent, mimeType: mime, sizeBytes: size)
                self.attachmentDrafts[i].status = .ready
                self.attachmentDrafts[i].progress = 1
            } catch {
                guard let i = self.currentDraft(draft) else { return }
                self.attachmentDrafts[i].status = Task.isCancelled ? .cancelled : .failed
                self.attachmentDrafts[i].error = Task.isCancelled ? nil : error.localizedDescription
                if let error = error as? AttachmentError, error.status == 404 || error.status == 405 {
                    self.attachmentsUnavailable = true
                    self.attachmentsAllowed = false
                    self.cancelAllUploads()
                }
            }
            guard self.currentDraft(draft) != nil else { return }
            self.uploadTask = nil
            self.publishAttachments()
            self.startNextUpload()
        }
    }
    private func currentDraft(_ draft: AttachmentDraft) -> Int? {
        attachmentDrafts.firstIndex {
            $0.id == draft.id && $0.revision == draft.revision && $0.sessionId == sdk?.getSessionId()
        }
    }
    public func attachments(for message: Message) -> [ChatAttachment] {
        sentAttachments[message.id] ?? ChatAttachment.from(message)
    }
    public func attachmentDownloadURL(_ attachment: ChatAttachment) async -> URL? {
        guard !attachment.deliveryFailed, let sdk else { return nil }
        do { return try await sdk.resolveAttachmentDownloadURL(attachmentId: attachment.id) } catch {
            errorMessage = strings(error.localizedDescription)
            return nil
        }
    }
    private static func removePickerFile(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        guard
            folder.lastPathComponent.hasPrefix("ArtemisPhoto-")
                || folder.lastPathComponent.hasPrefix("ArtemisCamera-"),
            folder.deletingLastPathComponent().standardizedFileURL
                == FileManager.default.temporaryDirectory.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
