import SwiftUI

/// The settings window: Dock, menu bar label and panel blocks.
struct SettingsView: View {
    let dockChanged: () -> Void
    @AppStorage(Pref.showInDock) private var showInDock = false

    var body: some View {
        Form {
            Section("Основные") {
                Toggle("Показывать в Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, _ in dockChanged() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
