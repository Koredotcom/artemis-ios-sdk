import SwiftUI

struct AudioRichTemplate: View {
    let media: MediaContent
    let accentColor: Color

    var body: some View {
        InlineAudioPlayer(media: media)
    }
}
