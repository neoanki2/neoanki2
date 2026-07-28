import AppKit
import SwiftUI

/// Keeps a window within the screen it is on.
///
/// Two things otherwise size the window for the reader: macOS restores the
/// frame a window last had, which may come from a larger display, and SwiftUI
/// grows a window to fit its content. Either one can carry the bottom controls
/// past the edge of the screen, where they cannot be clicked at all.
///
/// AppKit asks a window how large it may become through
/// `windowWillResize(_:to:)`, and answers there are applied during the window's
/// own layout rather than in the middle of a constraint pass. Clamping here is
/// what keeps this from reentering AppKit's layout.
final class WindowScreenFitDelegate: NSObject, NSWindowDelegate {
    /// Whatever delegate SwiftUI installed. Messages this class does not
    /// implement are forwarded there, so SwiftUI keeps its own behavior.
    ///
    /// `nonisolated(unsafe)` because AppKit consults `responds(to:)` and
    /// `forwardingTarget(for:)` through the Objective-C runtime, which offers no
    /// place to state isolation. Every access is on the main thread: AppKit
    /// messages window delegates there, and this is only ever assigned from the
    /// main actor during installation.
    private nonisolated(unsafe) weak var forwarding: NSWindowDelegate?

    init(forwarding: NSWindowDelegate?) {
        self.forwarding = forwarding
        super.init()
    }

    @MainActor
    func windowWillResize(
        _ sender: NSWindow,
        to frameSize: NSSize
    ) -> NSSize {
        let proposed = forwarding?.windowWillResize?(sender, to: frameSize) ?? frameSize
        guard let limit = sender.screenSizeLimit else { return proposed }
        return NSSize(
            width: min(proposed.width, limit.width),
            height: min(proposed.height, limit.height)
        )
    }

    @MainActor
    func windowDidChangeScreen(_ notification: Notification) {
        forwarding?.windowDidChangeScreen?(notification)
        guard let window = notification.object as? NSWindow else { return }
        window.clampToScreen()
    }

    /// `windowWillResize(_:to:)` is only consulted for resizes the window itself
    /// negotiates — a user drag, or a zoom. SwiftUI growing the window to fit
    /// its content, and AppKit restoring an autosaved frame, both bypass it and
    /// land here instead, which is the path that actually produced windows
    /// taller than the screen.
    @MainActor
    func windowDidResize(_ notification: Notification) {
        forwarding?.windowDidResize?(notification)
        guard let window = notification.object as? NSWindow else { return }
        window.clampToScreen()
    }

    override nonisolated func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        return forwarding?.responds(to: selector) ?? false
    }

    override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
        if let forwarding, forwarding.responds(to: selector) { return forwarding }
        return super.forwardingTarget(for: selector)
    }
}

extension NSWindow {
    /// The largest frame this window may occupy on its current screen.
    @MainActor
    var screenSizeLimit: NSSize? {
        guard !styleMask.contains(.fullScreen),
              let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        else {
            return nil
        }
        return visible.size
    }

    /// Shrinks the window to its screen and nudges it fully back on screen. A
    /// window that already fits is left exactly as the reader left it.
    @MainActor
    func clampToScreen() {
        guard let limit = screenSizeLimit,
              let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        else {
            return
        }

        // Detail panes render inline rather than in sheets, so their minimum
        // heights accumulate into the window's content minimum. When that
        // minimum exceeds the window, the split view lays out at the minimum
        // instead — hanging its top edge above the window and carrying the
        // sidebar rows out of reach, which is what makes them unclickable even
        // though the window itself fits the screen. Capping the minimum is what
        // keeps the content inside the frame.
        let chrome = frame.height - contentRect(forFrameRect: frame).height
        let maxContentHeight = max(limit.height - chrome, 0)
        if contentMinSize.height > maxContentHeight {
            contentMinSize = NSSize(width: contentMinSize.width, height: maxContentHeight)
        }
        if contentMinSize.width > limit.width {
            contentMinSize = NSSize(width: limit.width, height: contentMinSize.height)
        }

        var target = frame
        target.size.width = min(target.width, limit.width)
        target.size.height = min(target.height, limit.height)
        target.origin.x = min(max(target.minX, visible.minX), visible.maxX - target.width)
        target.origin.y = min(max(target.minY, visible.minY), visible.maxY - target.height)

        guard target != frame else { return }
        // Deferred so this never lands inside an in-flight layout pass, which
        // AppKit treats as a programming error and traps on.
        let fitted = target
        Task { @MainActor [weak self] in
            guard let self, self.frame != fitted else { return }
            self.setFrame(fitted, display: true)
        }
    }
}

extension View {
    /// Installs screen fitting on the window hosting this view.
    func fitWindowToScreen() -> some View {
        background(WindowScreenFitInstaller())
    }
}

/// Reaches the hosting `NSWindow` from SwiftUI without owning any visible area.
private struct WindowScreenFitInstaller: NSViewRepresentable {
    final class Coordinator {
        var fitDelegate: WindowScreenFitDelegate?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        install(from: view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        install(from: nsView, context: context)
    }

    private func install(from view: NSView, context: Context) {
        let coordinator = context.coordinator
        // The window exists only once the view joins a hierarchy, and a fresh
        // window arrives with SwiftUI's own delegate already attached.
        Task { @MainActor in
            guard let window = view.window else { return }
            if coordinator.fitDelegate == nil || window.delegate !== coordinator.fitDelegate {
                let fit = WindowScreenFitDelegate(forwarding: window.delegate)
                coordinator.fitDelegate = fit
                window.delegate = fit
            }
            window.clampToScreen()
        }
    }
}
