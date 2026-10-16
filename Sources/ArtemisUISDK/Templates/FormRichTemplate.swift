#if canImport(ArtemisSocketSDK)
import ArtemisSocketSDK
#endif
import Foundation
import SwiftUI

struct FormRichTemplate: View {
    let form: FormTemplate
    let messageId: String
    let context: RichTemplateContext
    @State private var values: [String: String] = [:]
    @State private var submitted = false
    @State private var pending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title = form.title, !title.templateTrimmed.isEmpty {
                Text(title).templateTitle()
            }
            ForEach(form.fields) { field in
                FieldView(
                    field: field, value: binding(for: field), accentColor: context.accentColor, submitted: submitted)
            }
            Button(form.submitLabel ?? "Submit") {
                pending = true
                error = nil
                Task {
                    defer { pending = false }
                    do {
                        try await context.perform(
                            "form-submit", value: encodeFormSubmitPayload(resolvedValues), formData: resolvedValues,
                            renderId: messageId)
                        submitted = true
                    } catch { self.error = "Form could not be sent. Please retry." }
                }
            }
            .buttonStyle(FilledCapsuleButtonStyle(accentColor: context.accentColor))
            .disabled(!isValid || submitted || pending || context.submittedActionId != nil)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
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
        Dictionary(uniqueKeysWithValues: form.fields.map { ($0.id, values[$0.id] ?? $0.value ?? "") })
    }

    private var isValid: Bool {
        form.fields.allSatisfy { !$0.required || !(values[$0.id] ?? $0.value ?? "").templateTrimmed.isEmpty }
    }

    private func binding(for field: FormTemplateField) -> Binding<String> {
        Binding(get: { values[field.id] ?? field.value ?? "" }, set: { values[field.id] = $0 })
    }

    private struct FieldView: View {
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
                                        .foregroundStyle(TemplateStyle.mutedText)
                                }
                                Text(selectedLabel)
                                    .foregroundStyle(value.isEmpty ? TemplateStyle.mutedText : TemplateStyle.text)
                            }
                            Spacer()
                            Image(systemName: "chevron.down").foregroundStyle(TemplateStyle.mutedText)
                        }
                        .templateInputBorder(accentColor: accentColor, focused: !value.isEmpty)
                    }
                    .disabled(submitted)
                } else {
                    TextField(field.placeholder ?? field.label, text: $value)
                        .formKeyboardType(field.inputType)
                        .disabled(submitted)
                        .templateTextField(accentColor: accentColor)
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
