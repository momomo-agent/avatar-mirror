import AVFoundation
import Accelerate
import AvatarKit

@MainActor
final class AudioDrivenAnimator: ObservableObject {
    @Published var tracking = AvatarFaceTracking()
    @Published var isActive = false
    @Published var status = "Idle"
    
    /// Head rotation driven by audio energy
    @Published var headRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    
    /// Direct callback for 60fps tracking updates (bypasses SwiftUI).
    var onTrackingUpdate: ((AvatarFaceTracking) -> Void)?
    
    private var audioEngine: AVAudioEngine?
    private var currentFileURL: URL?
    private var currentFileIsSecurityScoped = false
    private var audioPlayer: AVAudioPlayerNode?
    private var displayLink: CADisplayLink?
    
    // Audio analysis state
    private var currentLevel: Float = 0
    private var smoothedLevel: Float = 0
    private var peakLevel: Float = 0.001
    
    // Animation state
    private var time: Double = 0
    private var blinkTimer: Double = 0
    private var nextBlinkTime: Double = 2.0
    private var isBlinking = false
    private var blinkPhase: Double = 0
    
    // Head micro-movement state
    private var headNodPhase: Double = 0
    private var headSwayPhase: Double = 0
    private var headTiltPhase: Double = 0
    
    // Smoothing for natural movement
    private var smoothedJaw: Float = 0
    private var smoothedMouth: Float = 0
    private var smoothedBrow: Float = 0
    private var smoothedSquint: Float = 0
    
    func startWithMicrophone() {
        stop()
        
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let level = self?.rmsLevel(buffer: buffer) ?? 0
            Task { @MainActor [weak self] in
                self?.currentLevel = level
            }
        }
        
