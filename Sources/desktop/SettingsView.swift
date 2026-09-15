#if os(macOS)
import SwiftUI
import SwiftlightCore

struct SettingsView: View {
    @ObservedObject var model: ClientModel
    var body: some View {
        Form {
            StreamSettingsSections(settings: $model.settings, preferences: $model.statisticsPreferences,
                                   display: model.display, hardwareDetail: model.hardwareDetail)
                .onChange(of: model.statisticsPreferences) { _, _ in model.saveStatisticsPreferences() }
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

#endif
