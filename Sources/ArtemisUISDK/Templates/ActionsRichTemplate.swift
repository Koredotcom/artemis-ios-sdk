#if canImport(ArtemisSocketSDK)
import ArtemisSocketSDK
#endif
import SwiftUI

struct ActionsRichTemplate: View {
    let actions: ActionSet
    let context: RichTemplateContext
    @State private var values: [String: String] = [:]
    @State private var pending = false
    @State private var selected: String?
    @State private var error: String?
    @Environment(\.openURL) private var openURL
    private var locked: Bool { pending || selected != nil || actions.submittedActionId != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(actions.elements) { element in
                switch element.type {
                case "select":
                    Picker(element.label, selection: binding(for: element)) {
                        Text(element.placeholder ?? "Select").tag("")
                        ForEach(element.options) { Text($0.label).tag($0.id) }
                    }.disabled(locked)
                        .onChange(of: values[element.id] ?? "") { value in
                            if !value.isEmpty, actions.submitId == nil { submit(element.id, value: value) }
                        }
                case "input":
                    TextField(element.placeholder ?? element.label, text: binding(for: element)).templateTextField(
                        accentColor: context.accentColor
                    ).disabled(locked)
                default:
                    Button(element.label) {
                        if let raw = element.url, let url = URL(string: raw), url.isHTTP {
                            openURL(url)
                        } else {
                            submit(element.id, value: element.value ?? element.label, displayText: element.label)
                        }
                    }
                    .buttonStyle(
                        OutlinedPillButtonStyle(
                            accentColor: context.accentColor,
                            isSelected: (selected ?? actions.submittedActionId) == element.id)
                    )
                    .disabled(locked)
                }
            }
            if let submitId = actions.submitId {
                Button(actions.submitLabel ?? "Submit") { submit(submitId, formData: values) }
                    .buttonStyle(FilledCapsuleButtonStyle(accentColor: context.accentColor)).disabled(locked || !valid)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { if values.isEmpty { values = context.presentation?.values(for: context.message.id) ?? [:] } }
        .onChange(of: values) { context.presentation?.save($0, for: context.message.id) }
    }
    private var valid: Bool {
        actions.elements.allSatisfy { !$0.required || !(values[$0.id] ?? $0.value ?? "").templateTrimmed.isEmpty }
    }
    private func binding(for element: ActionElement) -> Binding<String> {
        Binding(get: { values[element.id] ?? element.value ?? "" }, set: { values[element.id] = $0 })
    }
    private func submit(
        _ id: String, value: String? = nil, formData: [String: String]? = nil, displayText: String? = nil
    ) {
        guard !locked else { return }
        pending = true
        error = nil
        Task {
            defer { pending = false }
            do {
                try await context.perform(
                    id, value: value, formData: formData, renderId: actions.renderId ?? context.message.id,
                    displayText: displayText)
                selected = id
            } catch { self.error = "Action could not be sent. Please retry." }
        }
    }
}
