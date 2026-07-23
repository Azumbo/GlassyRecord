import SwiftUI
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
    @State private var showDemoBrowser = false

    private var pipPreviewSize: CGSize {
        CGSize(width: GlassyTheme.pipPreviewBaseWidth, height: GlassyTheme.pipPreviewBaseHeight)
    }

    init(settings: AppSettings) {
        _viewModel = StateObject(wrappedValue: RecordingViewModel(settings: settings))
    }

    var body: some View {
        ZStack {
            GlassyTheme.backgroundSecondary.ignoresSafeArea()

            if showFaceCamPlacement {
                faceCamOverlay
            }

            touchIndicatorsLayer

            controlsOverlay
            timerBadge
            broadcastBanner

            if SimulatorSupport.isRunning {
                VStack {
                    SimulatorBanner()
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            if viewModel.showBroadcastSetupCard {
                broadcastSetupOverlay
            }

            if showPiPInlinePreview {
                pipInlineOverlay
                    .zIndex(10)
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

            recordingExitButton
        }
        // DragGesture(minimumDistance: 0) на всём экране ломает тап по RPSystemBroadcastPickerView.
        .touchTrailGesture(touchTrailGesture, enabled: viewModel.isRecording)
        .navigationBarHidden(true)
        .statusBarHidden(!viewModel.showTimer)
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.cleanup() }
        .onChange(of: settingsStore.settings.faceCamScale) { scale in
            // Пресеты с экрана записи вызывают selectFaceCamSize сами (с restart).
            // Здесь только подтягиваем внешние изменения настроек без лишнего restart.
            viewModel.applyFaceCamScale(scale, forceRestart: false)
        }
        .onChange(of: viewModel.completedSession?.id) { _ in
            guard let session = viewModel.completedSession else { return }
            coordinator.showEditor(for: session)
            viewModel.clearCompletedSession()
        }
        .onChange(of: scenePhase) { phase in
            viewModel.handleScenePhase(phase)
            if phase == .active {
                viewModel.applyFaceCamScaleFromSettings()
                viewModel.refreshBroadcastState()
            }
        }
        .onChange(of: viewModel.lastError?.localizedDescription) { message in
            guard !SimulatorSupport.isRunning, let message else { return }
            coordinator.alertMessage = message
        }
        .onChange(of: coordinator.alertMessage) { message in
            if message == nil, viewModel.isFailed {
                viewModel.dismissFailure()
            }
        }
        .onChange(of: viewModel.isRecording) { isRecording in
            guard isRecording, coordinator.openDemoBrowserWhenRecordingStarts else { return }
            coordinator.openDemoBrowserWhenRecordingStarts = false
            showDemoBrowser = true
        }
        .fullScreenCover(isPresented: $showDemoBrowser) {
            DemoBrowserView {
                showDemoBrowser = false
            }
            .environmentObject(settingsStore)
        }
    }

    private var touchTrailGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                viewModel.addTouchIndicator(at: value.location)
                viewModel.userInteraction()
            }
    }

    private var showPiPInlinePreview: Bool {
        viewModel.usesBroadcastMode && (viewModel.isAwaitingBroadcast || viewModel.isRecording)
    }

    private var showFaceCamPlacement: Bool {
        !viewModel.usesBroadcastMode
    }

    private var recordingExitButton: some View {
        VStack {
            HStack {
                Button {
                    viewModel.exitToHome { coordinator.popToRoot() }
                } label: {
                    Label(L10n.t("nav.back"), systemImage: "chevron.left")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .liquidGlass(cornerRadius: 12)
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)
                .padding(.top, 8)
                Spacer()
            }
            Spacer()
                .allowsHitTesting(false)
        }
        .zIndex(20)
    }

    private var pipInlineOverlay: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    if let previewLayer = viewModel.pipProcessedPreviewLayer {
                        PiPProcessedPreviewView(displayLayer: previewLayer)
                            .frame(
                                width: pipPreviewSize.width,
                                height: pipPreviewSize.height
                            )
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                            }
                    } else if viewModel.isAwaitingBroadcast || viewModel.isRecording {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(GlassyTheme.fillTertiary)
                            .frame(width: pipPreviewSize.width, height: pipPreviewSize.height)
                            .overlay { ProgressView() }
                    }

                    if viewModel.isAwaitingBroadcast || viewModel.isRecording {
                        pipSizePresetControl
                            .frame(width: 200)
                    }
                }
                .padding(.top, 12)
                .padding(.trailing, 12)
            }
            Spacer()
                .allowsHitTesting(false)
        }
        .allowsHitTesting(true)
    }

    private var pipSizePresetControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.t("pip.size"), systemImage: "person.crop.rectangle")
                .font(.caption2.weight(.medium))

            Text(L10n.t("pip.size.hint"))
                .font(.caption2)
                .foregroundStyle(GlassyTheme.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 4)], spacing: 4) {
                ForEach(PiPFaceSizePreset.allCases) { preset in
                    Button {
                        viewModel.selectFaceCamSize(preset)
                        settingsStore.update { $0.applyPipFaceSizePreset(preset) }
                        viewModel.userInteraction()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(preset.shortLabel)
                            .font(.caption2.weight(.medium))
                            .frame(minWidth: 40, minHeight: 32)
                    }
                    .buttonStyle(PipPresetButtonStyle(isSelected: viewModel.faceCamSizePreset == preset))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .liquidGlass(cornerRadius: 10)
    }

    private var preparingOverlay: some View {
        statusOverlay(title: L10n.t("recording.preparing"), subtitle: L10n.t("recording.preparing_sub"))
    }

    private var savingOverlay: some View {
        statusOverlay(title: L10n.t("recording.saving"), subtitle: L10n.t("recording.saving_sub"))
    }

    private var broadcastSetupOverlay: some View {
        VStack {
            Spacer()
                .allowsHitTesting(false)
            VStack(spacing: 16) {
                Text(L10n.t("recording.pip_title"))
                    .font(.headline)
                Text(L10n.t("recording.pip_preview_hint"))
                    .font(.subheadline)
                    .foregroundStyle(GlassyTheme.labelSecondary)
                    .multilineTextAlignment(.center)

                Text(L10n.t("recording.pip_system_hint"))
                    .font(.caption)
                    .foregroundStyle(GlassyTheme.labelSecondary)
                    .multilineTextAlignment(.center)

                Text(L10n.t("recording.demo_hint"))
                    .font(.caption)
                    .foregroundStyle(GlassyTheme.labelSecondary)
                    .multilineTextAlignment(.center)

                Button {
                    viewModel.prepareBroadcastConfig()
                    viewModel.userInteraction()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Label("Готов к записи", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                VStack(spacing: 6) {
                    Text("Дальше начните запись из Пункта управления iOS:")
                    Text("Зажмите кнопку записи экрана → выберите GlassyRecord → Start Broadcast.")
                }
                .font(.caption)
                .foregroundStyle(GlassyTheme.labelSecondary)
                .multilineTextAlignment(.center)
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
        .allowsHitTesting(true)
    }

    private var broadcastBanner: some View {
        VStack {
            if viewModel.usesBroadcastMode, viewModel.isPiPActive, !viewModel.isRecording {
                Text(L10n.t("recording.banner.pip_ready"))
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .liquidGlass(cornerRadius: 12)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            } else if viewModel.usesBroadcastMode, viewModel.isRecording {
                Text(L10n.t("recording.banner.recording"))
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .liquidGlass(cornerRadius: 12)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            Spacer()
                .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }

    private var failedOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(GlassyTheme.warning)
                Text(L10n.t("recording.failed_title"))
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
                    Button(L10n.t("nav.back")) {
                        viewModel.dismissFailure()
                        viewModel.exitToHome { coordinator.popToRoot() }
                    }
                        .buttonStyle(.bordered)
                    Button(L10n.t("common.retry")) {
                        viewModel.dismissFailure()
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
                mirrored: settingsStore.settings.faceCamMirrored,
                onPreviewLayerReady: { layer in
                    viewModel.cameraService.bindPreviewLayer(layer)
                }
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
        ZStack(alignment: .bottom) {
            if viewModel.showControls, viewModel.isRecording || !viewModel.usesBroadcastMode {
                RecordingControlPanel(
                    isRecording: viewModel.isRecording,
                    glassesEnabled: viewModel.glassesEnabled,
                    glassesColor: viewModel.glassesService.frameColor,
                    onStop: { Task { await viewModel.stopRecording() } },
                    onToggleGlasses: viewModel.toggleGlasses,
                    onGlassesColor: viewModel.setGlassesColor,
                    onOpenDemo: viewModel.isRecording ? { showDemoBrowser = true } : nil,
                    onAppLaunchFailed: { message in
                        coordinator.alertMessage = message
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(viewModel.showControls && (viewModel.isRecording || !viewModel.usesBroadcastMode))
        .animation(GlassyTheme.spring, value: viewModel.showControls)
    }

    private var timerBadge: some View {
        ZStack(alignment: .top) {
            if viewModel.showTimer, viewModel.isRecording {
                Text(viewModel.duration.formattedDuration)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .liquidGlass(cornerRadius: 10)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
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
    var onPreviewLayerReady: ((AVCaptureVideoPreviewLayer) -> Void)? = nil

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
                CameraPreviewView(
                    session: session,
                    mirrored: mirrored,
                    onPreviewLayerReady: onPreviewLayerReady
                )
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

private extension View {
    @ViewBuilder
    func touchTrailGesture<G: Gesture>(_ gesture: G, enabled: Bool) -> some View {
        if enabled {
            simultaneousGesture(gesture)
        } else {
            self
        }
    }
}
