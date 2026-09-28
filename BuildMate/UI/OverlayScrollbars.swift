import AppKit
import SwiftUI

/// Keep native dragging, accessibility and fading, without a permanent scrollbar gutter.
/// Place in the background of scroll content so it configures only its enclosing scroll view.
struct OverlayScrollbars: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollbarAnchor { ScrollbarAnchor() }
    func updateNSView(_ view: ScrollbarAnchor, context: Context) { view.configure() }

    final class ScrollbarAnchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }
        func configure() {
            guard let scroll = enclosingScrollView else { return }
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            scroll.verticalScroller?.controlSize = .small
            scroll.horizontalScroller?.controlSize = .small
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) {
            configure()
            enclosingScrollView?.flashScrollers()
        }
    }
}
