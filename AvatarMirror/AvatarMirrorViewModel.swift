import SwiftUI
import ARKit
import AVFoundation

@MainActor
final class AvatarMirrorViewModel: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isTracking = false
    @Published var currentAnimoji = "tiger"
    @Published var isMemoji = false
    @Published var debugStatus = "Starting..."
    
    let bridge = AvatarKitBridge()
    let memojiEditor = MemojiEditorBridge()
    
    private var arSession: ARSession?
    private var useBuiltInTracking = false
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
                    self.debugStatus = "Camera OK"
                } else {
                    self.debugStatus = "❌ Camera denied"
                }
            }
        }
    }
    
    /// Called by the view representable once AVTRecordView is created
    func onViewReady() {
        bridge.loadAnimoji(currentAnimoji)
        
        // Try built-in face tracking first
        bridge.startFaceTracking()
        debugStatus = "Face tracking started"
        
        // Also start our own ARSession as backup for manual blendshape application
        // If built-in tracking works, our delegate will still fire but applyFaceAnchor
        // will be a no-op since the avatar is already being driven
        startBackupARSession()
    }
    
    private func startBackupARSession() {
        let session = ARSession()
        session.delegate = self
        self.arSession = session
        
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        print("✅ Backup ARSession started")
    }
    
    func stop() {
        bridge.stopFaceTracking()
        arSession?.pause()
        arSession = nil
    }
    
    // MARK: - ARSessionDelegate (backup manual tracking)
    
    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let faceAnchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }
        Task { @MainActor in
            isTracking = faceAnchor.isTracked
            // Apply blendshapes manually — this works alongside or instead of built-in tracking
            bridge.applyFaceAnchor(faceAnchor)
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
            @unknown default: state = "Limited"
            }
        case .normal: state = "Normal"
        }
        Task { @MainActor in
            debugStatus = "Camera: \(state)"
        }
    }
    
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            debugStatus = "❌ \(error.localizedDescription)"
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
            let avatarSel = NSSelectorFromString("avatar")
            if record.responds(to: avatarSel),
               let avatar = record.perform(avatarSel)?.takeUnretainedValue() as? NSObject {
                self.bridge.avtView?.setValue(avatar, forKeyPath: "avatar")
            }
        }
    }
}
