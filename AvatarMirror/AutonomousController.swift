import SwiftUI
import AvatarKit
import AVFoundation

/// Autonomous mode: BehaviorEngine drives the avatar with idle, listening, speaking, thinking states.
@MainActor
final class AutonomousController: ObservableObject {
    @Published var status = "Idle"
    @Published var currentState: AvatarBehaviorEngine.BehaviorState = .idle
    
    /// Body state derived from head motion — drives the body overlay.
    @Published var bodyLean: CGFloat = 0      // -1 (left) to 1 (right)
    @Published var bodyTilt: CGFloat = 0      // forward/back lean
    @Published var bodyBreath: CGFloat = 0    // 0..1 breathing cycle
    
    let engine = AvatarBehaviorEngine()
    
    /// Direct callback for 60fps tracking updates.
    var onTrackingUpdate: ((AvatarFaceTracking) -> Void)?
    
    private var breathPhase: Double = 0
    
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AVAudioPlayerNode?
    private var currentFileURL: URL?
    private var currentFileIsSecurityScoped = false
    
    func start() {
        engine.onFrame = { [weak self] tracking in
            self?.updateBodyState(from: tracking)
            self?.onTrackingUpdate?(tracking)
        }
        engine.start()
        status = "Autonomous — Idle"
    }
    
    private func updateBodyState(from tracking: AvatarFaceTracking) {
        // Derive body lean from head translation X (head moves right → body leans right)
        // headTranslation is in avatar units after scaling in ContentView
        let rawLean = Double(tracking.headTranslation.x)
        let smoothing = 0.15
        let newLean = bodyLean + (rawLean * 0.005 - bodyLean) * smoothing
        
        // Forward/back from head pitch (looking down = forward lean)
        let pitch = Double(tracking.headRotation.pitch)
        let newTilt = bodyTilt + (pitch * 0.3 - bodyTilt) * smoothing
        
        // Breathing cycle (independent, ~4 second period)
        breathPhase += 1.0 / 60.0 * 0.25  // ~4s period at 60fps
        if breathPhase > 1.0 { breathPhase -= 1.0 }
        let newBreath = (1.0 + sin(breathPhase * .pi * 2)) * 0.5
        
        bodyLean = newLean.clamped(to: -1...1)
        bodyTilt = newTilt.clamped(to: -1...1)
        bodyBreath = newBreath
    }
    
    func stop() {
        stopAudio()
        engine.stop()
    }
    
    // MARK: - State Control
    
    func goIdle() {
        stopAudio()
        engine.transition(to: .idle)
        currentState = .idle
        status = "Autonomous — Idle"
    }
    
    func startListening() {
        engine.transition(to: .listening)
        currentState = .listening
        status = "Autonomous — Listening"
    }
    
    func startThinking() {
        engine.transition(to: .thinking)
        currentState = .thinking
        status = "Autonomous — Thinking"
    }
    
    func playExpression(_ preset: ExpressionPreset) {
        engine.emote(preset, duration: 0.3, holdFor: 1.5)
        status = "Emoting"
    }
    
    func nod() {
        engine.headGesture.nod()
    }
    
    func shake() {
        engine.headGesture.shake()
    }
    
    func tilt() {
        engine.headGesture.tilt()
    }
    
    // MARK: - Speaking with Audio File
    
    func speakWithFile(_ url: URL) {
        stopAudio()
        
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            status = "Cannot read audio"
            if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
            return
        }
        
        currentFileURL = url
        currentFileIsSecurityScoped = isSecurityScoped
        
        let avEngine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        avEngine.attach(player)
        
        let format = audioFile.processingFormat
        avEngine.connect(player, to: avEngine.mainMixerNode, format: format)
        
        do {
            try avEngine.start()
            // .dataPlayedBack ensures callback fires AFTER audio is heard,
            // not when the buffer is merely scheduled/consumed.
            player.scheduleFile(audioFile, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.goIdle()
                }
            }
            player.play()
            
            self.audioEngine = avEngine
            self.audioPlayer = player
            
            // Use BehaviorEngine's speaking mode with audio analysis
            engine.speakWithAudioNode(avEngine.mainMixerNode, engine: avEngine)
            currentState = .speaking
            status = "Speaking — \(url.lastPathComponent)"
        } catch {
            status = "Audio error: \(error.localizedDescription)"
            if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
        }
    }
    
    func speakWithSample(_ sample: AudioSample) {
        guard let url = sample.url else { return }
        speakWithFile(url)
    }
    
    // MARK: - Speaking with Microphone
    
    func speakWithMicrophone() {
        stopAudio()
        
        let avEngine = AVAudioEngine()
        do {
            try avEngine.start()
            self.audioEngine = avEngine
            engine.speakWithAudioNode(avEngine.inputNode, engine: avEngine)
            currentState = .speaking
            status = "Speaking — Microphone"
        } catch {
            status = "Mic error: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Cleanup
    
    private func stopAudio() {
        audioPlayer?.stop()
        audioEngine?.stop()
        audioEngine?.mainMixerNode.removeTap(onBus: 0)
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioPlayer = nil
        if currentFileIsSecurityScoped {
            currentFileURL?.stopAccessingSecurityScopedResource()
        }
        currentFileURL = nil
        currentFileIsSecurityScoped = false
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
