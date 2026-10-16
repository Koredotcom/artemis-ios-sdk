import SwiftUI

struct ChatTranscriptBackground: View {
    let theme: ChatTheme?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(hexString: theme?.backgroundColor ?? "#FFFFFF")
                if let url = theme?.backgroundImageURL {
                    TemplateRemoteImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
