import CoreFoundation
import SwiftUI

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

struct TableRichTemplate: View {
    @Environment(\.chatTheme) private var chatTheme
    @Environment(\.chatStrings) private var strings
    @State private var isExpanded = false
    @State private var availableWidth: CGFloat = 0

    private var templateStyle: TemplatePalette { TemplatePalette(theme: chatTheme) }
    private var tableBackground: Color {
        Color(hexString: chatTheme?.backgroundColor ?? "#FFFFFF")
    }
    private var tableSurface: Color {
        Color(hexString: chatTheme?.surfaceColor ?? "#F3F4F6")
    }

    let table: TableTemplate
    let accentColor: Color

    private var maxVisibleRows: Int { max(0, table.maxVisibleRows ?? 10) }
    private var hasMoreRows: Bool { table.rows.count > maxVisibleRows }
    private var visibleRows: ArraySlice<[String: AnySendable]> {
        isExpanded ? table.rows[...] : table.rows.prefix(maxVisibleRows)
    }
    private var tableWidth: CGFloat {
        max(availableWidth, CGFloat(table.columns.count) * 106)
    }
    private var columnWidth: CGFloat {
        table.columns.isEmpty ? 106 : tableWidth / CGFloat(table.columns.count)
    }

    var body: some View {
        Group {
            if table.columns.isEmpty || table.rows.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(spacing: 0) {
                            headerRow
                            ForEach(Array(visibleRows.enumerated()), id: \.offset) { index, row in
                                dataRow(row, index: index, isLast: index == visibleRows.count - 1)
                            }
                        }
                        .frame(width: tableWidth, alignment: .leading)
                        .background(tableBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(templateStyle.border, lineWidth: 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: TableAvailableWidthKey.self, value: geometry.size.width)
                        }
                    }
                    .onPreferenceChange(TableAvailableWidthKey.self) { width in
                        guard width > 0, abs(width - availableWidth) > 0.5 else { return }
                        availableWidth = width
                    }

                    if hasMoreRows {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Text(strings(isExpanded ? "Show less" : "Show more"))
                                .font(chatTheme?.font(size: 12, weight: .semibold) ?? .system(size: 12, weight: .semibold))
                                .foregroundStyle(accentColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(isExpanded ? strings("Show less") : strings("Show more"))
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(table.columns) { column in
                cell(
                    text: column.header.uppercased(),
                    alignment: cellAlignment(column.align),
                    isHeader: true
                )
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(templateStyle.border).frame(height: 1)
        }
    }

    private func dataRow(_ row: [String: AnySendable], index: Int, isLast: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(table.columns) { column in
                cell(
                    text: tableCellString(row[column.key]?.value),
                    alignment: cellAlignment(column.align),
                    isHeader: false,
                    background: index.isMultiple(of: 2) ? tableBackground : tableSurface.opacity(0.70)
                )
            }
        }
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(templateStyle.border).frame(height: 1)
            }
        }
    }

    private func cell(
        text: String,
        alignment: CellAlignment,
        isHeader: Bool,
        background: Color? = nil
    ) -> some View {
        let cellAlignment = alignment.frameAlignment
        let headerFill = tableSurface.overlay(accentColor.opacity(0.15))

        return Text(text)
            .font(
                chatTheme?.font(size: isHeader ? 11 : 12, weight: isHeader ? .bold : .regular)
                    ?? .system(size: isHeader ? 11 : 12, weight: isHeader ? .bold : .regular)
            )
            .tracking(isHeader ? 0.44 : 0)
            .multilineTextAlignment(alignment.textAlignment)
            .lineSpacing(2)
            .foregroundStyle(templateStyle.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: columnWidth, alignment: cellAlignment)
            .background {
                if isHeader {
                    headerFill
                } else {
                    background ?? tableBackground
                }
            }
    }

    private func cellAlignment(_ rawAlignment: String?) -> CellAlignment {
        switch rawAlignment?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "center": .center
        case "right", "end": .trailing
        case "justify", "justified": .leading
        default: .leading
        }
    }

    /// Mirrors JavaScript's String(value ?? '') behavior used by the Web table renderer.
    private func tableCellString(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if let array = value as? [Any] {
            return array.map { tableCellString($0) }.joined(separator: ",")
        }
        if value is [String: Any] { return "[object Object]" }
        return RichContentParser.displayString(value)
    }
}

private enum CellAlignment {
    case leading
    case center
    case trailing

    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

private struct TableAvailableWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
