import SwiftUI

struct ChatHistoryScrollRequest: Equatable {
    let messageCount: Int
    let isTyping: Bool
    let revision: Int
    var forceScrollRevision: Int = 0
}
private struct ChatContentBottom: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// Geometry and gesture bookkeeping do not affect the rendered view. Keeping
// these values out of observable state avoids feeding scroll layout back into
// SwiftUI's layout updates while the keyboard changes the viewport.
private final class ChatScrollMetrics {
    var bottom: CGFloat = 0
    var dragging = false
    var lastForceRevision = 0
}

/// Follows new content only while the reader is at the bottom; sending forces a follow.
struct ChatHistoryScrollView<Content: View>: View {
    let request: ChatHistoryScrollRequest
    @ViewBuilder let content: (CGFloat) -> Content
    @State private var followsLatest = true
    @State private var metrics = ChatScrollMetrics()
    @Namespace private var coordinateSpace
    private enum Anchor: Hashable { case bottom }
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    // Rich messages can be taller than the viewport and contain
                    // their own horizontal scroll views. Eager measurement avoids
                    // LazyVStack's repeating item-phase/geometry updates when
                    // scrolling to these messages or changing keyboard height.
                    VStack(spacing: 12) {
                        content(max(0, geometry.size.width - 32))
                        Color.clear.frame(height: 8).id(Anchor.bottom)
                    }
                    .padding(.horizontal, 16).padding(.top, 16)
                    .background(
                        GeometryReader { contentGeometry in
                            Color.clear.preference(
                                key: ChatContentBottom.self,
                                value: contentGeometry.frame(in: .named(coordinateSpace)).maxY)
                        })
                }
                .coordinateSpace(name: coordinateSpace)
                .simultaneousGesture(
                    DragGesture().onChanged { _ in
                        metrics.dragging = true
                        if followsLatest { followsLatest = false }
                    }
                    .onEnded { _ in
                        metrics.dragging = false
                        updateFollowing(bottom: metrics.bottom, viewportHeight: geometry.size.height)
                    }
                )
                .onPreferenceChange(ChatContentBottom.self) { value in
                    guard value.isFinite else { return }
                    metrics.bottom = value
                    if metrics.dragging { updateFollowing(bottom: value, viewportHeight: geometry.size.height) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest {
                        Button {
                            followsLatest = true
                            proxy.scrollTo(Anchor.bottom, anchor: .bottom)
                        } label: {
                            Label("Latest", systemImage: "arrow.down").font(.caption).padding(10).background(
                                .regularMaterial, in: Capsule())
                        }.padding(12)
                    }
                }
                .task(id: request) {
                    let force = metrics.lastForceRevision != request.forceScrollRevision
                    metrics.lastForceRevision = request.forceScrollRevision
                    if force && !followsLatest { followsLatest = true }
                    guard followsLatest, !metrics.dragging else { return }
                    for pass in 0..<3 {
                        if pass == 0 {
                            await Task.yield()
                        } else {
                            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                        }
                        guard !Task.isCancelled, followsLatest, !metrics.dragging else { return }
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { proxy.scrollTo(Anchor.bottom, anchor: .bottom) }
                    }
                }
            }
        }
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }

    private func updateFollowing(bottom: CGFloat, viewportHeight: CGFloat) {
        let follows = bottom <= viewportHeight + 48
        if followsLatest != follows { followsLatest = follows }
    }
}
