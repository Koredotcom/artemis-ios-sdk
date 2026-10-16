import SwiftUI

struct VideoRichTemplate: View {
    let media: MediaContent
    let accentColor: Color

    var body: some View {
        InlineVideoPlayer(media: media)
    }
}
