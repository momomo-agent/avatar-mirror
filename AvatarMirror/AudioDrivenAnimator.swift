import Foundation
import AVFoundation
import Speech
import AvatarKit
import simd

/// Drives Animoji lip-sync and head motion from audio.
/// Uses SFSpeechRecognizer for phoneme→viseme mapping + natural head movement.
@MainActor
final class AudioDrivenAnimator: ObservableObject {
    
    @Published var tracking = AvatarFaceTracking()
    @Published var isActive = false
    @Published var status = ""
    
    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var displayLink: CADisplayLink?
    
    // Audio analysis
    private var currentRMS: Float = 0
    private var smoothedRMS: Float = 0
    
    // Viseme state
    private var currentViseme: Viseme = .neutral
    private var targetViseme: Viseme = .neutral
    private var visemeProgress: Float = 1.0
    private var lastVisemeTime: CFTimeInterval = 0
    
    // Head motion
    private var headTime: CFTimeInterval = 0
    private var headBaseYaw: Float = 0
    private var headBasePitch: Float = 0
    
    // MARK: - Viseme definitions
    
    /// Visual phoneme groups mapped to ARKit blendshapes.
    enum Viseme: CaseIterable {
        case neutral    // silence
        case pp         // P, B, M — lips pressed
        case ff         // F, V — lower lip tucked
        case th         // TH — tongue between teeth
        case dd         // T, D, N, L — tongue tip up
        case kk         // K, G, NG — back tongue
        case ch         // CH, J, SH, ZH — wide lips
        case ss         // S, Z — narrow gap
        case nn         // N, NG nasal
        case rr         // R — rounded
        case aa         // A, AI — wide open
        case ee         // E, I — wide smile
        case oo         // O — round
        case uu         // U, W — tight round
        
        var blendshapes: [String: Float] {
            switch self {
            case .neutral:
                return [:]
            case .pp:
                return [
                    "mouthClose": 0.7,
                    "mouthPressLeft": 0.6, "mouthPressRight": 0.6,
                    "mouthPucker": 0.2,
                ]
            case .ff:
                return [
                    "mouthFunnel": 0.3,
                    "jawOpen": 0.1,
                    "mouthLowerDownLeft": 0.3, "mouthLowerDownRight": 0.3,
                ]
            case .th:
                return [
                    "jawOpen": 0.15,
                    "tongueOut": 0.4,
                    "mouthStretchLeft": 0.2, "mouthStretchRight": 0.2,
                ]
            case .dd:
                return [
                    "jawOpen": 0.2,
                    "tongueOut": 0.15,
                    "mouthStretchLeft": 0.15, "mouthStretchRight": 0.15,
                ]
            case .kk:
                return [
                    "jawOpen": 0.25,
                    "mouthStretchLeft": 0.2, "mouthStretchRight": 0.2,
                ]
            case .ch:
                return [
                    "jawOpen": 0.2,
                    "mouthFunnel": 0.4,
                    "mouthStretchLeft": 0.3, "mouthStretchRight": 0.3,
                ]
            case .ss:
                return [
                    "jawOpen": 0.08,
                    "mouthSmileLeft": 0.2, "mouthSmileRight": 0.2,
                    "mouthStretchLeft": 0.3, "mouthStretchRight": 0.3,
                ]
            case .nn:
                return [
                    "mouthClose": 0.4,
                    "mouthPressLeft": 0.3, "mouthPressRight": 0.3,
                ]
            case .rr:
                return [
                    "jawOpen": 0.15,
                    "mouthFunnel": 0.5,
                    "mouthPucker": 0.3,
                ]
            case .aa:
                return [
                    "jawOpen": 0.7,
                    "mouthStretchLeft": 0.2, "mouthStretchRight": 0.2,
                ]
            case .ee:
                return [
                    "jawOpen": 0.2,
                    "mouthSmileLeft": 0.5, "mouthSmileRight": 0.5,
                    "mouthStretchLeft": 0.4, "mouthStretchRight": 0.4,
                ]
            case .oo:
                return [
                    "jawOpen": 0.4,
                    "mouthFunnel": 0.6,
                    "mouthPucker": 0.4,
                ]
            case .uu:
                return [
                    "jawOpen": 0.1,
                    "mouthFunnel": 0.7,
                    "mouthPucker": 0.7,
                ]
            }
        }
    }
    
