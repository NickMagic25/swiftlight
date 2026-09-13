import SwiftUI
import SwiftlightCore

struct SettingsView: View {
    @ObservedObject var model: ClientModel
    var body: some View {
        Form {
            Section {
                Picker("Resolution", selection: $model.settings.resolution) {
                    ForEach(ResolutionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if model.settings.resolution == .custom {
                    HStack {
                        TextField("Width", value: $model.settings.customSize.width, format: .number)
                        Text("×")
                        TextField("Height", value: $model.settings.customSize.height, format: .number)
                    }
                }
                let size = model.settings.resolvedSize(display: model.display)
                LabeledContent("Requested pixels", value: "\(size.width) × \(size.height)")
                if model.settings.resolution == .nativeSafeArea { Text("Uses the current content area intersected with the destination display's safe area. Dimensions are rounded down to even pixels.").font(.caption).foregroundStyle(.secondary) }
                Picker("Requested stream FPS", selection: $model.settings.framesPerSecond) {
                    Text("Match Display").tag(0)
                    ForEach([30, 60, 90, 120, 144, 165, 240], id: \.self) { Text("\($0)").tag($0) }
                }
                TextField("Custom FPS (0 = display)", value: $model.settings.framesPerSecond, format: .number)
                LabeledContent("Display refresh", value: model.display.refreshHz.formatted(.number.precision(.fractionLength(2))) + " Hz")
                Toggle("Automatic initial bitrate", isOn: $model.settings.automaticBitrate)
                if !model.settings.automaticBitrate {
                    Slider(value: $model.settings.bitrateMbps, in: 1...150, step: 1) { Text("Bitrate (Mbps)") }
                    TextField("Bitrate (Mbps)", value: $model.settings.bitrateMbps, format: .number)
                }
            } header: { Text("Stream Quality") }
            Section {
                Picker("Codec", selection: $model.settings.codec) { ForEach(CodecPreference.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Picker("HDR", selection: $model.settings.hdr) { ForEach(HDRPreference.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Text(model.hardwareDetail).font(.caption).foregroundStyle(.secondary)
                Picker("Scaling", selection: $model.settings.scaling) { Text("Fit").tag(VideoScaling.fit); Text("Fill (Crop)").tag(VideoScaling.fill); Text("Integer").tag(VideoScaling.integer) }
                Picker("Mouse", selection: $model.settings.pointerMode) {
                    Text("Relative (Games)").tag(PointerMode.relative); Text("Absolute (Desktop)").tag(PointerMode.absolute)
                }
            } header: { Text("Video") }
            Section {
                Picker("Audio channels", selection: $model.settings.audioChannels) {
                    ForEach(AudioChannelConfiguration.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: model.settings.audioChannels) { _, channels in
                    if channels == .stereo { model.settings.audioOutput = .direct }
                }
                Picker("Audio output", selection: Binding(
                    get: { model.settings.effectiveAudioOutput },
                    set: { model.settings.audioOutput = $0 }
                )) {
                    ForEach(AudioOutputMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                            .disabled(mode == .systemSpatial && model.settings.audioChannels == .stereo)
                    }
                }
                if model.settings.audioChannels == .stereo {
                    Text("Use Stereo and Direct for a game's headphone or binaural mix. Choose 5.1 or 7.1 to enable System Spatial Audio.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.settings.effectiveAudioOutput == .systemSpatial {
                    Text("Set the host and game to surround speakers. With compatible AirPods, use the macOS AirPods menu to choose Off, Fixed or Head Tracked when available. macOS controls whether spatial playback is active. This mode uses additional audio buffering.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Set the host and game to surround speakers. Direct sends the surround mix to the selected macOS output; speaker playback depends on its channel configuration. Choose System Spatial Audio for Apple-managed surround virtualization on compatible AirPods.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Play audio on host", isOn: $model.settings.playAudioOnHost)
                Text("Audio changes apply on the next connection. Save for this computer or use as global defaults below.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Audio") }
            Section {
                Toggle("Start streams in full screen", isOn: $model.settings.launchInFullScreen)
                Picker("Frame pacing", selection: $model.settings.videoPacing) {
                    ForEach(VideoPacing.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("VSync", isOn: $model.settings.displaySyncEnabled)
                Picker("Drawable buffers", selection: $model.settings.maximumDrawableCount) {
                    Text("3 (default)").tag(3); Text("2").tag(2)
                }
                Text("Reconnect to apply changes. On decoded frame minimizes waiting. Display paced adapts to the screen, including ProMotion. VSync can reduce tearing at the cost of latency.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Presentation") }
            Section {
                Picker("Detail", selection: $model.statisticsPreferences.detail) {
                    ForEach(StreamStatisticsDetail.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: model.statisticsPreferences.detail) { _, _ in model.saveStatisticsPreferences() }
                Picker("Position", selection: $model.statisticsPreferences.position) {
                    ForEach(StreamStatisticsPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: model.statisticsPreferences.position) { _, _ in model.saveStatisticsPreferences() }
                Text("Press Control–Option–Shift–S to show or hide statistics. These preferences save immediately and apply to every computer.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Stream Statistics") }
            Section {
                Text("Stream quality, video, audio and presentation changes apply on the next connection. Sunshine uses the host's configured display modes; Apollo may provide a virtual display when permitted.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save for This Computer") { model.saveSettings() }.swiftlightGlassButton(prominent: true).disabled(model.selectedHost == nil)
                    Button("Use as Global Defaults") { model.saveSettings(asDefault: true) }.swiftlightGlassButton()
                }
            }
        }.formStyle(.grouped)
    }
}
