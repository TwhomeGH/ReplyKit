import Foundation
import SwiftUI

struct AVLagSettingsView: View {
    @AppStorage(AVLagSettings.modeKey, store: userDefaults)
    private var modeRaw = AVLagPersistenceMode.memoryOnly.rawValue
    @AppStorage(AVLagSettings.segmentHoursKey, store: userDefaults)
    private var segmentHours = 4
    @AppStorage(AVLagSettings.longSessionSegmentsKey, store: userDefaults)
    private var longSessionSegments = false
    @State private var showClearConfirmation = false

    private var isPersistent: Bool {
        modeRaw == AVLagPersistenceMode.recentSessions.rawValue
    }

    var body: some View {
        Form {
            Section(AppLanguage.localized("avLag.settings.mode")) {
                Picker(AppLanguage.localized("avLag.settings.mode"), selection: $modeRaw) {
                    Text(AppLanguage.localized("avLag.settings.memory"))
                        .tag(AVLagPersistenceMode.memoryOnly.rawValue)
                    Text(AppLanguage.localized("avLag.settings.recent"))
                        .tag(AVLagPersistenceMode.recentSessions.rawValue)
                }
                Text(isPersistent
                    ? AppLanguage.localized("avLag.settings.footerRecent")
                    : AppLanguage.localized("avLag.settings.footerMemory"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isPersistent {
                Section(AppLanguage.localized("avLag.settings.longSession")) {
                    Toggle(AppLanguage.localized("avLag.settings.long"), isOn: $longSessionSegments)
                    Picker(AppLanguage.localized("avLag.settings.segment"), selection: $segmentHours) {
                        ForEach([1, 2, 4, 8], id: \.self) { hours in
                            Text(String(format: AppLanguage.localized("avLag.settings.hours"), hours))
                                .tag(hours)
                        }
                    }
                    Text(AppLanguage.localized(longSessionSegments
                        ? "avLag.settings.footerLongOn" : "avLag.settings.footerLongOff"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(AppLanguage.localized("avLag.settings.clear"), role: .destructive) {
                    showClearConfirmation = true
                }
            }
        }
        .navigationTitle(AppLanguage.localized("avLag.settings.title"))
        .alert(AppLanguage.localized("avLag.settings.clear"), isPresented: $showClearConfirmation) {
            Button(AppLanguage.localized("avLag.settings.cancel"), role: .cancel) {}
            Button(AppLanguage.localized("avLag.settings.clearConfirm"), role: .destructive) {
                Task { await AVLagReportStore.shared.clear() }
            }
        } message: {
            Text(AppLanguage.localized("avLag.settings.clearMessage"))
        }
    }
}