        do {
            try engine.start()
            self.audioEngine = engine
            isActive = true
            status = "Mic active"
            startDisplayLink()
        } catch {
            status = "Mic error: \(error.localizedDescription)"
        }
    }
    
    func startWithAudioFile(_ url: URL) {
        stop()
        
        // startAccessingSecurityScopedResource is needed for file-picker URLs
        // but returns false for bundle resources — that's fine, just proceed
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            status = "Cannot read audio file"
            if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
            return
        }
        
        self.currentFileURL = url
        self.currentFileIsSecurityScoped = isSecurityScoped
        
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        
        let format = audioFile.processingFormat
        engine.connect(player, to: engine.mainMixerNode, format: format)
        
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: engine.mainMixerNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            let level = self?.rmsLevel(buffer: buffer) ?? 0
            Task { @MainActor [weak self] in
                self?.currentLevel = level
            }
        }
        
        do {
            try engine.start()
            player.scheduleFile(audioFile, at: nil) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.status = "Playback finished"
                    self?.isActive = false
                }
            }
            player.play()
            self.audioEngine = engine
            self.audioPlayer = player
            isActive = true
            status = "Playing: \(url.lastPathComponent)"
            startDisplayLink()
        } catch {
            status = "Playback error: \(error.localizedDescription)"
            if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
        }
    }
    
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        audioPlayer?.stop()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.mainMixerNode.removeTap(onBus: 0)
        audioEngine = nil
        audioPlayer = nil
        if currentFileIsSecurityScoped {
            currentFileURL?.stopAccessingSecurityScopedResource()
        }
        currentFileURL = nil
        currentFileIsSecurityScoped = false
        isActive = false
        currentLevel = 0
        smoothedLevel = 0
        time = 0
        blinkTimer = 0
        smoothedJaw = 0
        smoothedMouth = 0
        smoothedBrow = 0
        smoothedSquint = 0
        headRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }
    
    // MARK: - Display Link
    
    private func startDisplayLink() {
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] dt in
            Task { @MainActor [weak self] in
                self?.updateAnimation(dt: dt)
            }
        }, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }
    
    // MARK: - Animation Update (60fps)
    
    private func updateAnimation(dt: Double) {
        time += dt
        
        // Smooth the audio level
        let alpha: Float = 0.3
        smoothedLevel = smoothedLevel * (1 - alpha) + currentLevel * alpha
        
        // Adaptive peak tracking
        if smoothedLevel > peakLevel {
            peakLevel = smoothedLevel
        } else {
            peakLevel = peakLevel * 0.999 + 0.001 // slow decay
        }
        
        // Normalized level (0-1)
        let normalizedLevel = min(smoothedLevel / max(peakLevel, 0.001), 1.0)
        
        // === MOUTH ===
        let targetJaw = normalizedLevel * 0.85
        let targetMouth = normalizedLevel * 0.4
        smoothedJaw = smoothedJaw * 0.7 + targetJaw * 0.3
        smoothedMouth = smoothedMouth * 0.7 + targetMouth * 0.3
        
        let mouthSmile = normalizedLevel > 0.3 ? (normalizedLevel - 0.3) * 0.3 : 0
        let mouthStretch = smoothedJaw * 0.2
        
        // === BROWS ===
        let targetBrow = normalizedLevel > 0.4 ? (normalizedLevel - 0.4) * 0.5 : 0
        smoothedBrow = smoothedBrow * 0.85 + targetBrow * 0.15
        
        // === EYES ===
        blinkTimer += dt
        var blinkValue: Float = 0
        
        if isBlinking {
            blinkPhase += dt * 8.0
            if blinkPhase >= .pi {
                isBlinking = false
                blinkPhase = 0
                nextBlinkTime = Double.random(in: 2.0...5.0)
                blinkTimer = 0
            } else {
                blinkValue = Float(sin(blinkPhase))
            }
        } else if blinkTimer >= nextBlinkTime {
            isBlinking = true
            blinkPhase = 0
        }
        
        let targetSquint = normalizedLevel > 0.5 ? (normalizedLevel - 0.5) * 0.3 : 0
        smoothedSquint = smoothedSquint * 0.9 + targetSquint * 0.1
        
        // === HEAD MICRO-MOVEMENT ===
        let headActivity = normalizedLevel * 0.6 + 0.1
        
        headNodPhase += dt * (1.5 + Double(normalizedLevel) * 2.0)
        headSwayPhase += dt * (0.8 + Double(normalizedLevel) * 1.2)
        headTiltPhase += dt * 0.6
        
        let nodAngle = Float(sin(headNodPhase)) * 0.04 * headActivity
        let swayAngle = Float(sin(headSwayPhase)) * 0.03 * headActivity
        let tiltAngle = Float(sin(headTiltPhase)) * 0.015 * headActivity
        
        let pitchQ = simd_quatf(angle: nodAngle, axis: SIMD3<Float>(1, 0, 0))
        let yawQ = simd_quatf(angle: swayAngle, axis: SIMD3<Float>(0, 1, 0))
        let rollQ = simd_quatf(angle: tiltAngle, axis: SIMD3<Float>(0, 0, 1))
        headRotation = pitchQ * yawQ * rollQ
        
        // === BUILD BLENDSHAPES ===
        var bs: [String: Float] = [:]
        
        // Mouth
        bs["jawOpen"] = smoothedJaw
        bs["mouthFunnel"] = smoothedMouth * 0.5
        bs["mouthPucker"] = smoothedMouth * 0.3
        bs["mouthSmileLeft"] = mouthSmile
        bs["mouthSmileRight"] = mouthSmile
        bs["mouthStretchLeft"] = mouthStretch
        bs["mouthStretchRight"] = mouthStretch
        bs["mouthLowerDownLeft"] = smoothedJaw * 0.3
        bs["mouthLowerDownRight"] = smoothedJaw * 0.3
        
        // Brows
        bs["browInnerUp"] = smoothedBrow
        bs["browOuterUpLeft"] = smoothedBrow * 0.6
        bs["browOuterUpRight"] = smoothedBrow * 0.6
        
        // Eyes
        bs["eyeBlinkLeft"] = blinkValue
        bs["eyeBlinkRight"] = blinkValue
        bs["eyeSquintLeft"] = smoothedSquint
        bs["eyeSquintRight"] = smoothedSquint
        
        let lookPhase = Float(sin(time * 0.7))
        bs["eyeLookUpLeft"] = max(0, lookPhase * 0.05)
        bs["eyeLookUpRight"] = max(0, lookPhase * 0.05)
        
        // Cheek puff on strong sounds
        if normalizedLevel > 0.6 {
            let cheek = (normalizedLevel - 0.6) * 0.3
            bs["cheekPuff"] = cheek
        }
        
        tracking.blendshapes = bs
        tracking.rawQuaternion = headRotation
        tracking.coordinateSpace = .world  // stay centered, no camera-space perspective
        
        // Fire direct callback for 60fps rendering (bypasses SwiftUI)
        onTrackingUpdate?(tracking)
    }
    
    // MARK: - Audio Analysis
    
    private nonisolated func rmsLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelDataValue = channelData.pointee
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        
        var sum: Float = 0
        vDSP_measqv(channelDataValue, 1, &sum, vDSP_Length(count))
        return sqrt(sum)
    }
}

// MARK: - Display Link Helper

private class DisplayLinkTarget: NSObject {
    let callback: (Double) -> Void
    private var lastTimestamp: CFTimeInterval = 0
    
    init(callback: @escaping (Double) -> Void) {
        self.callback = callback
    }
    
    @objc func tick(_ link: CADisplayLink) {
        let dt = lastTimestamp == 0 ? 1.0/60.0 : link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        callback(min(dt, 1.0/30.0))
    }
}
