import ARKit
import SceneKit
import SwiftUI

/// Превью Face Cam через ARKit — без параллельного AVCaptureSession.
struct ARFaceCamPreviewView: UIViewRepresentable {
    let arSession: ARSession
    let scene: SCNScene

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = arSession
        view.scene = scene
        view.automaticallyUpdatesLighting = true
        view.rendersCameraGrain = false
        view.scene.rootNode.childNodes.forEach { $0.isHidden = false }
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.session !== arSession {
            uiView.session = arSession
        }
        if uiView.scene !== scene {
            uiView.scene = scene
        }
    }
}
