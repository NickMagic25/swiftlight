import SwiftUI
import SwiftlightHost

/// Artwork is content; glass appears only on the active cover and its controls.
/// Mobile titles remain visible because touch does not provide a hover state.
struct AppLibraryGrid: View {
    let apps: [RemoteApp]
    let runningAppID: Int?
    @ObservedObject var artwork: AppArtworkStore
    let loadingAllowed: Bool
    let requestArtwork: (RemoteApp) -> Void
    let launch: (RemoteApp) -> Void
    let quit: ((RemoteApp) -> Void)?
    @FocusState private var focusedAppID: Int?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(apps: [RemoteApp], runningAppID: Int?, artwork: AppArtworkStore, loadingAllowed: Bool,
         requestArtwork: @escaping (RemoteApp) -> Void, launch: @escaping (RemoteApp) -> Void,
         quit: ((RemoteApp) -> Void)? = nil) {
        self.apps = apps
        self.runningAppID = runningAppID
        self.artwork = artwork
        self.loadingAllowed = loadingAllowed
        self.requestArtwork = requestArtwork
        self.launch = launch
        self.quit = quit
    }

    private var spacing: CGFloat {
        #if os(iOS)
        16
        #else
        24
        #endif
    }

    private var columns: [GridItem] {
        #if os(iOS)
        if dynamicTypeSize.isAccessibilitySize {
            [GridItem(.flexible(minimum: 140), spacing: spacing, alignment: .topLeading)]
        } else {
            [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: spacing, alignment: .topLeading)]
        }
        #else
        [GridItem(.adaptive(minimum: 180, maximum: 210), spacing: spacing)]
        #endif
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(apps) { app in
                AppCoverButton(app: app, image: artwork.images[app.id], isRunning: runningAppID == app.id,
                               isFocused: focusedAppID == app.id) { launch(app) }
                    .focused($focusedAppID, equals: app.id)
                    .contextMenu {
                        Button(runningAppID == app.id ? "Resume" : "Play") { launch(app) }
                        if runningAppID == app.id, let quit {
                            Divider()
                            Button("Quit Remote Application…", role: .destructive) { quit(app) }
                        }
                    }
                    .onAppear { if loadingAllowed { requestArtwork(app) } }
                    .onChange(of: loadingAllowed) { _, allowed in
                        if allowed { requestArtwork(app) }
                    }
            }
        }
        .accessibilityIdentifier("appLibraryGrid")
    }
}

private struct AppCoverButton: View {
    let app: RemoteApp
    let image: CGImage?
    let isRunning: Bool
    let isFocused: Bool
    let launch: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var highlighted: Bool { hovered || isFocused }
    private var actionName: String { isRunning ? "Resume" : "Play" }

    var body: some View {
        Button(action: launch) {
            #if os(iOS)
            VStack(alignment: .leading, spacing: 8) {
                // A single accessibility column gives names the available width
                // without expanding cover images to the width of an iPad window.
                cover.frame(maxWidth: 200)
                Text(app.name)
                    .font(.headline)
                    .foregroundStyle(.tint)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("appTitle-\(app.id)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            #else
            cover.contentShape(RoundedRectangle(cornerRadius: 12))
            #endif
        }
        .buttonStyle(CoverPressStyle())
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: highlighted)
        .accessibilityLabel("\(isRunning ? "Resume" : "Launch") \(app.name)")
        .accessibilityValue(isRunning ? "Running" : "")
        .accessibilityIdentifier("appCard-\(app.id)")
        #if os(macOS)
        .help(app.name)
        #endif
    }

    private var cover: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityIdentifier("appArtwork-\(app.id)")
                } else {
                    fallback.accessibilityIdentifier("appArtworkFallback-\(app.id)")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .swiftlightArtworkHighlight(active: highlighted, cornerRadius: 12)
            #if !os(iOS)
            .overlay(alignment: .bottom) {
                if highlighted {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(app.name).font(.callout.weight(.semibold)).lineLimit(3)
                        Label(actionName, systemImage: "play.fill").font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .swiftlightGlassSurface(cornerRadius: 10)
                    .padding(8)
                    .transition(.opacity)
                }
            }
            #endif
            .overlay(alignment: .topLeading) {
                if isRunning {
                    Label("Resume", systemImage: "play.fill")
                        .font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 7)
                        .swiftlightGlassSurface(cornerRadius: 20)
                        .padding(10)
                }
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
    }

    private var fallback: some View {
        VStack(spacing: 18) {
            Image(systemName: app.name.localizedCaseInsensitiveContains("desktop") ? "desktopcomputer" : "gamecontroller")
                .font(.system(size: 40, weight: .light))
            #if !os(iOS)
            Text(app.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center).lineLimit(5)
            #endif
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.5))
    }
}

private struct CoverPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}
