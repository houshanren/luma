import SwiftUI
import AppKit

/// 窗口级键盘监听。隐藏按钮 + keyboardShortcut 在覆盖层/零尺寸视图里经常收不到按键，
/// 这里直接监听 NSWindow 的 keyDown，保证左右方向键等快捷键稳定生效。
struct KeyEventMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    final class Coordinator {
        var handler: (NSEvent) -> Bool
        var monitor: Any?
        weak var hostView: NSView?

        init(handler: @escaping (NSEvent) -> Bool) {
            self.handler = handler
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(handler: handler)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator, let hostView = coordinator.hostView else { return event }
            guard let hostWindow = hostView.window, event.window === hostWindow else { return event }
            guard hostWindow.attachedSheet == nil else { return event }
            if hostWindow.firstResponder is NSTextView { return event }
            return coordinator.handler(event) ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
        coordinator.hostView = nil
    }
}
