import SwiftUI
import PencilKit

struct RecordingOverlayView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        RecordingOverlayContent(settings: settingsStore.settings)
    }
}

struct RecordingOverlayContent: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.modelContext) private var modelContext

    @StateObject private var viewModel: RecordingViewModel
    @GestureState private var pinchScale: CGFloat = 1.0

    init(settings: AppSettings) {
        _viewModel = StateObject(wrappedValue: RecordingViewModel(settings: settings))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Симуляция фона записи экрана (в продакшене — RPScreenRecorder preview)
            LinearGradient(
                colors: [.gray.opacity(0.3), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            faceCamOverlay
            touchIndicatorsLayer
            drawingLayer
            controlsOverlay
            timerBadge

            if SimulatorSupport.isRunning {
                VStack {
                    SimulatorBanner()
                    Spacer()
                }
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(!viewModel.showTimer)
        .task {
            await viewModel.prepare()
            if !viewModel.isRecording {
                await viewModel.startRecording()
            }
        }
        .onDisappear { viewModel.cleanup() }
        .onTapGesture(count: 2) {
            Task { await stopAndOpenEditor() }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    viewModel.addTouchIndicator(at: value.location)
                    viewModel.userInteraction()
                }
        )
        .onChange(of: viewModel.lastError?.localizedDescription) { _, message in
            guard !SimulatorSupport.isRunning, let message else { return }
            coordinator.alertMessage = message
        }
    }

    // MARK: - Face Cam

    private var faceCamOverlay: some View {
        GeometryReader { geo in
            let baseSize = GlassyTheme.faceCamDefaultSize * settingsStore.settings.faceCamScale
            let size = baseSize * viewModel.faceCamScale * pinchScale

            FaceCamView(
                session: viewModel.cameraService.session,
                isSimulatorMode: viewModel.cameraService.isSimulatorMode,
                shape: settingsStore.settings.faceCamShape,
                glassesEnabled: viewModel.glassesEnabled,
                glassesColor: viewModel.glassesService.frameColor,
                mirrored: settingsStore.settings.faceCamMirrored
            )
            .frame(width: size, height: size)
            .clipShape(faceCamClipShape)
            .liquidGlass(cornerRadius: faceCamCornerRadius(size: size))
            .overlay(alignment: .topTrailing) {
                if viewModel.glassesEnabled {
                    Image(systemName: "eyeglasses")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.yellow)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(6)
                        .accessibilityLabel("Наложение очков активно")
                }
            }
            .position(faceCamCenter(in: geo.size, camSize: size))
            .gesture(faceCamDragGesture(in: geo.size, camSize: size))
            .gesture(faceCamPinchGesture)
            .animation(GlassyTheme.spring, value: viewModel.faceCamPosition)
        }
    }

    private var faceCamClipShape: some Shape {
        switch settingsStore.settings.faceCamShape {
        case .circle:
            AnyShape(Circle())
        case .roundedRectangle:
            AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .capsule:
            AnyShape(Capsule())
        }
    }

    private func faceCamCornerRadius(size: CGFloat) -> CGFloat {
        switch settingsStore.settings.faceCamShape {
        case .circle: size / 2
        case .roundedRectangle: 16
        case .capsule: size / 2
        }
    }

    private func faceCamCenter(in container: CGSize, camSize: CGFloat) -> CGPoint {
        CGPoint(
            x: viewModel.faceCamPosition.x * container.width,
            y: viewModel.faceCamPosition.y * container.height
        )
    }

    private func faceCamDragGesture(in container: CGSize, camSize: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                viewModel.userInteraction()
                let x = min(max(value.location.x / container.width, 0.1), 0.9)
                let y = min(max(value.location.y / container.height, 0.1), 0.9)
                viewModel.faceCamPosition = CGPoint(x: x, y: y)
            }
    }

    private var faceCamPinchGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchScale) { value, state, _ in state = value }
            .onEnded { value in
                viewModel.faceCamScale = min(max(viewModel.faceCamScale * value, 0.6), 1.8)
                viewModel.userInteraction()
            }
    }

    // MARK: - Drawing & Touches

    private var drawingLayer: some View {
        DrawingCanvasView(drawing: $viewModel.canvasDrawing, tool: viewModel.drawingTool)
            .allowsHitTesting(viewModel.showControls)
    }

    private var touchIndicatorsLayer: some View {
        GeometryReader { geo in
            ForEach(viewModel.touchIndicators) { indicator in
                Circle()
                    .fill(indicator.color.opacity(indicator.opacity))
                    .frame(width: indicator.size, height: indicator.size)
                    .position(indicator.position)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Controls

    private var controlsOverlay: some View {
        VStack {
            Spacer()
            if viewModel.showControls {
                RecordingControlPanel(
                    isRecording: viewModel.isRecording,
                    glassesEnabled: viewModel.glassesEnabled,
                    glassesColor: viewModel.glassesService.frameColor,
                    drawingTool: viewModel.drawingTool,
                    onStop: { Task { await stopAndOpenEditor() } },
                    onToggleGlasses: viewModel.toggleGlasses,
                    onGlassesColor: viewModel.setGlassesColor,
                    onToolChange: { viewModel.drawingTool = $0 }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(GlassyTheme.spring, value: viewModel.showControls)
        .onTapGesture { viewModel.userInteraction() }
    }

    private var timerBadge: some View {
        VStack {
            if viewModel.showTimer {
                Text(viewModel.duration.formattedDuration)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .liquidGlass(cornerRadius: 10)
                    .padding(.top, 8)
            }
            Spacer()
        }
        .animation(.easeInOut, value: viewModel.showTimer)
    }

    private func stopAndOpenEditor() async {
        if let session = await viewModel.stopRecording() {
            PersistenceController.shared.saveRecording(session, context: modelContext)
            coordinator.showEditor(for: session)
        }
    }
}

struct FaceCamView: View {
    let session: AVCaptureSession
    var isSimulatorMode: Bool = false
    let shape: FaceCamShape
    let glassesEnabled: Bool
    let glassesColor: GlassesFrameColor
    var mirrored: Bool = true

    var body: some View {
        ZStack {
            if isSimulatorMode {
                SimulatorFaceCamPreview(
                    glassesEnabled: glassesEnabled,
                    glassesColor: glassesColor,
                    mirrored: mirrored
                )
            } else {
                CameraPreviewView(session: session)
            }
        }
        .background(Color.black)
    }
}

struct AnyShape: Shape, @unchecked Sendable {
    private let pathBuilder: @Sendable (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        pathBuilder = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path {
        pathBuilder(rect)
    }
}

extension TimeInterval {
    var formattedDuration: String {
        let minutes = Int(self) / 60
        let seconds = Int(self) % 60
        let fraction = Int((self.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, fraction)
    }
}

import AVFoundation
