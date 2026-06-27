import SwiftUI
import AVKit

@MainActor
final class EditorViewModel: ObservableObject {
    @Published var selectedTab: EditorTab = .trim
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 1
    @Published var micVolume: Float = 1.0
    @Published var systemVolume: Float = 1.0
    @Published var selectedFilter: VideoFilter = .none
    @Published var exportCodec: ExportCodec = .hevc
    @Published var isExporting = false
    @Published var player: AVPlayer?
    @Published var duration: TimeInterval = 0
    @Published var errorMessage: String?

    let session: RecordingSession
    private let exportService = ExportService()

    init(session: RecordingSession) {
        self.session = session
        if let url = session.fileURL {
            let asset = AVURLAsset(url: url)
            player = AVPlayer(url: url)
            Task {
                duration = (try? await asset.load(.duration).seconds) ?? session.duration
                trimEnd = duration
            }
        }
    }

    func exportToGallery() async {
        guard let url = session.fileURL else {
            errorMessage = GlassyRecordError.fileNotFound.localizedDescription
            return
        }
        isExporting = true
        defer { isExporting = false }

        do {
            let asset = AVURLAsset(url: url)
            let start = CMTime(seconds: trimStart, preferredTimescale: 600)
            let end = CMTime(seconds: trimEnd, preferredTimescale: 600)
            let range = CMTimeRange(start: start, end: end)

            guard let renderService = RenderService() else {
                errorMessage = GlassyRecordError.exportFailed("Metal недоступен").localizedDescription
                return
            }
            let exported = try await exportService.export(
                asset: asset,
                codec: exportCodec,
                trimRange: range,
                filter: selectedFilter,
                renderService: renderService
            )
            try await exportService.saveToPhotoLibrary(url: exported)
        } catch {
            errorMessage = error.localizedDescription
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
            editorTabs
            tabContent
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
    }

    private var preview: some View {
        ZStack {
            Color.black
            if let player = viewModel.player {
                VideoPlayer(player: player)
            } else {
                ContentUnavailableView("Нет видео", systemImage: "film")
            }
        }
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private var editorTabs: some View {
        Picker("Инструмент", selection: $viewModel.selectedTab) {
            ForEach(EditorTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

  @ViewBuilder
    private var tabContent: some View {
        switch viewModel.selectedTab {
        case .trim:
            trimControls
        case .audio:
            audioControls
        case .filters:
            filterControls
        case .text:
            textControls
        }
    }

    private var trimControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Обрезка")
                .font(.headline)
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

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Громкость дорожек")
                .font(.headline)
            LabeledContent("Микрофон") {
                Slider(value: $viewModel.micVolume, in: 0...2)
            }
            LabeledContent("Системный звук") {
                Slider(value: $viewModel.systemVolume, in: 0...2)
            }
        }
        .padding()
    }

    private var filterControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(VideoFilter.allCases) { filter in
                    Button {
                        viewModel.selectedFilter = filter
                    } label: {
                        Text(filter.displayName)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(viewModel.selectedFilter == filter ? Color.accentColor : Color(.secondarySystemFill))
                            .foregroundStyle(viewModel.selectedFilter == filter ? .white : .primary)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
    }

    private var textControls: some View {
        ContentUnavailableView(
            "Текст и фигуры",
            systemImage: "text.badge.plus",
            description: Text("Добавьте подписи в следующем обновлении")
        )
        .frame(height: 120)
    }

    private var exportBar: some View {
        HStack {
            Picker("Кодек", selection: $viewModel.exportCodec) {
                ForEach(ExportCodec.allCases) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }
            .pickerStyle(.menu)

            Spacer()

            Button {
                Task { await viewModel.exportToGallery() }
            } label: {
                if viewModel.isExporting {
                    ProgressView()
                } else {
                    Label("Экспорт", systemImage: "square.and.arrow.up")
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

                // Trim handles
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
