import SwiftUI
import SwiftlightCore

struct MobileSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MobileClientModel
    @State private var draft: StreamSettings
    @State private var errorMessage: String?

    init(model: MobileClientModel) {
        self.model = model
        _draft = State(initialValue: model.settings)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    Picker("Resolution", selection: $draft.resolution) {
                        Text("720p").tag(ResolutionMode.hd720)
                        Text("1080p").tag(ResolutionMode.hd1080)
                        Text("1440p").tag(ResolutionMode.qhd1440)
                        Text("4K").tag(ResolutionMode.uhd4K)
                        Text("Display resolution").tag(ResolutionMode.native)
                    }
                    Picker("Frame rate", selection: $draft.framesPerSecond) {
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                        Text("120 FPS").tag(120)
                        Text("Display refresh rate").tag(0)
                    }
                    .accessibilityIdentifier("frameRate")
                    Picker("Codec", selection: $draft.codec) {
                        Text("Automatic").tag(CodecPreference.auto)
                        Text("HEVC").tag(CodecPreference.hevc)
                        Text("AV1").tag(CodecPreference.av1)
                    }
                    Picker("Picture size", selection: $draft.scaling) {
                        Text("Fit").tag(VideoScaling.fit)
                        Text("Fill").tag(VideoScaling.fill)
                    }
                }
                Section {
                    Toggle("Automatic bitrate", isOn: $draft.automaticBitrate)
                        .accessibilityIdentifier("automaticBitrate")
                    if !draft.automaticBitrate {
                        VStack(alignment: .leading) {
                            LabeledContent("Bitrate", value: "\(Int(draft.bitrateMbps)) Mbps")
                            Slider(value: $draft.bitrateMbps, in: 5...150, step: 5)
                                .accessibilityLabel("Bitrate")
                                .accessibilityValue("\(Int(draft.bitrateMbps)) megabits per second")
                        }
                    }
                } header: {
                    Text("Quality")
                } footer: {
                    Text("Higher resolutions, frame rates, and bitrates need a faster connection. This version supports standard dynamic range video. Available codecs depend on your computer and device.")
                }
                Section {
                    Toggle("Play audio on computer", isOn: $draft.playAudioOnHost)
                        .accessibilityIdentifier("playAudioOnComputer")
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Changes apply the next time you start a stream.")
                }
            }
            .navigationTitle("Stream Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .accessibilityIdentifier("cancelStreamSettings")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try model.saveSettings(draft)
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .accessibilityIdentifier("saveStreamSettings")
                }
            }
            .alert("Settings could not be saved", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}
