import AppKit
import SwiftUI

/// 现代 macOS 窗口壳：透明标题栏 + fullSizeContentView
/// 红绿灯位于横向工作台标题栏，整窗保留系统圆角与自由缩放。
enum WindowChrome {
    /// 旧页面兼容值；新页头不再重复预留标题栏空间。
    static let trafficLightsTop: CGFloat = 52
    /// 红绿灯水平占位（侧栏顶部若并排放控件时用）
    static let trafficLightsLeading: CGFloat = 78

    /// 首次打开的默认尺寸；用户可自由拉伸，后续恢复上次大小。
    static let defaultWidth: CGFloat = 960
    static let defaultHeight: CGFloat = 640
    static let minWidth: CGFloat = 640
    static let minHeight: CGFloat = 500
    /// SwiftUI scene sizing excludes the title bar even when its background is hidden.
    /// Ask AppKit for its height so the default outer window is 640 pt on each OS.
    private static var titlebarHeight: CGFloat {
        let content = NSRect(x: 0, y: 0, width: defaultWidth, height: defaultHeight)
        let frame = NSWindow.frameRect(forContentRect: content, styleMask: [.titled])
        return frame.height - content.height
    }
    static var contentHeight: CGFloat { defaultHeight - titlebarHeight }
    static var minContentHeight: CGFloat { minHeight - titlebarHeight }
    /// 换名丢掉旧 autosave，否则 defaultSize 不生效
    static let frameAutosaveName = "MacDefier.MainWindow.v6.horizontal"

    static func apply(to window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.standardWindowButton(.zoomButton)?.isEnabled = true
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        // 宠物跟眼依赖 mouseMoved；默认窗口不产生该事件
        window.acceptsMouseMovedEvents = true
        // 内容画进标题栏区域，由我们自己留 traffic light 空白
        // 整窗底贴近系统设置（侧栏材质自己画，这里用浅底）
        window.backgroundColor = NSColor.controlBackgroundColor

        if window.frameAutosaveName != frameAutosaveName {
            window.setFrameAutosaveName(frameAutosaveName)
        }
        window.minSize = NSSize(width: minWidth, height: minHeight)
        // Apply the compact default only before the user has saved a window size.
        if !window.setFrameUsingName(frameAutosaveName) {
            var frame = window.frame
            frame.size = NSSize(width: defaultWidth, height: defaultHeight)
            window.setFrame(frame, display: false)
        }
    }
}

struct WindowChromeInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> InstallerView { InstallerView() }
    func updateNSView(_ nsView: InstallerView, context: Context) {}

    final class InstallerView: NSView {
        private weak var configuredWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, configuredWindow !== window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window,
                      self.configuredWindow !== window else { return }
                self.configuredWindow = window
                WindowChrome.apply(to: window)
            }
        }
    }
}

/// Reports only the main content window's ordered/visible state. Menu bar panels and transient
/// windows must not accidentally keep all samplers alive.
struct MainWindowVisibilityObserver: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onChange: (Bool) -> Void
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
        }

        func attach(to window: NSWindow?) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            guard let window else {
                onChange(false)
                return
            }
            let center = NotificationCenter.default
            // `didOrderOnScreen/OffScreen` are not public NSWindow notifications.
            // Main/key, occlusion, minimize, and close cover the visibility changes
            // that affect monitor demand without relying on private API names.
            for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.willCloseNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.report()
                })
            }
            report()
        }

        func detach() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            window = nil
        }

        private func report() {
            guard let window else {
                onChange(false)
                return
            }
            onChange(window.isVisible && !window.isMiniaturized)
        }
    }
}
