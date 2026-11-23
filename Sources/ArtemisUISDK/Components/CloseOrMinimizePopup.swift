import SwiftUI

struct CloseOrMinimizePopup: View {
    let canMinimize: Bool
    let localeIdentifier: String
    let fallbackLocaleIdentifier: String
    let onCancel: () -> Void
    let onClose: () -> Void
    let onMinimize: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                Text(popupString(
                    canMinimize
                        ? "Would you like to close or minimize this chat?"
                        : "Would you like to close this chat?"))
                    .font(.system(size: 15))
                    .foregroundStyle(Color(white: 0.2))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(20)

                Rectangle()
                    .fill(Color(white: 0.88))
                    .frame(height: 0.5)

                HStack(spacing: 0) {
                    action(popupString("Cancel"), action: onCancel)
                    divider
                    action(popupString("Close"), action: onClose)
                    if canMinimize {
                        divider
                        action(popupString("Minimize"), action: onMinimize)
                    }
                }
                .frame(height: 48)
            }
            .frame(maxWidth: 320)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
            .padding(.horizontal, 32)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
            .accessibilityAddTraits(.isModal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(white: 0.88))
            .frame(width: 0.5, height: 32)
    }

    private func action(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(red: 0.25, green: 0.39, blue: 0.83))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func popupString(_ key: String) -> String {
        NSLocalizedString(
            key, tableName: "Localizable",
            bundle: CloseOrMinimizePopupBundle.bundle(
                for: localeIdentifier, fallback: fallbackLocaleIdentifier),
            value: key, comment: "")
    }
}

private enum CloseOrMinimizePopupBundle {
    private static let resourceBundle: Bundle = {
        #if SWIFT_PACKAGE
            return .module
        #else
            let containingBundle = Bundle(for: CloseOrMinimizePopupBundleToken.self)
            if let url = containingBundle.url(forResource: "ArtemisUISDK_Resources", withExtension: "bundle"),
                let resources = Bundle(url: url)
            {
                return resources
            }
            return containingBundle
        #endif
    }()

    static func bundle(for localeIdentifier: String, fallback: String) -> Bundle {
        func localeCandidates(_ identifier: String) -> [String] {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-")
            let languageCode = String(normalized.prefix(while: { $0 != "-" }))
            return [normalized, languageCode]
        }
        let candidates = localeCandidates(localeIdentifier) + localeCandidates(fallback) + ["en"]
        var visited = Set<String>()
        for locale in candidates where visited.insert(locale).inserted {
            if let path = resourceBundle.path(forResource: locale, ofType: "lproj"),
                let localizedBundle = Bundle(path: path)
            {
                return localizedBundle
            }
        }
        return resourceBundle
    }
}

#if !SWIFT_PACKAGE
private final class CloseOrMinimizePopupBundleToken: NSObject {}
#endif
