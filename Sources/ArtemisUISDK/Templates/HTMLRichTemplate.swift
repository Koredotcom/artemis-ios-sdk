import SwiftUI

struct HTMLRichTemplate: View {
    let content: String
    let isUserMessage: Bool

    var body: some View {
        SafeHTMLView(content: content, isUserMessage: isUserMessage)
    }
}
