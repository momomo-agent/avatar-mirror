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
    
    /// Last tracked pose — held when face is lost for smooth decay
    private var lastTrackedPose: AvatarFaceTracking?
    private var faceLostTime: CFTimeInterval?
    private var decayLink: CADisplayLink?
    
    /// Duration to smoothly decay from last pose to neutral when face is lost
    private let decayDuration: TimeInterval = 0.5
    
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
                self?.handleTrackingUpdate(t)
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
    
    private func handleTrackingUpdate(_ newTracking: AvatarFaceTracking) {
        if newTracking.isTracking {
            // Face found — use directly, cancel any decay
            stopDecay()
            lastTrackedPose = newTracking
            tracking = newTracking
            debugStatus = "Tracking"
        } else {
            // Face lost — start smooth decay from last pose
            if faceLostTime == nil, lastTrackedPose != nil {
                faceLostTime = CACurrentMediaTime()
                startDecay()
                debugStatus = "Face lost"
            }
            // Keep passing the ARFrame for the avatar to maintain position
            // but don't update tracking (decay handles it)
        }
    }
    
    private func startDecay() {
        guard decayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(decayTick))
        link.add(to: .main, forMode: .common)
        decayLink = link
    }
    
    private func stopDecay() {
        decayLink?.invalidate()
        decayLink = nil
        faceLostTime = nil
    }
    
    @objc private func decayTick() {
        guard let lastPose = lastTrackedPose, let lostTime = faceLostTime else {
            stopDecay()
            return
        }
        
        let elapsed = CACurrentMediaTime() - lostTime
        let progress = min(Float(elapsed / decayDuration), 1.0)
        
        // Ease out cubic
        let t = 1.0 - (1.0 - progress) * (1.0 - progress) * (1.0 - progress)
        
        if progress >= 1.0 {
            // Fully decayed to neutral
            tracking = AvatarFaceTracking(isTracking: true)
            stopDecay()
            lastTrackedPose = nil
            return
        }
        
        // Interpolate from last pose to neutral
        var blendshapes: [String: Float] = [:]
        for (key, value) in lastPose.blendshapes {
            let decayed = value * (1.0 - t)
            if decayed > 0.001 { blendshapes[key] = decayed }
        }
        
        let neutralQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let rotation = simd_slerp(lastPose.headRotation, neutralQ, t)
        
        tracking = AvatarFaceTracking(
            blendshapes: blendshapes,
            headRotation: rotation,
            isTracking: true
        )
    }
    
    func stop() {
        stopDecay()
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
