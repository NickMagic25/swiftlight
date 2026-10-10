#if os(iOS)
import SwiftUI
import SwiftlightCore

struct MobileSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MobileClientModel
    @State private var draft: StreamSettings
    @State private var statisticsDraft: StreamStatisticsPreferences
    @State private var showStatisticsByDefaultDraft: Bool
    @State private var errorMessage: String?

    init(model: MobileClientModel) {
        self.model = model
        _draft = State(initialValue: model.settings)
        _statisticsDraft = State(initialValue: model.statisticsPreferences)
        _showStatisticsByDefaultDraft = State(initialValue: model.showStatisticsByDefault)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Touch mode", selection: $draft.mobileTouchMode) {
                        Text("Trackpad").tag(MobileTouchMode.trackpad)
                        Text("Native Touch").tag(MobileTouchMode.nativeTouch)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("mobileTouchMode")
                    .accessibilityValue(draft.mobileTouchMode == .trackpad ? "Trackpad" : "Native Touch")
                } header: {
                    Text("Touch Input")
                } footer: {
                    Text("Trackpad: slide to move, tap to click, double tap and hold to drag, or use two fingers to right-click and scroll. Native Touch sends touches directly to a supporting computer. Unsupported computers use Trackpad. Changes apply to your next stream.")
                }
                StreamSettingsSections(settings: $draft, preferences: $statisticsDraft,
                                       showByDefault: $showStatisticsByDefaultDraft)
                AppBuildIdentitySection()
            }
            .accessibilityIdentifier("streamSettingsForm")
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
                            try model.saveSettings(draft, statistics: statisticsDraft,
                                                   showStatisticsByDefault: showStatisticsByDefaultDraft)
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

#endif
