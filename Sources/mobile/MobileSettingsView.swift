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
                StreamSettingsSections(settings: $draft, preferences: $statisticsDraft,
                                       showByDefault: $showStatisticsByDefaultDraft)
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
