import Foundation
import SwiftUI
import SwiftlightCore

/// Shared controls bind to the caller's settings. The caller owns staging,
/// persistence, host defaults, and presentation of its settings surface.
struct StreamSettingsSections: View {
    @Binding var settings: StreamSettings
    @Binding var preferences: StreamStatisticsPreferences
    var showByDefault: Binding<Bool>? = nil
    var display: DisplayGeometry? = nil
    var hardwareDetail: String? = nil

    var body: some View {
        StreamVideoSettingsSection(settings: $settings, display: display, hardwareDetail: hardwareDetail)
        StreamQualitySettingsSection(settings: $settings)
        StreamAudioSettingsSection(settings: $settings)
        StreamPerformanceSettingsSection(settings: $settings)
        StreamStatisticsSettingsSection(preferences: $preferences, showByDefault: showByDefault)
    }
}

struct StreamVideoSettingsSection: View {
    @Binding var settings: StreamSettings
    var display: DisplayGeometry? = nil
    var hardwareDetail: String? = nil
    private let frameRates = [30, 60, 90, 120, 144, 165, 240]

    var body: some View {
        Section("Video") {
            Picker("Resolution", selection: $settings.resolution) {
                ForEach(ResolutionMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("resolution")
            if settings.resolution == .custom {
                StreamNumericField("Width (pixels)", value: $settings.customSize.width, identifier: "customWidth")
                StreamNumericField("Height (pixels)", value: $settings.customSize.height, identifier: "customHeight")
            }
            if let display {
                let size = settings.resolvedSize(display: display)
                LabeledContent("Requested pixels", value: "\(size.width) × \(size.height)")
            }
            if settings.resolution == .nativeSafeArea {
                Text("Uses the current content area intersected with the destination display's safe area. Dimensions are rounded down to even pixels.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if settings.resolution == .native || settings.resolution == .window {
                Text("Native Display uses the full display's pixels. Window follows the app's current window size.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Frame rate", selection: $settings.framesPerSecond) {
                Text("Display refresh rate").tag(0)
                ForEach(frameRates, id: \.self) { Text("\($0) FPS").tag($0) }
                // Retain a matching tag while editing an arbitrary frame rate.
                if settings.framesPerSecond != 0 && !frameRates.contains(settings.framesPerSecond) {
                    Text("Custom").tag(settings.framesPerSecond)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("frameRate")
            StreamNumericField("Custom FPS (0 = display)", value: $settings.framesPerSecond, identifier: "customFrameRate")
            if let display {
                LabeledContent("Display refresh", value: display.refreshHz.formatted(.number.precision(.fractionLength(2))) + " Hz")
            }
            Picker("Codec", selection: $settings.codec) {
                Text("Automatic").tag(CodecPreference.auto)
                Text("HEVC").tag(CodecPreference.hevc)
                Text("AV1").tag(CodecPreference.av1)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("codec")
            Picker("HDR", selection: $settings.hdr) {
                Text("Automatic").tag(HDRPreference.auto)
                Text("On").tag(HDRPreference.on)
                Text("Off").tag(HDRPreference.off)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("hdrPreference")
            if let hardwareDetail, !hardwareDetail.isEmpty {
                Text(hardwareDetail).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Picture size", selection: $settings.scaling) {
                Text("Fit").tag(VideoScaling.fit)
                Text("Fill (Crop)").tag(VideoScaling.fill)
                Text("Integer").tag(VideoScaling.integer)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("videoScaling")
            Picker("Pointer", selection: $settings.pointerMode) {
                Text("Relative (Games)").tag(PointerMode.relative)
                Text("Absolute (Desktop)").tag(PointerMode.absolute)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("pointerMode")
        }
    }
}

struct StreamQualitySettingsSection: View {
    @Binding var settings: StreamSettings
    private var bitrate: String { settings.bitrateMbps.formatted(.number.precision(.fractionLength(0...1))) }

    var body: some View {
        Section {
            Toggle("Automatic bitrate", isOn: $settings.automaticBitrate)
                .accessibilityIdentifier("automaticBitrate")
            if !settings.automaticBitrate {
                VStack(alignment: .leading) {
                    LabeledContent("Bitrate", value: "\(bitrate) Mbps")
                    Slider(value: $settings.bitrateMbps, in: 1...150, step: 1)
                        .accessibilityLabel("Bitrate")
                        .accessibilityValue("\(bitrate) megabits per second")
                }
                StreamNumericField("Bitrate (Mbps)", value: $settings.bitrateMbps, identifier: "customBitrate")
            }
        } header: {
            Text("Quality")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Higher resolutions, frame rates, and bitrates need a faster connection. Available codecs depend on your computer and device.")
                Text("HDR requires a compatible computer and display. Automatic uses HDR when both support it; On requires HDR; Off uses standard dynamic range. Enable HDR on your computer before starting. Changes apply to your next stream.")
            }
        }
    }
}

struct StreamAudioSettingsSection: View {
    @Binding var settings: StreamSettings

    var body: some View {
        Section {
            Picker("Audio channels", selection: $settings.audioChannels) {
                ForEach(AudioChannelConfiguration.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("audioChannels")
            .accessibilityValue(settings.audioChannels.label)
            .onChange(of: settings.audioChannels) { _, channels in
                if channels == .stereo { settings.audioOutput = .direct }
            }
            Picker("Audio output", selection: Binding(
                get: { settings.effectiveAudioOutput },
                set: { settings.audioOutput = settings.audioChannels == .stereo ? .direct : $0 }
            )) {
                ForEach(AudioOutputMode.allCases.filter {
                    settings.audioChannels != .stereo || $0 == .direct
                }, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("audioOutput")
            .accessibilityValue(settings.effectiveAudioOutput.label)
            Toggle("Play audio on computer", isOn: $settings.playAudioOnHost)
                .accessibilityIdentifier("playAudioOnComputer")
        } header: {
            Text("Audio")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if settings.audioChannels == .stereo {
                    Text("Use Stereo and Direct for a game's headphone or binaural mix. Choose 5.1 or 7.1 to enable System Spatial Audio.")
                } else if settings.effectiveAudioOutput == .systemSpatial {
                    #if os(macOS)
                    Text("Set the host and game to surround speakers. With compatible AirPods, use the macOS AirPods menu to choose Off, Fixed or Head Tracked when available. macOS controls whether spatial playback is active. This mode uses additional audio buffering.")
                    #else
                    Text("Set the host and game to surround speakers. With compatible AirPods, open Control Center, touch and hold the volume control, and choose Spatial Audio when available. Your device controls spatial playback and head tracking. This mode uses additional audio buffering.")
                    #endif
                } else {
                    Text("Set the host and game to surround speakers. Direct uses the output's available channels and downmixes for smaller routes. Choose System Spatial Audio for Apple-managed surround playback on compatible AirPods.")
                }
                Text("Audio changes apply the next time you start a stream.")
            }
        }
    }
}

struct StreamPerformanceSettingsSection: View {
    @Binding var settings: StreamSettings

    var body: some View {
        Section {
            #if os(macOS)
            Toggle("Start streams in full screen", isOn: $settings.launchInFullScreen)
            #endif
            Picker("Frame pacing", selection: $settings.videoPacing) {
                Text("On decoded frame").tag(VideoPacing.immediate)
                Text("Display paced").tag(VideoPacing.displayLink)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("videoPacing")
            .accessibilityValue(settings.videoPacing == .immediate ? "On decoded frame" : "Display paced")
            #if os(macOS)
            Toggle("VSync", isOn: $settings.displaySyncEnabled)
            #endif
            Picker("Drawable buffers", selection: $settings.maximumDrawableCount) {
                Text("3 (default)").tag(3)
                Text("2").tag(2)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("maximumDrawableCount")
            .accessibilityValue(settings.maximumDrawableCount == 3 ? "3 (default)" : "2")
        } header: {
            Text("Performance")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("On decoded frame responds to newly decoded video. Display paced follows the screen's refresh, including ProMotion. Performance changes apply to your next stream.")
                #if os(macOS)
                Text("VSync can reduce tearing at the cost of latency.")
                #endif
            }
        }
    }
}

struct StreamStatisticsSettingsSection: View {
    @Binding var preferences: StreamStatisticsPreferences
    var showByDefault: Binding<Bool>? = nil

    var body: some View {
        Section {
            if let showByDefault {
                Toggle("Show statistics by default", isOn: showByDefault)
                    .accessibilityIdentifier("showStatisticsByDefault")
            }
            Picker("Detail", selection: $preferences.detail) {
                ForEach(StreamStatisticsDetail.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("statisticsDetail")
            Picker("Position", selection: $preferences.position) {
                ForEach(StreamStatisticsPosition.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("statisticsPosition")
        } header: {
            Text("Stream Statistics")
        } footer: {
            #if os(macOS)
            Text("Press Control–Option–Shift–S to show or hide statistics. These preferences save immediately and apply to every computer.")
            #else
            Text("Choose whether statistics appear when a stream starts. Tap with three fingers during a stream to show or hide them without changing this default.")
            #endif
        }
    }
}

/// Numeric edits reach the draft before Save without depending on a Return key
/// or focus resignation. Invalid text is rejected by StreamSettings.validated().
private struct StreamNumericField<Value: Equatable>: View {
    let title: LocalizedStringKey
    @Binding var value: Value
    let identifier: String
    let format: (Value) -> String
    let parse: (String) -> Value?
    let invalidValue: Value
    @State private var text: String

    private init(_ title: LocalizedStringKey, value: Binding<Value>, identifier: String,
                 format: @escaping (Value) -> String, parse: @escaping (String) -> Value?, invalidValue: Value) {
        self.title = title
        _value = value
        self.identifier = identifier
        self.format = format
        self.parse = parse
        self.invalidValue = invalidValue
        _text = State(initialValue: format(value.wrappedValue))
    }

    var body: some View {
        LabeledContent {
            TextField(title, text: Binding(
                get: { text },
                set: { newText in
                    // Update both values in the edit transaction. Two reciprocal
                    // onChange handlers can replay an older value into the field
                    // while UIKit is delivering a multi-character edit.
                    text = newText
                    value = parse(newText) ?? invalidValue
                }
            ))
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                #endif
                .onChange(of: value) { _, newValue in
                    // A preset picker or slider can change this value too.
                    // Keep in-progress equivalent text, including an empty
                    // invalid draft, while reflecting external changes.
                    if let parsed = parse(text) {
                        if parsed != newValue { text = format(newValue) }
                    } else if newValue != invalidValue {
                        text = format(newValue)
                    }
                }
        } label: {
            Text(title)
        }
    }
}

private extension StreamNumericField where Value == Int {
    init(_ title: LocalizedStringKey, value: Binding<Int>, identifier: String) {
        self.init(title, value: value, identifier: identifier, format: { $0.formatted(.number.grouping(.never)) },
                  parse: { try? IntegerFormatStyle<Int>.number.parseStrategy.parse($0) }, invalidValue: -1)
    }
}

private extension StreamNumericField where Value == Double {
    init(_ title: LocalizedStringKey, value: Binding<Double>, identifier: String) {
        self.init(title, value: value, identifier: identifier, format: { $0.formatted(.number.grouping(.never)) },
                  parse: {
                      guard let value = try? FloatingPointFormatStyle<Double>.number.parseStrategy.parse($0), value.isFinite else { return nil }
                      return value
                  }, invalidValue: -1)
    }
}
