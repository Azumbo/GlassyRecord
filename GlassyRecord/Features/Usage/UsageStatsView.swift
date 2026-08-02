import SwiftUI
import UIKit

/// Экран статистики + кнопка «Скопировать отчёт» для передачи в Cursor.
struct UsageStatsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @ObservedObject private var tracker = UsageTracker.shared
    @State private var copied = false
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                Text(L10n.t("usage.intro"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    copyReport()
                } label: {
                    Label(
                        copied ? L10n.t("usage.copied") : L10n.t("usage.copy_report"),
                        systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc"
                    )
                }
                .foregroundStyle(copied ? .green : .accentColor)

                ShareLink(
                    item: tracker.makeHandoffReport(settings: settingsStore.settings),
                    subject: Text(L10n.t("usage.share_subject")),
                    message: Text(L10n.t("usage.share_message"))
                ) {
                    Label(L10n.t("usage.share_report"), systemImage: "square.and.arrow.up")
                }
            }

            Section(L10n.t("usage.used")) {
                let used = UsageFeature.allCases
                    .filter { $0 != .usageReset && tracker.counts[$0.rawValue, default: 0] > 0 }
                    .sorted { tracker.counts[$0.rawValue, default: 0] > tracker.counts[$1.rawValue, default: 0] }
                if used.isEmpty {
                    Text(L10n.t("usage.used_empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(used) { feature in
                        HStack {
                            Text(feature.displayTitle)
                            Spacer()
                            Text("\(tracker.counts[feature.rawValue, default: 0])")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }

            Section(L10n.t("usage.never")) {
                let unused = UsageFeature.allCases.filter {
                    $0 != .usageReset && tracker.counts[$0.rawValue, default: 0] == 0
                }
                if unused.isEmpty {
                    Text(L10n.t("usage.never_empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(unused) { feature in
                        Text(feature.displayTitle)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button(L10n.t("usage.reset"), role: .destructive) {
                    confirmReset = true
                }
            }
        }
        .navigationTitle(L10n.t("nav.stats"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            tracker.track(.usageStatsOpened)
        }
        .confirmationDialog(L10n.t("usage.reset_confirm"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(L10n.t("usage.reset_action"), role: .destructive) {
                tracker.reset()
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        }
    }

    private func copyReport() {
        let report = tracker.makeHandoffReport(settings: settingsStore.settings)
        UIPasteboard.general.string = report
        tracker.track(.usageReportCopied)
        copied = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
