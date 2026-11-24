import Foundation
import SwiftUI

enum FormFieldValidation {
    static func error(
        value: String, required: Bool, inputType: String?, allowedOptions: [String]? = nil
    ) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return required ? "validation.required" : nil }
        if let allowedOptions, !allowedOptions.contains(value) { return "validation.option" }
        switch inputType {
        case "number":
            if Double(value)?.isFinite != true { return "validation.number" }
        case "email":
            let pattern =
                #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*$"#
            if value.range(of: pattern, options: .regularExpression) == nil { return "validation.email" }
        case "date", "time":
            if parse(value, type: inputType!) == nil { return "validation." + inputType! }
        default: break
        }
        return nil
    }

    static func formatter(type: String, timeZone: TimeZone = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = type == "date" ? "yyyy-MM-dd" : "HH:mm"
        formatter.isLenient = false
        return formatter
    }

    static func parse(_ value: String, type: String, timeZone: TimeZone = .current) -> Date? {
        let formatter = formatter(type: type, timeZone: timeZone)
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            return nil
        }
        return date
    }
}

struct TypedFormInput: View {
    @Environment(\.timeZone) private var timeZone
    @Environment(\.chatTheme) private var theme
    @Environment(\.chatStrings) private var strings
    @FocusState private var isFocused: Bool

    let label: String
    let placeholder: String?
    let inputType: String?
    @Binding var value: String
    let accentColor: Color
    var onSubmit: () -> Void = {}

    var body: some View {
        if inputType == "date" || inputType == "time" {
            HStack(spacing: 8) {
                if value.isEmpty {
                    Button {
                        value = FormFieldValidation.formatter(type: inputType!, timeZone: timeZone)
                            .string(from: Date())
                    } label: {
                        HStack {
                            Text(placeholder ?? label)
                                .foregroundStyle(Color(hexString: theme?.mutedTextColor ?? "#64748B"))
                            Spacer(minLength: 0)
                            Image(systemName: "calendar")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color(hexString: theme?.mutedTextColor ?? "#64748B"))
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    DatePicker(
                        "", selection: date,
                        displayedComponents: inputType == "date" ? [.date] : [.hourAndMinute])
                    .labelsHidden()
                    Spacer(minLength: 0)
                    Button {
                        value = ""
                    } label: {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(Color(hexString: theme?.mutedTextColor ?? "#64748B"))
                    }
                    .accessibilityLabel(strings.format("Clear {field}", ["field": label]))
                }
            }
            .richTemplateInput(accentColor: accentColor, focused: isFocused)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
        } else if inputType == "password" {
            SecureField(placeholder ?? label, text: $value)
                .focused($isFocused)
                .formKeyboardType(inputType)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .onSubmit(onSubmit)
                .accessibilityLabel(label)
                .richTemplateInput(accentColor: accentColor, focused: isFocused)
        } else {
            TextField(placeholder ?? label, text: $value)
                .focused($isFocused)
                .formKeyboardType(inputType)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(inputType == "email" ? .never : .sentences)
                .autocorrectionDisabled(inputType == "email")
                .submitLabel(.done)
                .onSubmit(onSubmit)
                .accessibilityLabel(label)
                .richTemplateInput(accentColor: accentColor, focused: isFocused)
        }
    }

    private var date: Binding<Date> {
        Binding(
            get: { FormFieldValidation.parse(value, type: inputType!, timeZone: timeZone) ?? Date() },
            set: { value = FormFieldValidation.formatter(type: inputType!, timeZone: timeZone).string(from: $0) })
    }
}
