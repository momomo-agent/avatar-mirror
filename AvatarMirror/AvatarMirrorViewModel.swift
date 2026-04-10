import SwiftUI
import ARKit
import AVFoundation
import HumanSenseKit

@MainActor
final class AvatarMirrorViewModel: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isTracking = false
    @Published var currentAnimoji = "tiger"
    @Published var isMemoji = false
    @Published var currentPose = "person_waving"
    @Published var debugStatus = "Starting..."
    
    let bridge = AvatarKitBridge()
    let memojiEditor = MemojiEditorBridge()
    
    // Direct ARSession as primary — HumanSenseKit as optional enrichment
    private var arSession: ARSession?
    private var kit: HumanSenseKit?
    private var savedMemojiRecord: NSObject?
    
    func start() {
        guard ARFaceTrackingConfiguration.isSupported else {
            debugStatus = "❌ Face tracking not supported"
            return
        }
        
        debugStatus = "Requesting camera..."
        
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.debugStatus = "Camera OK, starting AR..."
                    self.startDirectARSession()
                } else {
                    self.debugStatus = "❌ Camera denied"
                }
            }
        }
    }
    
    private func startDirectARSession() {
        // Use our own ARSession directly — don't rely on HumanSenseKit's internal session
        let session = ARSession()
        session.delegate = self
        self.arSession = session
        
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        debugStatus = "ARSession running (direct)"
        print("✅ Direct ARSession started with ARFaceTrackingConfiguration")
    }
    
    func stop() {
        arSession?.pause()
        arSession = nil
    }
    
    // MARK: - ARSessionDelegate (direct)
    
    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let faceAnchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }
        Task { @MainActor in
            let wasTracking = isTracking
            isTracking = faceAnchor.isTracked
            
            if isTracking != wasTracking {
                debugStatus = isTracking ? "✅ Face detected!" : "Face lost"
                print("🔄 Tracking: \(wasTracking) → \(isTracking)")
            }
            
            bridge.applyFaceAnchor(faceAnchor)
        }
    }
    
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        print("❌ ARSession error: \(error)")
        Task { @MainActor in
            debugStatus = "❌ AR error: \(error.localizedDescription)"
        }
    }
    
    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state: String
        switch camera.trackingState {
        case .notAvailable: state = "Not available"
        case .limited(let reason):
            switch reason {
            case .initializing: state = "Initializing..."
            case .excessiveMotion: state = "Too much motion"
            case .insufficientFeatures: state = "Insufficient features"
            case .relocalizing: state = "Relocalizing"
            @unknown default: state = "Limited (unknown)"
            }
        case .normal: state = "Normal"
        }
        print("📷 Camera tracking state: \(state)")
        Task { @MainActor in
            debugStatus = "Camera: \(state)"
        }
    }
    
    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        print("⚠️ ARSession interrupted")
        Task { @MainActor in
            debugStatus = "⚠️ AR interrupted"
        }
    }
    
    // MARK: - Switching
    
    func switchToAnimoji(_ name: String) {
        currentAnimoji = name
        isMemoji = false
        bridge.loadAnimoji(name)
    }
    
    func switchToMemoji() {
        isMemoji = true
        bridge.loadMemoji()
    }
    
    func switchPose(_ pose: String) {
        currentPose = pose
        bridge.applyBodySticker(pose)
    }
    
    // MARK: - Memoji Creator
    
    func presentMemojiCreator() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }
        
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        
        memojiEditor.presentCreator(from: topVC) { [weak self] record in
            guard let self, let record else { return }
            self.savedMemojiRecord = record
            self.isMemoji = true
            self.loadSavedMemoji(record)
        }
    }
    
    private func loadSavedMemoji(_ record: NSObject) {
        let avatarSel = NSSelectorFromString("avatar")
        if record.responds(to: avatarSel),
           let avatar = record.perform(avatarSel)?.takeUnretainedValue() as? NSObject {
            if let avtView = bridge.avtView {
                avtView.perform(NSSelectorFromString("setAvatar:"), with: avatar)
                print("✅ Loaded saved memoji")
            }
        }
    }
}
