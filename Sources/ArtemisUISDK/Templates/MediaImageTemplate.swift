#if canImport(ArtemisSocketSDK)
import ArtemisSocketSDK
#endif
import Foundation
import SwiftUI

struct MediaImageTemplate: View {
    let image: MediaContent
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = URL(string: image.url), url.isHTTP {
                Link(destination: url) {
                    TemplateRemoteImage(url: url) { loaded in
                        loaded.resizable().scaledToFill()
                    } placeholder: {
                        PlaceholderIcon(systemImage: "photo", accentColor: accentColor)
                    }
                    .frame(maxWidth: .infinity, minHeight: 170, maxHeight: 230)
                    .clipShape(RoundedRectangle(cornerRadius: TemplateStyle.imageRadius))
                }
            }
            if let caption = image.caption ?? image.alt, !caption.templateTrimmed.isEmpty {
                Text(caption).templateSectionLabel()
            }
        }
    }
}
