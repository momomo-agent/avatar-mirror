import SwiftUI
import ARKit
import AVFoundation
import AvatarKit
import simd

@MainActor
final class AvatarMirrorViewModel: NSObject, ObservableObject {
    @Published var trackingWorld = AvatarFaceTracking()
    @Published var trackingCamera = AvatarFaceTracking()
    @Published var trackingAppleAR = AvatarFaceTracking()
    @Published var currentAnimoji = "skull"
    @Published var debugStatus = "Starting..."
    var debugFrameCount = 0
    
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
    
    /// Debug frame counter for periodic logging
    private var debugARFrameCount = 0
    
    private func startTracking() {
        let session = ARSession()
        let proxy = ARDelegateProxy { [weak self] frame in
            guard let faceAnchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first else {
                let empty = AvatarFaceTracking()
                DispatchQueue.main.async { self?.handleTrackingUpdate(world: empty, camera: empty, appleAR: empty) }
                return
            }
            
            // === DEBUG POINT A: Raw ARKit values ===
            if let self {
                self.debugARFrameCount += 1
                if self.debugARFrameCount % 60 == 1 {
                    let ft = faceAnchor.transform
                    let ct = frame.camera.transform
                    let inv_ct = ct.inverse
                    let result = inv_ct * ft
                    
                    // Face transform (world space)
                    let fq = simd_quatf(ft)
                    print("[A-RAW] face.pos=(\(String(format: "%.4f,%.4f,%.4f", ft.columns.3.x, ft.columns.3.y, ft.columns.3.z)))")
                    print("[A-RAW] face.quat=(\(String(format: "%.4f,%.4f,%.4f,%.4f", fq.imag.x, fq.imag.y, fq.imag.z, fq.real)))")
                    
                    // Camera transform (world space)
                    let cq = simd_quatf(ct)
                    print("[A-RAW] cam.pos=(\(String(format: "%.4f,%.4f,%.4f", ct.columns.3.x, ct.columns.3.y, ct.columns.3.z)))")
                    print("[A-RAW] cam.quat=(\(String(format: "%.4f,%.4f,%.4f,%.4f", cq.imag.x, cq.imag.y, cq.imag.z, cq.real)))")
                    
                    // inv(cam) * face result
                    let rq = simd_quatf(result)
                    print("[A-RAW] inv*face.pos=(\(String(format: "%.4f,%.4f,%.4f", result.columns.3.x, result.columns.3.y, result.columns.3.z)))")
                    print("[A-RAW] inv*face.quat=(\(String(format: "%.4f,%.4f,%.4f,%.4f", rq.imag.x, rq.imag.y, rq.imag.z, rq.real)))")
                    print("[A-RAW] ---")
                }
            }
            
            // === DEBUG: Log displayCenterTransform and face transform ===
            if self?.debugFrameCount ?? 0 < 5 {
                self?.debugFrameCount = (self?.debugFrameCount ?? 0) + 1
                
                // displayCenterTransform is private on ARCamera
                let camera = frame.camera as AnyObject
                let dctSel = NSSelectorFromString("displayCenterTransform")
                if camera.responds(to: dctSel) {
                    // Returns simd_float4x4 (64 bytes) — use NSInvocation or just note it exists
                    print("[DCT] displayCenterTransform exists on ARCamera")
                } else {
                    print("[DCT] displayCenterTransform NOT found on ARCamera")
                }
                
                let ft = faceAnchor.transform
                let fq = simd_quatf(ft)
                print("[DCT] face.t=(\(String(format: "%.4f,%.4f,%.4f", ft.columns.3.x, ft.columns.3.y, ft.columns.3.z)))")
                print("[DCT] face.q=(\(String(format: "%.4f,%.4f,%.4f,%.4f", fq.imag.x, fq.imag.y, fq.imag.z, fq.real)))")
                
                // Log camera transform for reference
                let ct = frame.camera.transform
                let cq = simd_quatf(ct)
                print("[DCT] cam.t=(\(String(format: "%.4f,%.4f,%.4f", ct.columns.3.x, ct.columns.3.y, ct.columns.3.z)))")
                print("[DCT] cam.q=(\(String(format: "%.4f,%.4f,%.4f,%.4f", cq.imag.x, cq.imag.y, cq.imag.z, cq.real)))")
                
                // Log what we're putting in the buffer
                print("[DCT] ourQ=(\(String(format: "%.4f,%.4f,%.4f,%.4f", fq.imag.x, fq.imag.y, fq.imag.z, fq.real)))")
                print("[DCT] ourT=(\(String(format: "%.4f,%.4f,%.4f", ft.columns.3.x * 50, ft.columns.3.y * 20, ft.columns.3.z * 100)))")
                print("[DCT] ---")
            }
            
            // World mode: bit-exact with Apple's _AVTTrackingDataFromARFrame
            let world = AvatarFaceTracking(faceAnchor: faceAnchor)
            
            // Camera mode: inverse(camera) × face, cameraSpace=1
            // Sensor is landscape-left; apply -90° Z rotation to align with portrait display.
            // This is what Apple's displayCenterTransform does internally.
            let portraitCorrection = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)))
            let correctedCamera = frame.camera.transform * portraitCorrection
            let invCam = simd_inverse(correctedCamera)
            let relativeTransform = invCam * faceAnchor.transform
            let cameraQ = simd_quatf(relativeTransform)
            let cameraT = SIMD3<Float>(
                relativeTransform.columns.3.x * 50,
                relativeTransform.columns.3.y * 20,
                relativeTransform.columns.3.z * 100
            )
            var cameraTracking = AvatarFaceTracking(faceAnchor: faceAnchor)
            cameraTracking.rawQuaternion = cameraQ
            cameraTracking.headTranslation = cameraT
            cameraTracking.coordinateSpace = .cameraRotationOnly
            let camera = cameraTracking
            
            // Apple AR mode (constrainHeadPose=0):
            // Apple does: scaledFace × camera.transform
            // Scale: Apple uses 100000 but that pushes avatar out of scene.
            // Use same scale as world mode for now; the key difference is
            // the quaternion comes from face×camera instead of just face.
            var scaledFace = faceAnchor.transform
            scaledFace.columns.3 = SIMD4<Float>(
                scaledFace.columns.3.x * 50,
                scaledFace.columns.3.y * 20,
                scaledFace.columns.3.z * 100,
                scaledFace.columns.3.w
            )
            let arResult = scaledFace * frame.camera.transform
            let arQ = simd_quatf(arResult)
            let arT = SIMD3<Float>(arResult.columns.3.x, arResult.columns.3.y, arResult.columns.3.z)
            var appleARTracking = AvatarFaceTracking(faceAnchor: faceAnchor)
            appleARTracking.rawQuaternion = arQ
            appleARTracking.headTranslation = arT
            appleARTracking.coordinateSpace = .cameraRotationOnly
            let appleAR = appleARTracking
            
            DispatchQueue.main.async { self?.handleTrackingUpdate(world: world, camera: camera, appleAR: appleAR) }
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
    
    private func handleTrackingUpdate(world: AvatarFaceTracking, camera: AvatarFaceTracking, appleAR: AvatarFaceTracking) {
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
            trackingAppleAR = AvatarFaceTracking(
                blendshapes: smoothedWorld.blendshapes,
                rawQuaternion: appleAR.rawQuaternion,
                headTranslation: appleAR.headTranslation,
                coordinateSpace: appleAR.coordinateSpace
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
