import SwiftUI
import PencilKit
import UIKit

struct RecordingOverlayView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        RecordingOverlayContent(settings: settingsStore.settings)
    }
}

struct RecordingOverlayContent: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var viewModel: RecordingViewModel
    @GestureState private var pinchScale: CGFloat = 1.0

    init(settings: AppSettings) {
        _viewModel = StateObject(wrappedValue: RecordingViewModel(settings: settings))
    }

    var body: some View {
        ZStack {
            GlassyTheme.backgroundSecondary.ignoresSafeArea()

            if showPiPInlinePreview {
                pipInlineOverlay
            }

            if showFaceCamPlacement {
                faceCamOverlay
            }

            if !viewModel.usesBroadcastMode {
                touchIndicatorsLayer
                drawingLayer
            }

            controlsOverlay
            timerBadge
            broadcastBanner

            if SimulatorSupport.isRunning {
                VStack {
                    SimulatorBanner()
                    Spacer()
                }
            }

            if viewModel.isPreparing {
                preparingOverlay
            }

            if viewModel.isSaving {
                savingOverlay
            }

            if viewModel.isFailed {
                failedOverlay
            }

            if viewModel.isAwaitingBroadcast {
                broadcastSetupOverlay
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(!viewModel.showTimer)
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.cleanup() }
        .onTapGesture { viewModel.userInteraction() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                viewModel.refreshBroadcastState()
            }
        }
        .onChange(of: viewModel.lastError?.localizedDescription) { message in
            guard !SimulatorSupport.isRunning, let message else { return }
            coordinator.alertMessage = message
        }
    }

    private var showPiPInlinePreview: Bool {
        viewModel.usesBroadcastMode && (viewModel.isAwaitingBroadcast || viewModel.isRecording)
    }

    private var showFaceCamPlacement: Bool {
        !viewModel.usesBroadcastMode
    }

    private var pipInlineOverlay: some View {
        VStack {
            HStack {
                Spacer()
                if viewModel.isPiPPreviewReady {
                    PiPInlinePreview(displayLayer: viewModel.pipCameraManager.displayLayer)
                        .frame(width: 112, height: 148)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                        }
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                }
            }
            Spacer()
        }
    }

    private var preparingOverlay: some View {
        statusOverlay(title: "Подготовка…", subtitle: "Запуск записи в симуляторе")
    }

    private var savingOverlay: some View {
        statusOverlay(title: "Сохранение…", subtitle: "Добавляем видео в «Фото»")
    }

    private var broadcastSetupOverlay: some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                Text("Face Cam через системный PiP")
                    .font(.headline)
                Text("После старта записи селфи уйдёт в плавающее окно iOS. Позицию и размер задаёт система (4 угла, pinch, свайп за край). AR-очки накладываются до PiP — в видео попадёт то же, что в окошке.")
                    .font(.subheadline)
                    .foregroundStyle(GlassyTheme.labelSecondary)
                    .multilineTextAlignment(.center)

                Text("Нажмите кнопку ниже и подтвердите запись экрана и микрофон в системном диалоге iOS.")
                    .font(.caption)
                    .foregroundStyle(GlassyTheme.labelSecondary)
                    .multilineTextAlignment(.center)

                SystemBroadcastPickerRepresentable(
                    showsMicrophoneButton: settingsStore.settings.microphoneEnabled,
                    onPrepare: viewModel.prepareBroadcastConfig
                )
                .frame(height: 44)
                .padding(.horizontal, 8)

                if !AppGroup.isConfigured {
                    Text(AppGroup.diagnosticMessage)
                        .font(.caption)
                        .foregroundStyle(GlassyTheme.warning)
                        .multilineTextAlignment(.center)
                }

                if !BroadcastExtensionLocator.isExtensionEmbedded {
                    Text(BroadcastExtensionLocator.diagnosticMessage)
                        .font(.caption)
                        .foregroundStyle(GlassyTheme.warning)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
            .liquidGlass()
            .padding(.horizontal, 24)
            .padding(.bottom, 120)
        }
    }

    private var broadcastBanner: some View {
        VStack {
            if viewModel.usesBroadcastMode, viewModel.isRecording {
                Text("Запись идёт — переключитесь в любое приложение. Face Cam останется в системном PiP. Вернитесь сюда, чтобы остановить.")
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .liquidGlass(cornerRadius: 12)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            Spacer()
        }
    }

    private var failedOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(GlassyTheme.warning)
                Text("Не удалось записать")
                    .font(.headline)
                if case .failed(let message) = viewModel.setupPhase {
                    ScrollView {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(GlassyTheme.labelSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxHeight: 180)
                }
                HStack(spacing: 12) {
                    Button("Назад") { coordinator.popToRoot() }
                        .buttonStyle(.bordered)
                    Button("Повторить") {
                        viewModel.setupPhase = .idle
                        viewModel.prepareBroadcastConfig()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 32)
        }
    }

    private func statusOverlay(title: String, subtitle: String) -> some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(GlassyTheme.labelSecondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var faceCamOverlay: some View {
        GeometryReader { geo in
            let baseSize = GlassyTheme.faceCamDefaultSize * settingsStore.settings.faceCamScale
            let size = baseSize * viewModel.faceCamScale * pinchScale

            FaceCamView(
                session: viewModel.cameraService.isSimulatorMode ? viewModel.cameraService.session : nil,
                isSimulatorMode: viewModel.cameraService.isSimulatorMode,
                isPlacementPreview: false,
                usesARKitFaceCam: false,
                arSession: nil,
                arScene: nil,
                shape: settingsStore.settings.faceCamShape,
                glassesEnabled: viewModel.glassesEnabled,
                glassesColor: viewModel.glassesService.frameColor,
                mirrored: settingsStore.settings.faceCamMirrored
            )
            .frame(width: size, height: size)
            .clipShape(faceCamClipShape)
            .liquidGlass(cornerRadius: faceCamCornerRadius(size: size))
            .position(faceCamCenter(in: geo.size))
            .gesture(faceCamDragGesture(in: geo.size))
            .gesture(faceCamPinchGesture)
            .animation(GlassyTheme.spring, value: viewModel.faceCamPosition)
        }
    }

    private var faceCamClipShape: some Shape {
        switch settingsStore.settings.faceCamShape {
        case .circle: AnyShape(Circle())
        case .roundedRectangle: AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .capsule: AnyShape(Capsule())
        }
    }

    private func faceCamCornerRadius(size: CGFloat) -> CGFloat {
        switch settingsStore.settings.faceCamShape {
        case .circle: size / 2
        case .roundedRectangle: 16
        case .capsule: size / 2
        }
    }

    private func faceCamCenter(in container: CGSize) -> CGPoint {
        CGPoint(
            x: viewModel.faceCamPosition.x * container.width,
            y: viewModel.faceCamPosition.y * container.height
        )
    }

    private func faceCamDragGesture(in container: CGSize) -> some Gesture {
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

    private var drawingLayer: some View {
        DrawingCanvasView(drawing: $viewModel.canvasDrawing, tool: viewModel.drawingTool)
            .allowsHitTesting(viewModel.showControls)
    }

    private var touchIndicatorsLayer: some View {
        GeometryReader { _ in
            ForEach(viewModel.touchIndicators) { indicator in
                Circle()
                    .fill(indicator.color.opacity(indicator.opacity))
                    .frame(width: indicator.size, height: indicator.size)
                    .position(indicator.position)
            }
        }
        .allowsHitTesting(false)
    }

    private var controlsOverlay: some View {
        VStack {
            Spacer()
            if viewModel.showControls, viewModel.isRecording || !viewModel.usesBroadcastMode {
                RecordingControlPanel(
                    isRecording: viewModel.isRecording,
                    glassesEnabled: viewModel.glassesEnabled,
                    glassesColor: viewModel.glassesService.frameColor,
                    drawingTool: viewModel.drawingTool,
                    onStop: { Task { await stopAndSave() } },
                    onToggleGlasses: viewModel.toggleGlasses,
                    onGlassesColor: viewModel.setGlassesColor,
                    onToolChange: { viewModel.drawingTool = $0 }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(GlassyTheme.spring, value: viewModel.showControls)
    }

    private var timerBadge: some View {
        VStack {
            if viewModel.showTimer, viewModel.isRecording {
                Text(viewModel.duration.formattedDuration)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .liquidGlass(cornerRadius: 10)
                    .padding(.top, 8)
            }
            Spacer()
        }
    }

    private func stopAndSave() async {
        if await viewModel.stopRecordingAndSave() != nil {
            coordinator.alertMessage = "Видео сохранено в «Фото»"
            coordinator.popToRoot()
        } else if case .failed(let message) = viewModel.setupPhase {
            coordinator.alertMessage = message
        }
    }
}

struct FaceCamView: View {
    var session: AVCaptureSession?
    var isSimulatorMode: Bool = false
    var isPlacementPreview: Bool = false
    var usesARKitFaceCam: Bool = false
    var arSession: ARSession?
    var arScene: SCNScene?
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
            } else if isPlacementPreview {
                FaceCamPlacementPreview(
                    glassesEnabled: glassesEnabled,
                    glassesColor: glassesColor
                )
            } else if usesARKitFaceCam, let arSession, let arScene {
                ARFaceCamPreviewView(arSession: arSession, scene: arScene)
            } else if let session {
                CameraPreviewView(session: session)
                if glassesEnabled {
                    SimulatorGlassesOverlay(color: glassesColor)
                        .scaleEffect(0.9)
                }
            } else {
                FaceCamPlacementPreview(
                    glassesEnabled: glassesEnabled,
                    glassesColor: glassesColor
                )
            }
        }
        .background(GlassyTheme.backgroundSecondary)
    }
}

private struct FaceCamPlacementPreview: View {
    let glassesEnabled: Bool
    let glassesColor: GlassesFrameColor

    var body: some View {
        ZStack {
            GlassyTheme.fillTertiary
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(GlassyTheme.labelTertiary)
            if glassesEnabled {
                SimulatorGlassesOverlay(color: glassesColor)
                    .scaleEffect(0.9)
            }
        }
    }
}

import ARKit
import SceneKit
import AVFoundation

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
