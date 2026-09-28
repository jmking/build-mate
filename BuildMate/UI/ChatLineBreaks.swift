import SwiftUI

extension View {
    /// A multiline TextField still submits Shift–Return by default on macOS.
    /// Insert at the selection while preserving the field’s native growing layout.
    func chatLineBreaks(text: Binding<String>, selection: Binding<TextSelection?>) -> some View {
        onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            var value = text.wrappedValue
            let range: Range<String.Index>
            if case .selection(let selected) = selection.wrappedValue?.indices {
                range = selected
            } else {
                range = value.endIndex..<value.endIndex
            }
            let offset = value.distance(from: value.startIndex, to: range.lowerBound)
            value.replaceSubrange(range, with: "\n")
            text.wrappedValue = value
            selection.wrappedValue = TextSelection(insertionPoint: value.index(value.startIndex, offsetBy: offset + 1))
            return .handled
        }
    }
}
