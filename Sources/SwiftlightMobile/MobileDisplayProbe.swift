import SwiftUI
import SwiftlightCore
import UIKit

/// This adapter reads the owning window, including an iPad's resized window.
/// Ordinary navigation and controls remain SwiftUI-owned.
struct MobileDisplayProbe: UIViewRepresentable {
    let onChange: @MainActor (DisplayGeometry) -> Void

    func makeUIView(context: Context) -> MobileDisplayProbeView {
        let view = MobileDisplayProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: MobileDisplayProbeView, context: Context) {
        view.onChange = onChange
        view.scheduleUpdate()
    }
}

@MainActor final class MobileDisplayProbeView: UIView {
    var onChange: (@MainActor (DisplayGeometry) -> Void)?
    private var pendingUpdate = false
    private var lastGeometry: DisplayGeometry?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleUpdate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleUpdate()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        scheduleUpdate()
    }

    func scheduleUpdate() {
        guard !pendingUpdate else { return }
        pendingUpdate = true
        // Publish after the current SwiftUI update; never mutate observed state
        // from updateUIView or during UIKit layout.
        Task { @MainActor [weak self] in
            guard let self else { return }
            pendingUpdate = false
            guard let window, let screen = window.windowScene?.screen,
                  window.bounds.width > 0, window.bounds.height > 0 else { return }
            let screenBounds = screen.bounds
            let content = window.convert(window.bounds, to: screen.coordinateSpace)
            let safeContent = window.convert(window.safeAreaLayoutGuide.layoutFrame, to: screen.coordinateSpace)
            var pixels = screen.nativeBounds.size
            if (screenBounds.width > screenBounds.height) != (pixels.width > pixels.height) {
                pixels = CGSize(width: pixels.height, height: pixels.width)
            }
            let geometry = DisplayGeometry(screen: screenBounds, safeScreen: safeContent, content: content,
                nativePixels: PixelSize(Int(pixels.width), Int(pixels.height)),
                backingScale: Double(screen.scale), refreshHz: Double(screen.maximumFramesPerSecond))
            guard geometry != lastGeometry else { return }
            lastGeometry = geometry
            onChange?(geometry)
        }
    }
}
