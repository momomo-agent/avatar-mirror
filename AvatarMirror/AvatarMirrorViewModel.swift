import SwiftUI
import ARKit
import AVFoundation
import HumanSenseKit

@MainActor
final class AvatarMirrorViewModel: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isTracking = false
    @Published var currentAnimoji = "tiger"
    @Published var isMemoji = false
    @Published var debugStatus = "Starting..."
    @Published var useHumanSenseKit = true
    
    let bridge = AvatarKitBridge()
    let memojiEditor = MemojiEditorBridge()
    
    // HumanSenseKit for external tracking
    private var kit: HumanSenseKit?
    
    // Direct ARSession (used when HumanSenseKit doesn't expose ARFrame)
    private var arSession: ARSession?
    
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
                self.debugStatus = granted ? "Camera OK" : "❌ Camera denied"
            }
        }
    }
    
    func onViewReady() {
        bridge.loadAnimoji(currentAnimoji)
        
        if useHumanSenseKit {
            startHSKTracking()
        } else {
            bridge.startBuiltInTracking()
            debugStatus = "Built-in tracking"
        }
    }
    
    // MARK: - HumanSenseKit Tracking
    
    private func startHSKTracking() {
        bridge.startExternalTracking()
        
        // We need the raw ARFrame to pass to AvatarKit's trackingInfoWithARFrame:
        // HumanSenseKit uses ARSession internally — we'll run our own ARSession
        // and feed frames to both HumanSenseKit state and AvatarKit
        let session = ARSession()
        session.delegate = self
        self.arSession = session
        
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        debugStatus = "HSK tracking (ARSession)"
        print("✅ ARSession started for HSK + AvatarKit")
    }
    
    func stop() {
        arSession?.pause()
        arSession = nil
        kit?.stop()
        kit = nil
        bridge.stopTracking()
    }
    
    // MARK: - ARSessionDelegate
    
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Pass the full ARFrame to AvatarKit — this is the key!
        // trackingInfoWithARFrame: extracts face anchor + transform + blendshapes correctly
        Task { @MainActor in
            let hasFace = frame.anchors.contains(where: { $0 is ARFaceAnchor })
            isTracking = hasFace
            
            if hasFace {
                bridge.applyARFrame(frame)
            }
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
        case .normal: state = "Tracking"
        }
        Task { @MainActor in
            debugStatus = "HSK | \(state)"
        }
    }
    
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            debugStatus = "❌ \(error.localizedDescription)"
        }
    }
    
    // MARK: - Toggle
    
    func toggleTrackingMode() {
        stop()
        useHumanSenseKit.toggle()
        onViewReady()
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
