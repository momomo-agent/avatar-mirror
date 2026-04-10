import SwiftUI
import ARKit
import AVFoundation
import AvatarKit

@MainActor
final class AvatarMirrorViewModel: NSObject, ObservableObject {
    @Published var tracking = AvatarFaceTracking()
    @Published var currentAnimoji = "skull"
    @Published var debugStatus = "Starting..."
    
    private var arSession: ARSession?
    private var arDelegate: ARDelegateProxy?
    
    func start() {
        guard ARFaceTrackingConfiguration.isSupported else {
            debugStatus = "❌ Face tracking not supported"
            return
        }
        
        debugStatus = "Requesting camera..."
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self, granted else {
                    self?.debugStatus = "❌ Camera denied"
                    return
                }
                self.startTracking()
            }
        }
    }
    
    private func startTracking() {
        let session = ARSession()
        let proxy = ARDelegateProxy { [weak self] frame in
            let t = AvatarFaceTracking(arFrame: frame)
            DispatchQueue.main.async {
                self?.tracking = t
            }
        }
        session.delegate = proxy
        self.arSession = session
        self.arDelegate = proxy
        
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        debugStatus = "Tracking"
    }
    
    func stop() {
        arSession?.pause()
        arSession = nil
        arDelegate = nil
    }
}

// MARK: - ARSession Delegate Proxy

final class ARDelegateProxy: NSObject, ARSessionDelegate, @unchecked Sendable {
    private let onFrame: (ARFrame) -> Void
    
    init(onFrame: @escaping (ARFrame) -> Void) {
        self.onFrame = onFrame
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrame(frame)
    }
}
