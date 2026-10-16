import Foundation
import SwiftUI

indirect enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case code(String, String?)
    case quote([MarkdownBlock])
    case list(Bool, Int, [[MarkdownBlock]])
    case table([String], [[String]])
    case rule
    case image(String, String)
}

/// Structural Markdown parsing only; inline emphasis and links use Foundation's parser.
enum ChatMarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        parseLines(
            String(source.prefix(100_000)).replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n"), depth: 0)
    }
    private struct Marker {
        let indent: Int
        let width: Int
        let ordered: Bool
        let number: Int
        let text: String
    }
    private static func marker(_ line: String) -> Marker? {
        guard let range = line.range(of: #"^\s*(?:[-+*]|[0-9]+[.)])\s+"#, options: .regularExpression)
        else { return nil }
        let prefix = String(line[range])
        let token = prefix.trimmingCharacters(in: .whitespaces)
        return Marker(
            indent: line.prefix(while: { $0 == " " }).count, width: prefix.count,
            ordered: token.first?.isNumber == true, number: Int(token.dropLast()) ?? 1,
            text: String(line[range.upperBound...]))
    }
    private static func fence(_ line: String) -> (Character, Int, String?)? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard let first = text.first, first == "`" || first == "~" else { return nil }
        let count = text.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        let language = text.dropFirst(count).trimmingCharacters(in: .whitespaces)
        return (first, count, language.isEmpty ? nil : language)
    }
    static func cells(_ line: String) -> [String] {
        var source = line.trimmingCharacters(in: .whitespaces)
        if source.hasPrefix("|") { source.removeFirst() }
        if source.hasSuffix("|"), !source.hasSuffix(#"\|"#) { source.removeLast() }
        var cells: [String] = []
        var value = ""
        var escaped = false
        var code = false
        for character in source {
            if escaped {
                if character != "|" { value.append("\\") }
                value.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "`" {
                code.toggle()
                value.append(character)
                continue
            }
            if character == "|", !code {
                cells.append(value.templateTrimmed)
                value = ""
            } else {
                value.append(character)
            }
        }
        if escaped { value.append("\\") }
        cells.append(value.templateTrimmed)
        return cells
    }
    private static func tableSeparator(_ line: String) -> Bool {
        let values = cells(line)
        return line.contains("|") && !values.isEmpty
            && values.allSatisfy {
                $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
            }
    }
    private static func isRule(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        return compact.count >= 3 && ["-", "*", "_"].contains(String(compact.first!))
            && compact.allSatisfy { $0 == compact.first }
    }
    private static func parseLines(_ lines: [String], depth: Int) -> [MarkdownBlock] {
        guard depth < 24 else { return [.paragraph(lines.joined(separator: "\n"))] }
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        while index < lines.count {
            let line = lines[index]
            let text = line.templateTrimmed
            if text.isEmpty {
                flush()
                index += 1
                continue
            }
            if let (character, count, language) = fence(line) {
                flush()
                index += 1
                var code: [String] = []
                while index < lines.count {
                    if let (end, width, suffix) = fence(lines[index]), end == character, width >= count,
                        suffix == nil
                    {
                        index += 1
                        break
                    }
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(code.joined(separator: "\n"), language))
                continue
            }
            if text.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while index < lines.count, lines[index].templateTrimmed.hasPrefix(">") {
                    var value = String(lines[index].templateTrimmed.dropFirst())
                    if value.hasPrefix(" ") { value.removeFirst() }
                    quote.append(value)
                    index += 1
                }
                blocks.append(.quote(parseLines(quote, depth: depth + 1)))
                continue
            }
            if index + 1 < lines.count, line.contains("|"), tableSeparator(lines[index + 1]) {
                flush()
                let headers = cells(line)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"), !lines[index].templateTrimmed.isEmpty {
                    rows.append(
                        Array(
                            (cells(lines[index]) + Array(repeating: "", count: headers.count)).prefix(
                                headers.count)))
                    index += 1
                }
                blocks.append(.table(headers, rows))
                continue
            }
            if let range = text.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                blocks.append(
                    .heading(text.prefix(while: { $0 == "#" }).count, String(text[range.upperBound...])))
                index += 1
                continue
            }
            if index + 1 < lines.count,
                lines[index + 1].templateTrimmed.range(of: #"^(={3,}|-{3,})$"#, options: .regularExpression)
                    != nil
            {
                flush()
                blocks.append(.heading(lines[index + 1].templateTrimmed.hasPrefix("=") ? 1 : 2, text))
                index += 2
                continue
            }
            if isRule(text) {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }
            if let first = marker(line) {
                flush()
                var items: [[MarkdownBlock]] = []
                while index < lines.count, let item = marker(lines[index]), item.indent == first.indent,
                    item.ordered == first.ordered
                {
                    var content = [item.text]
                    index += 1
                    while index < lines.count {
                        let next = lines[index]
                        if let nextMarker = marker(next), nextMarker.indent <= first.indent { break }
                        let indent = next.prefix(while: { $0 == " " }).count
                        if !next.templateTrimmed.isEmpty && indent <= first.indent { break }
                        if next.templateTrimmed.isEmpty {
                            if index + 1 >= lines.count {
                                index += 1
                                break
                            }
                            let following = lines[index + 1]
                            if following.prefix(while: { $0 == " " }).count <= first.indent { break }
                        }
                        content.append(String(next.dropFirst(min(item.width, indent))))
                        index += 1
                    }
                    items.append(parseLines(content, depth: depth + 1))
                }
                blocks.append(.list(first.ordered, first.number, items))
                continue
            }
            if let expression = try? NSRegularExpression(
                pattern: #"^!\[([^\]]*)\]\((https?://[^\s)]+)\)$"#),
                let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                let alt = Range(match.range(at: 1), in: text), let url = Range(match.range(at: 2), in: text)
            {
                flush()
                blocks.append(.image(String(text[url]), String(text[alt])))
                index += 1
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flush()
        return blocks
    }
}

struct ChatMarkdownView: View {
    let content: String
    var fillsAvailableWidth = true

    var body: some View {
        MarkdownBlocksView(blocks: ChatMarkdownParser.parse(content))
            .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, alignment: .leading)
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
    }
}
private struct MarkdownBlockView: View {
    @Environment(\.chatTheme) private var theme
    let block: MarkdownBlock
    var body: some View {
        switch block {
        case .paragraph(let text): inline(text)
        case .heading(let level, let text):
            inline(text).font(
                theme?.font(size: max(17, 29 - CGFloat(level) * 2), weight: .bold)
                    ?? .system(size: max(17, 29 - CGFloat(level) * 2), weight: .bold)
            ).accessibilityAddTraits(.isHeader)
        case .code(let code, let language):
            VStack(alignment: .leading, spacing: 4) {
                if let language { Text(language).font(.caption).foregroundStyle(.secondary) }
                ScrollView(.horizontal) {
                    Text(verbatim: code).font(.system(size: theme?.baseFontSize ?? 16, design: .monospaced))
                        .textSelection(.enabled)
                }
            }.padding(10).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 3)
                AnyView(MarkdownBlocksView(blocks: blocks))
            }.fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, blocks in
                    HStack(alignment: .top, spacing: 8) {
                        Text(ordered ? "\(start + index)." : "•").frame(minWidth: 18, alignment: .trailing)
                        AnyView(MarkdownBlocksView(blocks: blocks))
                    }
                }
            }
        case .table(let headers, let rows):
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    tableRow(headers, header: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                        tableRow(cells, header: false)
                    }
                }
            }
        case .rule: Divider()
        case .image(let value, let alt):
            if let url = URL(string: value), url.isHTTP {
                TemplateRemoteImage(url: url) {
                    $0.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
                .accessibilityLabel(alt)
            }
        }
    }
    private func tableRow(_ values: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                inline(value).font(
                    theme?.font(size: 15, weight: header ? .semibold : .regular)
                        ?? .system(size: 15, weight: header ? .semibold : .regular)
                ).frame(width: 140, alignment: .leading)
                    .padding(8).background(header ? Color.primary.opacity(0.06) : .clear)
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
            }
        }
    }
    private func inline(_ value: String) -> some View {
        Text(ChatMarkdownCache.text(value)).textSelection(.enabled).fixedSize(
            horizontal: false, vertical: true)
    }
}
