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

/// Explicit hit targets for a borderless panel, independent of subtitle background alpha.
struct WindowResizeBorder: NSViewRepresentable {
    final class Border: NSView {
        // The whole hit target must contain a non-zero-alpha pixel. Otherwise
        // WindowServer can discard the transparent outer part before hit testing.
        private let edge: CGFloat = 10
        private let paintedEdge: CGFloat = 10
        private let corner: CGFloat = 20
        private var startFrame = NSRect.zero
        private var startMouse = NSPoint.zero
        private var sides: (left: Bool, right: Bool, bottom: Bool, top: Bool)?
        private static let risingCursor = makeDiagonalCursor(rising:true)
        private static let fallingCursor = makeDiagonalCursor(rising:false)
        private var cursorTrackingAreas: [NSTrackingArea] = []
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { window.invalidateCursorRects(for:self) }
        }
        override func setFrameSize(_ newSize: NSSize) {
            let changed = frame.size != newSize
            super.setFrameSize(newSize)
            if changed, let window {
                needsDisplay = true
                window.invalidateCursorRects(for:self)
            }
        }
        override func updateTrackingAreas() {
            for area in cursorTrackingAreas { removeTrackingArea(area) }
            cursorTrackingAreas.removeAll(keepingCapacity:true)
            let options: NSTrackingArea.Options = [.activeAlways,.mouseMoved,.cursorUpdate]
            let regions = [
                NSRect(x:corner,y:0,width:max(0,bounds.width-2*corner),height:edge),
                NSRect(x:corner,y:bounds.height-edge,width:max(0,bounds.width-2*corner),height:edge),
                NSRect(x:0,y:corner,width:edge,height:max(0,bounds.height-2*corner)),
                NSRect(x:bounds.width-edge,y:corner,width:edge,height:max(0,bounds.height-2*corner)),
                NSRect(x:0,y:0,width:corner,height:corner),
                NSRect(x:bounds.width-corner,y:bounds.height-corner,width:corner,height:corner),
                NSRect(x:0,y:bounds.height-corner,width:corner,height:corner),
                NSRect(x:bounds.width-corner,y:0,width:corner,height:corner)
            ]
            for rect in regions where rect.width > 0 && rect.height > 0 {
                let area = NSTrackingArea(rect:rect,options:options,owner:self,userInfo:nil)
                addTrackingArea(area); cursorTrackingAreas.append(area)
            }
            super.updateTrackingAreas()
        }
        private func edges(at p: NSPoint) -> (left: Bool, right: Bool, bottom: Bool, top: Bool)? {
            guard bounds.contains(p) else { return nil }
            let left = p.x < edge, right = p.x > bounds.width - edge
            let bottom = p.y < edge, top = p.y > bounds.height - edge
            guard left || right || bottom || top else { return nil }
            return (p.x < corner, p.x > bounds.width - corner,
                    p.y < corner, p.y > bounds.height - corner)
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            edges(at: convert(point, from: superview)) == nil ? nil : self
        }
        override func draw(_ dirtyRect: NSRect) {
            // A zero-alpha window pixel is discarded by WindowServer before hitTest.
            // Keep only the narrow resize perimeter faintly painted, never the center.
            NSColor.white.withAlphaComponent(0.02).setFill()
            NSRect(x:0,y:0,width:bounds.width,height:paintedEdge).fill()
            NSRect(x:0,y:bounds.height-paintedEdge,width:bounds.width,height:paintedEdge).fill()
            NSRect(x:0,y:paintedEdge,width:paintedEdge,height:max(0,bounds.height-2*paintedEdge)).fill()
            NSRect(x:bounds.width-paintedEdge,y:paintedEdge,width:paintedEdge,height:max(0,bounds.height-2*paintedEdge)).fill()
        }
        override func resetCursorRects() {
            addCursorRect(NSRect(x:corner,y:0,width:max(0,bounds.width-2*corner),height:edge),cursor:.resizeUpDown)
            addCursorRect(NSRect(x:corner,y:bounds.height-edge,width:max(0,bounds.width-2*corner),height:edge),cursor:.resizeUpDown)
            addCursorRect(NSRect(x:0,y:corner,width:edge,height:max(0,bounds.height-2*corner)),cursor:.resizeLeftRight)
            addCursorRect(NSRect(x:bounds.width-edge,y:corner,width:edge,height:max(0,bounds.height-2*corner)),cursor:.resizeLeftRight)
            for (x,y,rising) in [(CGFloat(0),CGFloat(0),true),(bounds.width-corner,bounds.height-corner,true),
                                 (CGFloat(0),bounds.height-corner,false),(bounds.width-corner,CGFloat(0),false)] {
                addCursorRect(NSRect(x:x,y:y,width:corner,height:corner),
                              cursor:rising ? Self.risingCursor : Self.fallingCursor)
            }
        }
        override func mouseMoved(with event: NSEvent) { setCursor(for:event) }
        override func cursorUpdate(with event: NSEvent) { setCursor(for:event) }
        private func setCursor(for event: NSEvent) {
            guard let sides = edges(at:convert(event.locationInWindow,from:nil)) else { return }
            let cursor: NSCursor
            if (sides.left && sides.bottom) || (sides.right && sides.top) { cursor = Self.risingCursor }
            else if (sides.left && sides.top) || (sides.right && sides.bottom) { cursor = Self.fallingCursor }
            else if sides.left || sides.right { cursor = .resizeLeftRight }
            else { cursor = .resizeUpDown }
            cursor.set()
        }
        private static func makeDiagonalCursor(rising: Bool) -> NSCursor {
            let image = NSImage(size:NSSize(width:20,height:20),flipped:false) { _ in
                let p = NSBezierPath()
                func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x:x,y:rising ? y : 20-y) }
                p.move(to:point(4,4)); p.line(to:point(16,16))
                p.move(to:point(4,10)); p.line(to:point(4,4)); p.line(to:point(10,4))
                p.move(to:point(10,16)); p.line(to:point(16,16)); p.line(to:point(16,10))
                p.lineWidth = 4; NSColor.white.setStroke(); p.stroke()
                p.lineWidth = 2; NSColor.black.setStroke(); p.stroke()
                return true
            }
            return NSCursor(image:image,hotSpot:NSPoint(x:10,y:10))
        }
        override func mouseDown(with event: NSEvent) {
            guard let window, let hit = edges(at:convert(event.locationInWindow,from:nil)) else { return }
            sides = hit; startFrame = window.frame; startMouse = NSEvent.mouseLocation
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window, let sides else { return }
            let point = NSEvent.mouseLocation
            let dx = point.x-startMouse.x, dy = point.y-startMouse.y
            var frame = startFrame
            if sides.left || sides.right {
                frame.size.width = max(window.minSize.width,min(window.maxSize.width,startFrame.width + (sides.left ? -dx : dx)))
                if sides.left { frame.origin.x = startFrame.maxX-frame.width }
            }
            if sides.bottom || sides.top {
                frame.size.height = max(window.minSize.height,min(window.maxSize.height,startFrame.height + (sides.bottom ? -dy : dy)))
                if sides.bottom { frame.origin.y = startFrame.maxY-frame.height }
            }
            window.setFrame(frame,display:true)
            window.invalidateCursorRects(for:self)
        }
        override func mouseUp(with event: NSEvent) { sides = nil }
    }
    func makeNSView(context: Context) -> Border {
        let view = Border(); view.setAccessibilityLabel("拖动窗口边缘调整字幕尺寸"); return view
    }
    // Border invalidation is driven by AppKit size/window callbacks above, not by
    // every partial transcript publication from SwiftUI.
    func updateNSView(_ view: Border, context: Context) {}
}
