import SwiftUI
import AppKit

package struct WindowAccessor: NSViewRepresentable {
    private let onChange: (NSWindow?) -> Void

    package init(onChange: @escaping (NSWindow?) -> Void) {
        self.onChange = onChange
    }

    package func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    package func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.observe(view)
            onChange(view.window)
        }
        return view
    }

    package func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        DispatchQueue.main.async {
            context.coordinator.observe(nsView)
            onChange(nsView.window)
        }
    }

    /// 顺带观察窗口尺寸：顶栏需要按宽度切换紧凑形态。
    package final class Coordinator {
        var onChange: (NSWindow?) -> Void
        private weak var window: NSWindow?
        private var observer: NSObjectProtocol?

        package init(onChange: @escaping (NSWindow?) -> Void) {
            self.onChange = onChange
        }

        func observe(_ view: NSView) {
            guard let window = view.window, self.window !== window else { return }
            self.window = window
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                              object: window,
                                                              queue: .main) { [weak self] _ in
                self?.onChange(window)
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
