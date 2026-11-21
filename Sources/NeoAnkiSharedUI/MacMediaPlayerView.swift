#if os(macOS)
import AVKit
import SwiftUI

/// Use the AppKit playback surface directly. The macOS SwiftUI VideoPlayer
/// bridge can abort when it tries to resolve AVPlayerView's class metadata.
package struct MacMediaPlayerView: NSViewRepresentable {
    let player: AVPlayer

    package init(player: AVPlayer) {
        self.player = player
    }

    package func makeNSView(context: Context) -> AVPlayerView { makePlayerView() }

    package func makePlayerView() -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    package func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    package static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
#endif
