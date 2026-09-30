/// The destination application's platform, independent of its UI framework.
public enum StreamPlatform: CaseIterable, Sendable {
    case macOS, iOS, iPadOS, tvOS
}

public enum StreamPresentationPolicy {
    /// Resolves launch presentation. Platform adapters perform the actual window
    /// or scene transition; the shared core never imports AppKit or UIKit.
    public static func launchesFullScreen(on platform: StreamPlatform, settings: StreamSettings) -> Bool {
        switch platform {
        case .macOS: settings.launchInFullScreen
        case .iOS, .iPadOS, .tvOS: true
        }
    }
}