    // MARK: - Phoneme → Viseme mapping
    
    /// Map IPA-like phoneme substrings to visemes.
    private static let phonemeMap: [(pattern: String, viseme: Viseme)] = [
        // Vowels
        ("ɑ", .aa), ("æ", .aa), ("a", .aa),
        ("i", .ee), ("ɪ", .ee), ("e", .ee), ("ɛ", .ee),
        ("o", .oo), ("ɔ", .oo),
        ("u", .uu), ("ʊ", .uu), ("w", .uu),
        // Consonants
        ("p", .pp), ("b", .pp), ("m", .pp),
        ("f", .ff), ("v", .ff),
        ("θ", .th), ("ð", .th),
        ("t", .dd), ("d", .dd), ("l", .dd), ("n", .dd),
        ("k", .kk), ("g", .kk), ("ŋ", .kk),
        ("ʃ", .ch), ("ʒ", .ch), ("tʃ", .ch), ("dʒ", .ch),
        ("s", .ss), ("z", .ss),
        ("r", .rr), ("ɹ", .rr),
        // Chinese pinyin approximations
        ("zh", .ch), ("ch", .ch), ("sh", .ch),
        ("ng", .kk),
    ]
    
    private func visemeForPhoneme(_ phoneme: String) -> Viseme {
        let lower = phoneme.lowercased()
        for (pattern, viseme) in Self.phonemeMap {
            if lower.contains(pattern) { return viseme }
        }
        // Fallback: use first character
        if let first = lower.first {
            let s = String(first)
            if "aeiou".contains(s) { return .aa }
        }
        return .neutral
    }
    
    // MARK: - Start / Stop
    
