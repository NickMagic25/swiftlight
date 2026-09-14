import SwiftUI
import SwiftlightHost

/// Artwork is content; glass appears only on the active cover and its controls.
struct AppLibraryGrid: View {
    let apps: [RemoteApp]
    let runningAppID: Int?
    @ObservedObject var artwork: AppArtworkStore
    let loadingAllowed: Bool
    let requestArtwork: (RemoteApp) -> Void
    let launch: (RemoteApp) -> Void
    let quit: (RemoteApp) -> Void
    @FocusState private var focusedAppID: Int?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 210), spacing: 24)], spacing: 24) {
            ForEach(apps) { app in
                AppCoverButton(app: app, image: artwork.images[app.id], isRunning: runningAppID == app.id,
                               isFocused: focusedAppID == app.id) { launch(app) }
                    .focused($focusedAppID, equals: app.id)
                    .contextMenu {
                        Button(runningAppID == app.id ? "Resume" : "Play") { launch(app) }
                        if runningAppID == app.id {
                            Divider()
                            Button("Quit Remote Application…", role: .destructive) { quit(app) }
                        }
                    }
                    .onAppear { requestArtwork(app) }
                    .onChange(of: loadingAllowed) { _, allowed in
                        if allowed { requestArtwork(app) }
                    }
            }
        }
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
            GeometryReader { geometry in
                ZStack {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        fallback
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .swiftlightArtworkHighlight(active: highlighted, cornerRadius: 12)
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
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(CoverPressStyle())
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: highlighted)
        .accessibilityLabel("\(isRunning ? "Resume" : "Launch") \(app.name)")
        .help(app.name)
    }

    private var fallback: some View {
        VStack(spacing: 18) {
            Image(systemName: app.name.localizedCaseInsensitiveContains("desktop") ? "desktopcomputer" : "gamecontroller")
                .font(.system(size: 40, weight: .light))
            Text(app.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center).lineLimit(5)
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
