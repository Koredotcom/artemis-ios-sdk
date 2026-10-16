import Foundation
import SwiftUI

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

struct FormRichTemplate: View {
    @Environment(\.chatTheme) private var chatTheme
    private var templateStyle: TemplatePalette { TemplatePalette(theme: chatTheme) }
    @Environment(\.chatStrings) private var strings
    let form: FormTemplate
    let messageId: String
    let context: RichTemplateContext
    @State private var values: [String: String] = [:]
    @State private var submitted = false
    @State private var pending = false
    @State private var error: String?
    @State private var showErrors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title = form.title, !title.templateTrimmed.isEmpty {
                Text(title).templateTitle()
            }
            ForEach(form.fields) { field in
                if field.type == "button" {
                    Button(field.label) {
                        pending = true
                        Task {
                            defer { pending = false }
                            do {
                                try await context.perform(field.id, value: field.value, renderId: messageId)
                                submitted = true
                            } catch { self.error = strings("Form could not be sent. Please retry.") }
                        }
                    }.disabled(locked)
                } else {
                    FieldView(
                        field: field, value: binding(for: field), accentColor: context.accentColor,
                        submitted: locked)
                    if let error = validationErrors[field.id], showErrors || !(values[field.id] ?? "").isEmpty {
                        Text(strings(error)).font(.caption).foregroundStyle(.red).accessibilityLabel(
                            field.label + ": " + strings(error))
                    }
                }
            }
            Button(form.submitLabel ?? strings("Submit")) {
                showErrors = true
                guard validationErrors.isEmpty else { return }
                pending = true
                error = nil
                Task {
                    defer { pending = false }
                    do {
                        try await context.perform(
                            "form-submit", value: encodeFormSubmitPayload(resolvedValues),
                            formData: resolvedValues,
                            renderId: messageId)
                        submitted = true
                    } catch { self.error = strings("Form could not be sent. Please retry.") }
                }
            }
            .buttonStyle(FilledCapsuleButtonStyle(accentColor: context.accentColor))
            .disabled(locked)
            if let error { Text(strings(error)).font(.caption).foregroundStyle(.red) }
        }
        .templateCard(padding: 18)
        .onAppear {
            if values.isEmpty { values = context.presentation?.values(for: messageId) ?? [:] }
            for field in form.fields where values[field.id] == nil {
                values[field.id] = field.value ?? ""
            }
        }
        .onChange(of: values) { context.presentation?.save($0, for: messageId) }
    }

    private var resolvedValues: [String: String] {
        Dictionary(
            form.fields.filter { $0.type != "button" }.map { ($0.id, values[$0.id] ?? $0.value ?? "") },
            uniquingKeysWith: { _, last in last })
    }

    private var locked: Bool { submitted || pending || context.submittedActionId != nil }
    private var validationErrors: [String: String] {
        Dictionary(
            form.fields.filter { $0.type != "button" }.compactMap { field in
                FormFieldValidation.error(
                    value: resolvedValues[field.id] ?? "", required: field.required,
                    inputType: field.inputType,
                    allowedOptions: field.type == "select" ? field.options.map(\.id) : nil
                )
                .map { (field.id, $0) }
            }, uniquingKeysWith: { _, last in last })
    }

    private func binding(for field: FormTemplateField) -> Binding<String> {
        Binding(get: { values[field.id] ?? field.value ?? "" }, set: { values[field.id] = $0 })
    }

    private struct FieldView: View {
        @Environment(\.chatTheme) private var chatTheme
        private var templateStyle: TemplatePalette { TemplatePalette(theme: chatTheme) }
        @Environment(\.chatStrings) private var strings
        let field: FormTemplateField
        @Binding var value: String
        let accentColor: Color
        let submitted: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if field.type == "select", !field.options.isEmpty {
                    Menu {
                        ForEach(field.options) { option in
                            Button(option.label) { value = option.id }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                if !value.isEmpty {
                                    Text(field.label + (field.required ? " *" : "")).font(.caption2.weight(.semibold))
                                        .foregroundStyle(templateStyle.mutedText)
                                }
                                Text(selectedLabel)
                                    .foregroundStyle(value.isEmpty ? templateStyle.mutedText : templateStyle.text)
                            }
                            Spacer()
                            Image(systemName: "chevron.down").foregroundStyle(templateStyle.mutedText)
                        }
                        .templateInputBorder(accentColor: accentColor, focused: !value.isEmpty)
                    }
                    .disabled(submitted)
                } else {
                    TypedFormInput(
                        label: field.label, placeholder: field.placeholder, inputType: field.inputType,
                        value: $value, accentColor: accentColor
                    ).disabled(submitted)
                }
            }
        }

        private var selectedLabel: String {
            field.options.first { $0.id == value }?.label ?? field.placeholder ?? field.label
        }

    }
}

private func encodeFormSubmitPayload(_ values: [String: String]) -> String {
    guard JSONSerialization.isValidJSONObject(values),
        let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
        let encoded = String(data: data, encoding: .utf8)
    else {
        return "{}"
    }
    return encoded
}
