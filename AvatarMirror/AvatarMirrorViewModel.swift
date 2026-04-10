import SwiftUI
import ARKit
import AVFoundation

@MainActor
final class AvatarMirrorViewModel: NSObject, ObservableObject {
    @Published var isTracking = false
    @Published var currentAnimoji = "tiger"
    @Published var isMemoji = false
    @Published var debugStatus = "Starting..."
    @Published var useHumanSenseKit = true
    
    let bridge = AvatarKitBridge()
    let memojiEditor = MemojiEditorBridge()
    
    private var arSession: ARSession?
    private var arDelegate: ARDelegateProxy?
    private var savedMemojiRecord: NSObject?
    
    func start() {
        guard ARFaceTrackingConfiguration.isSupported else {
            debugStatus = "❌ Face tracking not supported"
            return
        }
        
        debugStatus = "Requesting camera..."
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                self?.debugStatus = granted ? "Camera OK" : "❌ Camera denied"
            }
        }
    }
    
    func onViewReady() {
        bridge.loadAnimoji(currentAnimoji)
        
        if useHumanSenseKit {
            startExternalTracking()
        } else {
            bridge.startBuiltInTracking()
            debugStatus = "Built-in tracking"
        }
    }
    
    // MARK: - External Tracking (our own ARSession)
    
    private func startExternalTracking() {
        bridge.startExternalTracking()
        
        let session = ARSession()
        let proxy = ARDelegateProxy { [weak self] frame in
            self?.handleARFrame(frame)
        }
        session.delegate = proxy
        self.arSession = session
        self.arDelegate = proxy
        
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        debugStatus = "HSK tracking"
        print("✅ External ARSession started")
    }
    
    /// Called from ARDelegateProxy on ARSession's queue
    nonisolated func handleARFrame(_ frame: ARFrame) {
        let hasFace = frame.anchors.contains(where: { $0 is ARFaceAnchor })
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isTracking = hasFace
            if hasFace {
                self.bridge.applyARFrame(frame)
            }
        }
    }
    
    func stop() {
        arSession?.pause()
        arSession = nil
        arDelegate = nil
        bridge.stopTracking()
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
        
        // Pause our ARSession to avoid VFXWorld conflicts with the editor's own session
        arSession?.pause()
        
        memojiEditor.presentCreator(from: topVC) { [weak self] record in
            guard let self else {
                return
            }
            
            // Resume our ARSession
            if let session = self.arSession {
                let config = ARFaceTrackingConfiguration()
                config.isWorldTrackingEnabled = false
                session.run(config, options: [.resetTracking, .removeExistingAnchors])
            }
            
            guard let record else { return }
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

// MARK: - ARSession Delegate Proxy (non-isolated)

final class ARDelegateProxy: NSObject, ARSessionDelegate, @unchecked Sendable {
    private let onFrame: (ARFrame) -> Void
    
    init(onFrame: @escaping (ARFrame) -> Void) {
        self.onFrame = onFrame
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrame(frame)
    }
    
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state: String
        switch camera.trackingState {
        case .notAvailable: state = "Not available"
        case .limited(let reason):
            switch reason {
            case .initializing: state = "Initializing..."
            case .excessiveMotion: state = "Motion"
            case .insufficientFeatures: state = "Features"
            case .relocalizing: state = "Relocalizing"
            @unknown default: state = "Limited"
            }
        case .normal: state = "Tracking"
        }
        print("📷 Camera: \(state)")
    }
}
