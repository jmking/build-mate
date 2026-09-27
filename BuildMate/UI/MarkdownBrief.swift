import SwiftUI

/// Foundation parses Markdown; native text views supply block spacing and hanging list indents.
struct MarkdownBrief: View {
    let source: String
    var fillsWidth = true
    init(_ source: String, fillsWidth: Bool = true) {
        self.source = source
        self.fillsWidth = fillsWidth
    }

    private struct Block: Identifiable {
        var id: Int
        var text: AttributedString
        var heading: Int?
        var marker: String?
        var listDepth = 0
        var code = false
        var quote = false
    }
    private var blocks: [Block] {
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return [Block(id: 0, text: AttributedString(source))]
        }
        var result: [Block] = []
        var seenItems: Set<Int> = []
        for (intent, range) in parsed.runs[\.presentationIntent] {
            var block = Block(id: result.count, text: AttributedString(parsed[range]))
            block.text.presentationIntent = nil
            var item: (id: Int, ordinal: Int)?
            var ordered: Bool?
            for component in intent?.components ?? [] {
                switch component.kind {
                case .header(let level): block.heading = level
                case .listItem(let ordinal): if item == nil { item = (component.identity, ordinal) }
                case .orderedList: block.listDepth += 1; if ordered == nil { ordered = true }
                case .unorderedList: block.listDepth += 1; if ordered == nil { ordered = false }
                case .codeBlock: block.code = true
                case .blockQuote: block.quote = true
                default: break
                }
            }
            if let item, seenItems.insert(item.id).inserted { block.marker = ordered == true ? "\(item.ordinal)." : "•" }
            if block.code { block.text = AttributedString(String(block.text.characters).trimmingCharacters(in: .newlines)) }
            result.append(block)
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if block.listDepth > 0 {
                        Text(block.marker ?? "").frame(minWidth: 18, alignment: .trailing)
                    }
                    Text(block.text)
                        .font(block.code ? .system(size: 13, design: .monospaced) : block.heading != nil ? .system(size: block.heading == 1 ? 17 : 14, weight: .semibold) : .system(size: 14))
                        .lineSpacing(4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
                        .accessibilityAddTraits(block.heading == nil ? [] : .isHeader)
                }
                .padding(block.code ? 10 : 0)
                .background(block.code ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .padding(.leading, CGFloat(max(0, block.listDepth - 1)) * 20 + (block.quote ? 12 : 0))
                .padding(.top, block.heading == nil || block.id == 0 ? 0 : 4)
                .accessibilityElement(children: .combine)
            }
        }.font(.system(size: 14)).frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    }
}
