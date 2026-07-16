import SwiftUI
import AVKit

@MainActor
final class EditorViewModel: ObservableObject {
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 1
    @Published var isExporting = false
    @Published var player: AVPlayer?
    @Published var duration: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var exportSucceeded = false

    let session: RecordingSession
    private let exportService = ExportService()

    init(session: RecordingSession) {
        self.session = session
        let url = session.fileURL
        let asset = AVURLAsset(url: url)
        player = AVPlayer(url: url)
        Task {
            duration = (try? await asset.load(.duration).seconds) ?? session.duration
            trimEnd = duration
        }
    }

    func exportToGallery() async {
        isExporting = true
        defer { isExporting = false }

        do {
            let url = session.fileURL
            let isFullRange = trimStart <= 0.01 && trimEnd >= max(duration - 0.05, 0)

            if isFullRange {
                try await exportService.saveToPhotoLibrary(url: url)
            } else {
                UsageTracker.shared.track(
                    .trimUsed,
                    params: [
                        "start_s": String(format: "%.1f", trimStart),
                        "end_s": String(format: "%.1f", trimEnd)
                    ]
                )
                let asset = AVURLAsset(url: url)
                let start = CMTime(seconds: trimStart, preferredTimescale: 600)
                let end = CMTime(seconds: trimEnd, preferredTimescale: 600)
                let range = CMTimeRange(start: start, end: end)
                let exported = try await exportService.export(
                    asset: asset,
                    codec: .hevc,
                    trimRange: range
                )
                try await exportService.saveToPhotoLibrary(url: exported)
            }
            exportSucceeded = true
            UsageTracker.shared.track(
                .exportSucceeded,
                params: ["trimmed": String(!isFullRange)]
            )
        } catch {
            errorMessage = error.localizedDescription
            UsageTracker.shared.track(
                .exportFailed,
                params: ["reason": String(error.localizedDescription.prefix(120))]
            )
        }
    }
}

struct EditorView: View {
    @StateObject private var viewModel: EditorViewModel
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var timelineScale: CGFloat = 1.0

    init(session: RecordingSession) {
        _viewModel = StateObject(wrappedValue: EditorViewModel(session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
            trimControls
            exportBar
        }
        .navigationTitle("Редактор")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Ошибка", isPresented: .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("Готово", isPresented: $viewModel.exportSucceeded) {
            Button("OK") { coordinator.popToRoot() }
        } message: {
            Text("Видео сохранено в «Фото»")
        }
    }

    private var preview: some View {
        ZStack {
            Color.black
            if let player = viewModel.player {
                VideoPlayer(player: player)
            } else {
                PlaceholderStateView(title: "Нет видео", systemImage: "film")
            }
        }
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private var trimControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Обрезка")
                .font(.headline)
            HStack {
                Text(viewModel.trimStart.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(GlassyTheme.labelSecondary)
                Spacer()
                Text(viewModel.trimEnd.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(GlassyTheme.labelSecondary)
            }
            TimelineView(
                duration: viewModel.duration,
                trimStart: $viewModel.trimStart,
                trimEnd: $viewModel.trimEnd,
                scale: $timelineScale
            )
            .frame(height: 64)
        }
        .padding()
    }

    private var exportBar: some View {
        HStack {
            Text("ReplayKit MP4")
                .font(.caption)
                .foregroundStyle(GlassyTheme.labelSecondary)

            Spacer()

            Button {
                Task { await viewModel.exportToGallery() }
            } label: {
                if viewModel.isExporting {
                    ProgressView()
                } else {
                    Label("Сохранить в «Фото»", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isExporting)
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}

struct TimelineView: View {
    let duration: TimeInterval
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    @Binding var scale: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.secondarySystemFill))

                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: selectionWidth(in: geo.size.width))
                    .offset(x: startOffset(in: geo.size.width))

                trimHandle(at: startOffset(in: geo.size.width))
                trimHandle(at: startOffset(in: geo.size.width) + selectionWidth(in: geo.size.width))
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { value in scale = min(max(value, 0.5), 3) }
            )
        }
    }

    private func startOffset(in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(trimStart / duration) * width
    }

    private func selectionWidth(in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return width }
        return CGFloat((trimEnd - trimStart) / duration) * width
    }

    private func trimHandle(at x: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .frame(width: 4, height: 48)
            .offset(x: x - 2)
    }
}

import AVFoundation
