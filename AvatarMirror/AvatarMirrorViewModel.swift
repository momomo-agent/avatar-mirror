import SwiftUI
import ARKit
import AVFoundation
import AvatarKit

@MainActor
final class AvatarMirrorViewModel: NSObject, ObservableObject {
    @Published var trackingWorld = AvatarFaceTracking()
    @Published var trackingCamera = AvatarFaceTracking()
    @Published var currentAnimoji = "skull"
    @Published var debugStatus = "Starting..."
    
    private var arSession: ARSession?
    private var arDelegate: ARDelegateProxy?
    
    /// Last tracked poses — held when face is lost for smooth decay
    private var lastTrackedWorld: AvatarFaceTracking?
    private var lastTrackedCamera: AvatarFaceTracking?
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
            guard let faceAnchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first else {
                let empty = AvatarFaceTracking()
                DispatchQueue.main.async { self?.handleTrackingUpdate(world: empty, camera: empty) }
                return
            }
            // Produce both coordinate spaces for A/B comparison.
            // World: Euler delta from faceAnchor.transform, cameraSpace=0
            let world = AvatarFaceTracking(faceAnchor: faceAnchor, worldSpace: true)
            // Camera: inv(camera) × face, cameraSpace=1
            let camera = AvatarFaceTracking(
                faceAnchor: faceAnchor,
                cameraTransform: frame.camera.transform,
                withTranslation: true
            )
            DispatchQueue.main.async { self?.handleTrackingUpdate(world: world, camera: camera) }
        }
        session.delegate = proxy
        self.arSession = session
        self.arDelegate = proxy
        
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        debugStatus = "Tracking"
    }
    
    /// Blendshape EMA smoothing (Apple smooths before packing into the buffer)
    private let smoothingFactor: Float = 0.3  // lower = smoother, 0.3 ≈ Apple's feel
    private var smoothedBlendshapes: [String: Float] = [:]
    
    private func smoothTracking(_ tracking: AvatarFaceTracking) -> AvatarFaceTracking {
        var smoothed: [String: Float] = [:]
        for (key, value) in tracking.blendshapes {
            let prev = smoothedBlendshapes[key] ?? value
            let s = prev + smoothingFactor * (value - prev)
            smoothed[key] = s
            smoothedBlendshapes[key] = s
        }
        // Decay keys that disappeared
        for key in smoothedBlendshapes.keys where tracking.blendshapes[key] == nil {
            let decayed = smoothedBlendshapes[key]! * (1.0 - smoothingFactor)
            if decayed < 0.001 {
                smoothedBlendshapes.removeValue(forKey: key)
            } else {
                smoothedBlendshapes[key] = decayed
                smoothed[key] = decayed
            }
        }
        return AvatarFaceTracking(
            blendshapes: smoothed,
            rawQuaternion: tracking.rawQuaternion,
            headTranslation: tracking.headTranslation,
            coordinateSpace: tracking.coordinateSpace
        )
    }
    
    private func handleTrackingUpdate(world: AvatarFaceTracking, camera: AvatarFaceTracking) {
        if world.isTracking {
            stopDecay()
            lastTrackedWorld = world
            lastTrackedCamera = camera
            // Smooth blendshapes (shared — same ARKit source values)
            let smoothedWorld = smoothTracking(world)
            trackingWorld = AvatarFaceTracking(
                blendshapes: smoothedWorld.blendshapes,
                rawQuaternion: world.rawQuaternion,
                headTranslation: world.headTranslation,
                coordinateSpace: world.coordinateSpace
            )
            trackingCamera = AvatarFaceTracking(
                blendshapes: smoothedWorld.blendshapes,
                rawQuaternion: camera.rawQuaternion,
                headTranslation: camera.headTranslation,
                coordinateSpace: camera.coordinateSpace
            )
            debugStatus = "Tracking"
        } else {
            if faceLostTime == nil, lastTrackedWorld != nil {
                faceLostTime = CACurrentMediaTime()
                startDecay()
                debugStatus = "Face lost"
            }
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
        guard let lastWorld = lastTrackedWorld, let lastCamera = lastTrackedCamera,
              let lostTime = faceLostTime else {
            stopDecay()
            return
        }
        
        let elapsed = CACurrentMediaTime() - lostTime
        let progress = min(Float(elapsed / decayDuration), 1.0)
        let t = 1.0 - (1.0 - progress) * (1.0 - progress) * (1.0 - progress)
        
        if progress >= 1.0 {
            trackingWorld = AvatarFaceTracking()
            trackingCamera = AvatarFaceTracking()
            stopDecay()
            lastTrackedWorld = nil
            lastTrackedCamera = nil
            return
        }
        
        trackingWorld = decayTracking(lastWorld, t: t)
        trackingCamera = decayTracking(lastCamera, t: t)
    }
    
    private func decayTracking(_ lastPose: AvatarFaceTracking, t: Float) -> AvatarFaceTracking {
        var blendshapes: [String: Float] = [:]
        for (key, value) in lastPose.blendshapes {
            let decayed = value * (1.0 - t)
            if decayed > 0.001 { blendshapes[key] = decayed }
        }
        
        let lastQ = lastPose.rawQuaternion ?? lastPose.headRotation.quaternion
        let neutralQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let decayedQ = simd_slerp(lastQ, neutralQ, t)
        
        let decayedTranslation = lastPose.headTranslation * (1.0 - t)
        
        return AvatarFaceTracking(
            blendshapes: blendshapes,
            rawQuaternion: decayedQ,
            headTranslation: decayedTranslation,
            coordinateSpace: lastPose.coordinateSpace
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
