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
                Text("Пользуйтесь приложением как обычно несколько дней. Потом нажмите «Скопировать отчёт» и вставьте текст в чат Cursor — по нему будет видно, что оставить, а что удалить.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    copyReport()
                } label: {
                    Label(
                        copied ? "Скопировано" : "Скопировать отчёт",
                        systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc"
                    )
                }
                .foregroundStyle(copied ? .green : .accentColor)

                ShareLink(
                    item: tracker.makeHandoffReport(settings: settingsStore.settings),
                    subject: Text("Glassy Record usage"),
                    message: Text("Usage report for Cursor")
                ) {
                    Label("Поделиться отчётом", systemImage: "square.and.arrow.up")
                }
            }

            Section("Использовали") {
                let used = UsageFeature.allCases
                    .filter { $0 != .usageReset && tracker.counts[$0.rawValue, default: 0] > 0 }
                    .sorted { tracker.counts[$0.rawValue, default: 0] > tracker.counts[$1.rawValue, default: 0] }
                if used.isEmpty {
                    Text("Пока пусто — откройте запись, настройки и т.д.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(used) { feature in
                        HStack {
                            Text(feature.titleRU)
                            Spacer()
                            Text("\(tracker.counts[feature.rawValue, default: 0])")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }

            Section("Ни разу не использовали") {
                let unused = UsageFeature.allCases.filter {
                    $0 != .usageReset && tracker.counts[$0.rawValue, default: 0] == 0
                }
                if unused.isEmpty {
                    Text("Все фичи из каталога уже трогали.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(unused) { feature in
                        Text(feature.titleRU)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("Сбросить статистику", role: .destructive) {
                    confirmReset = true
                }
            }
        }
        .navigationTitle("Статистика")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            tracker.track(.usageStatsOpened)
        }
        .confirmationDialog("Сбросить счётчики?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Сбросить", role: .destructive) {
                tracker.reset()
            }
            Button("Отмена", role: .cancel) {}
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
