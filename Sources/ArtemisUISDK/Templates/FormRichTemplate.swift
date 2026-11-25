import Foundation
import SwiftUI

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

struct FormRichTemplate: View {
    @Environment(\.chatTheme) private var chatTheme
    @Environment(\.chatStrings) private var strings
    private var templateStyle: TemplatePalette { TemplatePalette(theme: chatTheme) }
    private var actionRenderId: String? { context.message.actions?.renderId }

    let form: FormTemplate
    let messageId: String
    let context: RichTemplateContext
    @State private var values: [String: String] = [:]
    @State private var submitted = false
    @State private var pending = false
    @State private var error: String?
    @State private var showErrors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = form.title, !title.templateTrimmed.isEmpty {
                Text(title)
                    .font(chatTheme?.font(size: 15, weight: .semibold) ?? .system(size: 15, weight: .semibold))
                    .foregroundStyle(templateStyle.text)
            }
            ForEach(form.fields) { field in
                if field.type != "input" && field.type != "select" {
                    Button(field.label) {
                        pending = true
                        Task {
                            defer { pending = false }
                            do {
                                try await context.perform(
                                    field.id, value: field.value ?? field.id, renderId: actionRenderId)
                                submitted = true
                            } catch { self.error = strings("Form could not be sent. Please retry.") }
                        }
                    }
                    .buttonStyle(RichTemplateButtonStyle(accentColor: context.accentColor, variant: .outline))
                    .disabled(locked)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(field.label)
                            .font(chatTheme?.font(size: 15, weight: .medium) ?? .system(size: 15, weight: .medium))
                            .foregroundStyle(templateStyle.mutedText)
                        if field.type == "select" {
                            Menu {
                                ForEach(field.options) { option in
                                    Button(option.label) { values[field.id] = option.id }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(selectedLabel(for: field))
                                        .foregroundStyle((values[field.id] ?? "").isEmpty
                                            ? templateStyle.mutedText : templateStyle.text)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(templateStyle.mutedText)
                                }
                                .richTemplateInput(accentColor: context.accentColor)
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .disabled(locked || field.options.isEmpty)
                        } else {
                            TypedFormInput(
                                label: field.label, placeholder: field.placeholder,
                                inputType: field.inputType, value: binding(for: field),
                                accentColor: context.accentColor)
                            .disabled(locked)
                        }
                        if let validationError = validationErrors[field.id],
                            showErrors || !(values[field.id] ?? "").isEmpty
                        {
                            Text(strings(validationError))
                                .font(chatTheme?.font(size: 12) ?? .system(size: 12))
                                .foregroundStyle(.red)
                                .accessibilityLabel(field.label + ": " + strings(validationError))
                        }
                    }
                }
            }
            Button {
                guard !locked else { return }
                showErrors = true
                guard validationErrors.isEmpty else { return }
                pending = true
                error = nil
                Task {
                    defer { pending = false }
                    do {
                        try await context.perform(
                            "form-submit",
                            value: encodeFormSubmitPayload(fields: form.fields, values: resolvedValues),
                            formData: resolvedValues, renderId: actionRenderId)
                        submitted = true
                    } catch { self.error = strings("Form could not be sent. Please retry.") }
                }
            } label: {
                HStack(spacing: 8) {
                    if pending { ProgressView().controlSize(.small).tint(.white) }
                    Text(form.submitLabel ?? strings("Submit"))
                }
            }
            .buttonStyle(RichTemplateButtonStyle(
                accentColor: context.accentColor, variant: .primary, minimumHeight: 40,
                fontWeight: .semibold))
            .disabled(locked)
            if let error {
                Text(strings(error))
                    .font(chatTheme?.font(size: 12) ?? .system(size: 12))
                    .foregroundStyle(.red)
            }
        }
        .richTemplateCard()
        .padding(.top, 8)
        .onAppear {
            if values.isEmpty { values = context.presentation?.values(for: messageId) ?? [:] }
            for field in form.fields where values[field.id] == nil {
                values[field.id] = ""
            }
        }
        .onChange(of: values) { context.presentation?.save($0, for: messageId) }
    }

    private var resolvedValues: [String: String] {
        Dictionary(
            form.fields.filter { $0.type == "input" || $0.type == "select" }
                .map { ($0.id, values[$0.id] ?? "") },
            uniquingKeysWith: { _, last in last })
    }

    private var locked: Bool {
        submitted || pending || context.submittedActionId != nil
            || !context.submittedActionIds.isEmpty
    }

    private var validationErrors: [String: String] {
        Dictionary(
            form.fields.filter { $0.type == "input" || $0.type == "select" }.compactMap { field in
                FormFieldValidation.error(
                    value: resolvedValues[field.id] ?? "", required: field.required,
                    inputType: field.inputType,
                    allowedOptions: field.type == "select" ? field.options.map(\.id) : nil
                ).map { (field.id, $0) }
            }, uniquingKeysWith: { _, last in last })
    }

    private func binding(for field: FormTemplateField) -> Binding<String> {
        Binding(get: { values[field.id] ?? "" }, set: { values[field.id] = $0 })
    }

    private func selectedLabel(for field: FormTemplateField) -> String {
        field.options.first { $0.id == (values[field.id] ?? "") }?.label
            ?? field.placeholder ?? (field.label.isEmpty ? strings("Select...") : field.label)
    }
}

private func encodeFormSubmitPayload(
    fields: [FormTemplateField], values: [String: String]
) -> String {
    // Web's JSON.stringify preserves control order for string keys, while
    // JavaScript enumerates canonical integer-like keys first in numeric order.
    var fieldOrder: [String] = []
    var orderedValues: [String: String] = [:]
    for field in fields where field.type == "input" || field.type == "select" {
        if orderedValues[field.id] == nil { fieldOrder.append(field.id) }
        orderedValues[field.id] = values[field.id] ?? ""
    }

    let integerKeys = fieldOrder.compactMap { fieldId -> (String, UInt32)? in
        guard let index = UInt32(fieldId), index < UInt32.max, String(index) == fieldId else {
            return nil
        }
        return (fieldId, index)
    }.sorted { $0.1 < $1.1 }.map { $0.0 }
    let stringKeys = fieldOrder.filter { fieldId in
        !(UInt32(fieldId).map { $0 < UInt32.max && String($0) == fieldId } ?? false)
    }

    let pairs = (integerKeys + stringKeys).map { fieldId in
        "\(jsonStringLiteral(fieldId)):\(jsonStringLiteral(orderedValues[fieldId] ?? ""))"
    }
    return "{\(pairs.joined(separator: ","))}"
}

private func jsonStringLiteral(_ value: String) -> String {
    var encoded = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x22: encoded += "\\\""
        case 0x5C: encoded += "\\\\"
        case 0x08: encoded += "\\b"
        case 0x0C: encoded += "\\f"
        case 0x0A: encoded += "\\n"
        case 0x0D: encoded += "\\r"
        case 0x09: encoded += "\\t"
        case 0x00..<0x20: encoded += String(format: "\\u%04x", scalar.value)
        default: encoded.unicodeScalars.append(scalar)
        }
    }
    encoded += "\""
    return encoded
}
