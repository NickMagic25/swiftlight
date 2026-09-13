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
                Toggle("Start streams in full screen", isOn: $model.settings.launchInFullScreen)
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
                Text("Stream quality, video and presentation changes apply on the next connection. Sunshine uses the host's configured display modes; Apollo may provide a virtual display when permitted.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save for This Computer") { model.saveSettings() }.swiftlightGlassButton(prominent: true).disabled(model.selectedHost == nil)
                    Button("Use as Global Defaults") { model.saveSettings(asDefault: true) }.swiftlightGlassButton()
                }
            }
        }.formStyle(.grouped)
    }
}
