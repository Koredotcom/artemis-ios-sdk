import SwiftUI

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

struct ActionsRichTemplate: View {
    @Environment(\.chatStrings) private var strings
    @Environment(\.chatTheme) private var theme
    let actions: ActionSet
    let context: RichTemplateContext
    @State private var values: [String: String] = [:]
    @State private var pending = false
    @State private var selected: String?
    @State private var error: String?
    @FocusState private var focusedInput: String?
    @Environment(\.openURL) private var openURL
    private var locked: Bool { pending || selected != nil || actions.submittedActionId != nil }
    private var palette: TemplatePalette { TemplatePalette(theme: theme) }
    private var scale: CGFloat { theme?.spacingScale ?? 1 }
    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            let buttons = actions.elements.filter { $0.type != "input" && $0.type != "select" }
            if !buttons.isEmpty {
                TemplateFlowRow(buttons, spacing: 6 * scale, verticalSpacing: 6 * scale + 5) { element in
                    Button {
                        guard !locked else { return }
                        if let raw = element.url, let url = URL(string: raw), url.isHTTP {
                            openURL(url)
                        } else {
                            submit(element.id, value: element.value ?? element.label, displayText: element.label)
                        }
                    } label: {
                        Text(verbatim: element.label)
                    }.buttonStyle(
                        TemplateControlButtonStyle(
                            accentColor: context.accentColor,
                            variant: .action,
                            isSelected: (selected ?? actions.submittedActionId) == element.id)
                    )
                    .disabled(locked)
                    .accessibilityLabel(element.label)
                }
            }
            ForEach(actions.elements.filter { $0.type == "select" }) { element in
                VStack(alignment: .leading, spacing: 4 * scale) {
                    fieldLabel(element.label)
                    Menu {
                        ForEach(element.options) { option in
                            Button(option.label) { binding(for: element).wrappedValue = option.id }
                        }
                    } label: {
                        HStack {
                            let value = binding(for: element).wrappedValue
                            Text(
                                verbatim: element.options.first(where: { $0.id == value })?.label
                                    ?? element.placeholder ?? strings("Select"))
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        }
                        .font(theme?.font(size: 13) ?? .system(size: 13))
                        .foregroundStyle(palette.text)
                        .padding(.horizontal, 12 * scale).padding(.vertical, 8 * scale)
                        .frame(minHeight: 40 * scale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hexString: theme?.backgroundColor ?? "#FFFFFF"))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(locked).accessibilityLabel(element.label)
                    .accessibilityValue(
                        element.options.first(where: { $0.id == binding(for: element).wrappedValue })?.label
                            ?? element.placeholder ?? strings("Select")
                    )
                    .onChange(of: values[element.id] ?? "") { value in
                        if !value.isEmpty, actions.submitId == nil { submit(element.id, value: value) }
                    }
                }
            }
            ForEach(actions.elements.filter { $0.type == "input" }) { element in
                VStack(alignment: .leading, spacing: 4 * scale) {
                    fieldLabel(element.label)
                    TextField(element.placeholder ?? "", text: binding(for: element))
                        .textFieldStyle(.plain)
                        .font(theme?.font(size: 13) ?? .system(size: 13))
                        .foregroundStyle(palette.text)
                        .formKeyboardType(element.inputType)
                        .focused($focusedInput, equals: element.id)
                        .padding(.horizontal, 12 * scale).padding(.vertical, 8 * scale)
                        .frame(minHeight: 40 * scale)
                        .background(Color(hexString: theme?.backgroundColor ?? "#FFFFFF"))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8).stroke(
                                focusedInput == element.id ? context.accentColor : palette.border, lineWidth: 1)
                        }
                        .disabled(locked).accessibilityLabel(element.label)
                }
            }
            if let submitId = actions.submitId {
                Button(actions.submitLabel ?? strings("Submit")) { submit(submitId, formData: values) }
                    .buttonStyle(TemplateControlButtonStyle(accentColor: context.accentColor, variant: .submit))
                    .disabled(locked || !valid)
                    .padding(.top, 4 * scale)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strings("Actions"))
        .onAppear {
            if values.isEmpty { values = context.presentation?.values(for: context.message.id) ?? [:] }
        }
        .onChange(of: values) { context.presentation?.save($0, for: context.message.id) }
    }
    private func fieldLabel(_ label: String) -> some View {
        Text(verbatim: label)
            .font(theme?.font(size: 12, weight: .medium) ?? .system(size: 12, weight: .medium))
            .foregroundStyle(palette.mutedText)
    }
    private var valid: Bool {
        actions.elements.allSatisfy {
            !$0.required || !(values[$0.id] ?? $0.value ?? "").templateTrimmed.isEmpty
        }
    }
    private func binding(for element: ActionElement) -> Binding<String> {
        Binding(get: { values[element.id] ?? element.value ?? "" }, set: { values[element.id] = $0 })
    }
    private func submit(
        _ id: String, value: String? = nil, formData: [String: String]? = nil,
        displayText: String? = nil
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
            } catch { self.error = strings("Action could not be sent. Please retry.") }
        }
    }
}
