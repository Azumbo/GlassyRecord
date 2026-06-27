import SwiftUI
import PencilKit

struct RecordingControlPanel: View {
    let isRecording: Bool
    let glassesEnabled: Bool
    let glassesColor: GlassesFrameColor
    let drawingTool: DrawingTool
    let onStop: () -> Void
    let onToggleGlasses: () -> Void
    let onGlassesColor: (GlassesFrameColor) -> Void
    let onToolChange: (DrawingTool) -> Void

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 12) {
            drawingTools

            HStack(spacing: 20) {
                glassesControls

                Spacer()

                stopButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .liquidGlass(cornerRadius: 24)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .onAppear { pulse = true }
    }

    private var drawingTools: some View {
        HStack(spacing: 8) {
            ForEach(DrawingTool.allCases) { tool in
                Button {
                    onToolChange(tool)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: tool.systemImage)
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 36)
                        .background(drawingTool == tool ? Color.accentColor.opacity(0.25) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel(tool.displayName)
            }
        }
    }

    private var glassesControls: some View {
        HStack(spacing: 8) {
            Button(action: onToggleGlasses) {
                Image(systemName: glassesEnabled ? "eyeglasses" : "eyeglasses.slash")
                    .font(.title3)
                    .foregroundStyle(glassesEnabled ? .yellow : .secondary)
            }

            if glassesEnabled {
                ForEach(GlassesFrameColor.allCases) { color in
                    Circle()
                        .fill(color == .red ? GlassyTheme.glassesRed : GlassyTheme.glassesBlue)
                        .frame(width: 22, height: 22)
                        .overlay {
                            Circle()
                                .stroke(glassesColor == color ? Color.white : .clear, lineWidth: 2)
                        }
                        .onTapGesture { onGlassesColor(color) }
                }
            }
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            ZStack {
                Circle()
                    .fill(GlassyTheme.recordRed.opacity(0.25))
                    .frame(width: pulse ? 58 : 52, height: pulse ? 58 : 52)
                    .animation(GlassyTheme.pulse, value: pulse)

                RoundedRectangle(cornerRadius: 6)
                    .fill(GlassyTheme.recordRed)
                    .frame(width: 28, height: 28)
            }
        }
        .accessibilityLabel("Остановить запись")
    }
}

struct DrawingCanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let tool: DrawingTool

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = context.coordinator
        canvas.tool = makeTool()
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.tool = makeTool()
        if uiView.drawing != drawing {
            uiView.drawing = drawing
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing)
    }

    private func makeTool() -> PKTool {
        switch tool {
        case .pen:
            return PKInkingTool(.pen, color: .white, width: 3)
        case .marker:
            return PKInkingTool(.marker, color: .yellow, width: 12)
        case .neon:
            return PKInkingTool(.pen, color: UIColor(GlassyTheme.neonAccent), width: 5)
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding var drawing: PKDrawing
        init(drawing: Binding<PKDrawing>) { _drawing = drawing }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing = canvasView.drawing
        }
    }
}
