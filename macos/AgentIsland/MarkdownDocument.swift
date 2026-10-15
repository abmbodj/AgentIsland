import Foundation

enum MarkdownBlock: Equatable {
    case heading(Int, String), paragraph(String), list(String, String), quote(String), code(String, String), table([[String]])

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var result: [MarkdownBlock] = [], paragraph: [String] = []
        var i = 0
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func cells(_ line: String) -> [String] {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") { s.removeFirst() }; if s.hasSuffix("|") { s.removeLast() }
            return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        while i < lines.count {
            let line = lines[i], t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flush(); let fence = String(t.prefix(3)), language = String(t.dropFirst(3)); var body: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { body.append(lines[i]); i += 1 }
                result.append(.code(language, body.joined(separator: "\n")))
            } else if i + 1 < lines.count, t.contains("|"), cells(lines[i + 1]).allSatisfy({ $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }) {
                flush(); var rows = [cells(t)]; i += 2
                while i < lines.count && lines[i].contains("|") { rows.append(cells(lines[i])); i += 1 }
                result.append(.table(rows)); continue
            } else if t.isEmpty { flush()
            } else if t.hasPrefix("#"), let space = t.firstIndex(of: " "), t[..<space].allSatisfy({ $0 == "#" }), t.distance(from: t.startIndex, to: space) <= 6 {
                flush(); result.append(.heading(t.distance(from: t.startIndex, to: space), String(t[t.index(after: space)...])))
            } else if t.hasPrefix(">") { flush(); result.append(.quote(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if let range = t.range(of: "^([-+*]|[0-9]+[.)]) +", options: .regularExpression) {
                flush(); var body = String(t[range.upperBound...]); var marker = String(t[range]).trimmingCharacters(in: .whitespaces)
                if body.hasPrefix("[ ] ") { marker = "☐"; body = String(body.dropFirst(4)) }
                else if body.lowercased().hasPrefix("[x] ") { marker = "☑"; body = String(body.dropFirst(4)) }
                else if ["-", "+", "*"].contains(marker) { marker = "•" }
                let indent = min(24, line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) })
                result.append(.list(String(repeating: " ", count: indent) + marker, body))
            } else { paragraph.append(line) }
            i += 1
        }
        flush(); return result
    }
}

#if !MARKDOWN_TESTS
import SwiftUI
struct MarkdownDocument: View {
    let markdown: String
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, text): inline(text).font(.system(size: level == 1 ? 18 : 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                case let .paragraph(text): inline(text)
                case let .list(marker, text): HStack(alignment: .top, spacing: 8) { Text(marker); inline(text).frame(maxWidth: .infinity, alignment: .leading) }
                case let .quote(text): inline(text).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                case let .code(language, text):
                    VStack(alignment: .leading, spacing: 5) {
                        Text(language).font(.system(size: 10)).foregroundStyle(.secondary)
                        ScrollView(.horizontal) { Text(text).font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: true, vertical: false) }
                    }.padding(8).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                case let .table(rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                GridRow { ForEach(row.indices, id: \.self) { column in inline(row[column]).fixedSize() } }.fontWeight(index == 0 ? .semibold : .regular)
                            }
                        }.padding(8)
                    }.background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .font(.system(size: 13)).foregroundStyle(Color(nsColor: Theme.ink))
        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