    func startWithAudioFile(_ url: URL) {
        status = "Loading audio..."
        
        Task {
            // Request speech recognition permission
            let authStatus = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status)
                }
            }
            guard authStatus == .authorized else {
                status = "❌ Speech recognition denied"
                return
            }
            
            do {
                try await setupAudioPlayback(url: url)
                startDisplayLink()
                isActive = true
                status = "Playing"
            } catch {
                status = "❌ \(error.localizedDescription)"
            }
        }
    }
    
    func startWithMicrophone() {
        status = "Starting mic..."
        
        Task {
            let authStatus = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status)
                }
            }
            guard authStatus == .authorized else {
                status = "❌ Speech recognition denied"
                return
            }
            
            do {
                try await setupMicInput()
                startDisplayLink()
                isActive = true
                status = "Listening"
            } catch {
                status = "❌ \(error.localizedDescription)"
            }
        }
    }
    
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        isActive = false
        status = ""
        currentViseme = .neutral
        targetViseme = .neutral
    }
    
    // MARK: - Audio Setup
    
    private func setupAudioPlayback(url: URL) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        
        // Tap for RMS analysis
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: mixerFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        
        // Speech recognition on the audio file
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()!
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        
        self.speechRecognizer = recognizer
        
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let result = result else { return }
            // Extract segments for timing
            for segment in result.bestTranscription.segments {
                let viseme = self?.visemeForText(segment.substring) ?? .neutral
                let delay = segment.timestamp
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self?.setViseme(viseme)
                }
            }
        }
        
        try engine.start()
        playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.stop()
            }
        }
        playerNode.play()
        
        self.audioEngine = engine
    }
    
    private func setupMicInput() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // Live speech recognition
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()!
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        
        self.speechRecognizer = recognizer
        self.recognitionRequest = request
        
        // Single tap: RMS analysis + feed to speech recognizer
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
            request.append(buffer)
        }
        
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let result = result else { return }
            if let lastSegment = result.bestTranscription.segments.last {
                let viseme = self?.visemeForText(lastSegment.substring) ?? .neutral
                DispatchQueue.main.async {
                    self?.setViseme(viseme)
                }
            }
        }
        
        try engine.start()
        self.audioEngine = engine
    }
    
    // MARK: - Audio Processing
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count {
            sum += channelData[i] * channelData[i]
        }
        let rms = sqrt(sum / Float(max(count, 1)))
        DispatchQueue.main.async {
            self.currentRMS = rms
        }
    }
    
    private func visemeForText(_ text: String) -> Viseme {
        // Simple: map first character to a viseme
        guard let first = text.first else { return .neutral }
        let s = String(first).lowercased()
        
        // Chinese character → approximate mouth shape
        // This is a rough mapping; real implementation would use pinyin
        if s.unicodeScalars.first.map({ $0.value > 0x4E00 }) == true {
            // Chinese characters — cycle through common shapes based on hash
            let shapes: [Viseme] = [.aa, .ee, .oo, .uu, .aa, .ee]
            let idx = abs(s.hashValue) % shapes.count
            return shapes[idx]
        }
        
        return visemeForPhoneme(s)
    }
    
    private func setViseme(_ viseme: Viseme) {
        if viseme != currentViseme {
            targetViseme = viseme
            visemeProgress = 0
            lastVisemeTime = CACurrentMediaTime()
        }
    }
    
    // MARK: - Display Link
    
    private func startDisplayLink() {
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in
            self?.tick()
        }, selector: #selector(DisplayLinkTarget.step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    
    private func tick() {
        let now = CACurrentMediaTime()
        
        // Smooth RMS
        smoothedRMS = smoothedRMS * 0.7 + currentRMS * 0.3
        let amplitude = min(smoothedRMS * 8, 1.0) // normalize
        
        // Viseme interpolation (50ms transition)
        let visemeDuration: Float = 0.05
        if visemeProgress < 1.0 {
            visemeProgress = min(visemeProgress + Float(1.0 / 60.0) / visemeDuration, 1.0)
            if visemeProgress >= 1.0 {
                currentViseme = targetViseme
            }
        }
        
        // Auto-return to neutral when silent
        if amplitude < 0.05 && currentViseme != .neutral {
            setViseme(.neutral)
        }
        
        // Blend current and target viseme blendshapes
        let fromBS = currentViseme.blendshapes
        let toBS = targetViseme.blendshapes
        let t = easeInOut(visemeProgress)
        
        var allKeys = Set(fromBS.keys)
        allKeys.formUnion(toBS.keys)
        
        var blendshapes: [String: Float] = [:]
        for key in allKeys {
            let a = fromBS[key] ?? 0
            let b = toBS[key] ?? 0
            blendshapes[key] = a + (b - a) * t
        }
        
        // Scale by amplitude — mouth opens more when louder
        let jawFromViseme = blendshapes["jawOpen"] ?? 0
        blendshapes["jawOpen"] = max(jawFromViseme, amplitude * 0.6)
        
        // Head motion — subtle natural movement
        headTime = now
        let yaw = sin(Float(now) * 0.7) * 0.06 + sin(Float(now) * 1.3) * 0.03
        let pitch = sin(Float(now) * 0.5) * 0.04 + sin(Float(now) * 1.1) * 0.02
        let roll = sin(Float(now) * 0.9) * 0.02
        
        // More head movement when speaking
        let speakingBoost: Float = amplitude > 0.1 ? 1.5 : 1.0
        
        let headQ = simd_quatf(angle: yaw * speakingBoost, axis: simd_float3(0, 1, 0))
            * simd_quatf(angle: pitch * speakingBoost, axis: simd_float3(1, 0, 0))
            * simd_quatf(angle: roll, axis: simd_float3(0, 0, 1))
        
        // Blink occasionally
        let blinkCycle = fmod(Float(now), 4.0)
        if blinkCycle > 3.8 {
            let blinkT = (blinkCycle - 3.8) / 0.2
            let blinkVal = blinkT < 0.5 ? blinkT * 2 : (1.0 - blinkT) * 2
            blendshapes["eyeBlinkLeft"] = blinkVal
            blendshapes["eyeBlinkRight"] = blinkVal
        }
        
        // Subtle brow movement when speaking
        if amplitude > 0.15 {
            blendshapes["browInnerUp"] = amplitude * 0.3
        }
        
        tracking = AvatarFaceTracking(
            blendshapes: blendshapes,
            headRotation: headQ,
            isTracking: true
        )
    }
    
    private func easeInOut(_ t: Float) -> Float {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}

// MARK: - DisplayLink target (avoid retain cycle)

private class DisplayLinkTarget {
    let callback: () -> Void
    init(callback: @escaping () -> Void) { self.callback = callback }
    @objc func step() { callback() }
}
