import AppKit
import SwiftUI

/// SwiftUI's hosting/scroll views consume background drags. Use AppKit's native window drag directly.
struct WindowDragRegion: NSViewRepresentable {
    final class Handle: NSView {
        override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
        override func mouseDown(with event:NSEvent) { window?.performDrag(with:event) }
        override func resetCursorRects() { addCursorRect(bounds,cursor:.openHand) }
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context:Context) -> Handle { let view = Handle(); view.setAccessibilityLabel("拖动字幕窗口"); return view }
    func updateNSView(_ nsView:Handle,context:Context) {}
}

/// Scrolling up pauses following; arriving captions never take the reader away from older text.
struct ReadingScrollMonitor: NSViewRepresentable {
    var onReadHistory: () -> Void
    final class Monitor: NSView {
        var callback:(() -> Void)?
        var monitor:Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching:.scrollWheel) { [weak self] event in
                if let self, event.window === self.window,
                   self.bounds.contains(self.convert(event.locationInWindow,from:nil)), event.scrollingDeltaY > 0 {
                    self.callback?()
                }
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context:Context) -> Monitor { let v = Monitor(); v.callback = onReadHistory; return v }
    func updateNSView(_ nsView:Monitor,context:Context) { nsView.callback = onReadHistory }
}
