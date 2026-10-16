import SwiftUI

struct HTMLRichTemplate: View {
    @Environment(\.chatStrings) private var strings
    let content: String
    let accentColor: Color

    var body: some View {
        SafeHTMLView(content: content).templateCard()
    }
}
