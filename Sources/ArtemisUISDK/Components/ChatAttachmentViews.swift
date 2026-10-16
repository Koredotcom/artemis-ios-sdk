import SwiftUI

struct AttachmentDraftCard: View {
    @Environment(\.chatStrings) private var strings
    let draft: AttachmentDraft
    let canRetry: Bool
    let canRemove: Bool
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                FileTypeIcon(attachment: draft.attachment, isUser: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.attachment.filename).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(statusLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onRemove) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).disabled(!canRemove).accessibilityLabel(
                        strings.format("Remove {filename}", ["filename": draft.attachment.filename]))
            }
            if draft.status == .uploading {
                ProgressView(value: draft.progress).frame(maxWidth: .infinity)
            }
            if let error = draft.error { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2) }
            if draft.status == .uploading || draft.status == .queued {
                Button(strings("Cancel upload"), action: onCancel).font(.caption).frame(minHeight: 44)
            } else if draft.status == .failed || draft.status == .cancelled {
                Button(strings("Retry upload"), action: onRetry).font(.caption).frame(minHeight: 44)
                    .disabled(!canRetry)
            }
        }
        .padding(10).frame(width: 250, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
        .accessibilityElement(children: .contain)
    }
    private var statusLabel: String {
        switch draft.status {
        case .queued: return strings("Queued")
        case .uploading:
            return strings.format("Uploading {percent}%", ["percent": String(Int(draft.progress * 100))])
        case .ready: return strings("Ready to send") + " • " + draft.attachment.detail
        case .failed: return strings("Upload failed")
        case .cancelled: return strings("Cancelled")
        }
    }
}

struct FileTypeIcon: View {
    @Environment(\.chatStrings) private var strings
    let attachment: ChatAttachment
    let isUser: Bool
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: attachment.icon).font(.system(size: 20))
            Text(attachment.fileType).font(.system(size: 8, weight: .bold)).lineLimit(1)
        }.frame(width: 36).foregroundStyle(isUser ? Color.white : accent).accessibilityHidden(true)
    }
    private var accent: Color {
        switch attachment.fileType {
        case "PDF": return .red
        case "DOC", "DOCX": return .blue
        case "PNG", "JPG", "JPEG": return .teal
        case "XLS", "XLSX": return .green
        case "PPT", "PPTX": return .orange
        default: return .secondary
        }
    }
}

struct AttachmentMessageGroup: View {
    @Environment(\.chatStrings) private var strings
    let attachments: [ChatAttachment]
    let isUser: Bool
    let resolve: (ChatAttachment) async -> URL?
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if attachments.count > 1 {
                Button {
                    expanded.toggle()
                } label: {
                    HStack {
                        Image(systemName: "paperclip")
                        Text(strings.format("{count} attachments", ["count": String(attachments.count)])).font(
                            .subheadline.weight(.semibold))
                        if attachments.contains(where: \.deliveryFailed) {
                            Text(strings("Delivery failed")).font(.caption)
                        }
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }.frame(minHeight: 44)
                }.buttonStyle(.plain).accessibilityLabel(
                    strings.format(
                        expanded ? "Collapse {count} attachments" : "Expand {count} attachments",
                        ["count": String(attachments.count)]))
            }
            if attachments.count == 1 || expanded {
                ForEach(attachments) { attachment in
                    AttachmentMessageRow(attachment: attachment, isUser: isUser, resolve: resolve)
                }
            }
        }
    }
}
private struct AttachmentMessageRow: View {
    @Environment(\.chatStrings) private var strings
    let attachment: ChatAttachment
    let isUser: Bool
    let resolve: (ChatAttachment) async -> URL?
    @Environment(\.openURL) private var openURL
    @State private var opening = false
    var body: some View {
        Button {
            opening = true
            Task {
                defer { opening = false }
                if let url = await resolve(attachment) { openURL(url) }
            }
        } label: {
            HStack(spacing: 8) {
                FileTypeIcon(attachment: attachment, isUser: isUser)
                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.filename).font(.subheadline.weight(.semibold)).lineLimit(1)
                        .truncationMode(.middle)
                    Text(attachment.deliveryFailed ? "Delivery failed" : attachment.detail).font(.caption2)
                        .opacity(0.8)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if opening {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 18)).frame(
                        width: 44, height: 44)
                }
            }.padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(opening || attachment.deliveryFailed)
            .accessibilityLabel(
                "\(attachment.filename), \(attachment.detail), \(attachment.deliveryFailed ? "delivery failed" : "download")"
            )
    }
}
