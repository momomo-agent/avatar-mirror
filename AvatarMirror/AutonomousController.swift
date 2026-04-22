import SwiftUI
import AvatarKit
import AVFoundation

/// Autonomous mode: BehaviorEngine drives the avatar with idle, listening, speaking, thinking states.
@MainActor
final class AutonomousController: ObservableObject {
    @Published var status = "Idle"
    @Published var currentState: AvatarBehaviorEngine.BehaviorState = .idle
    
    let engine = AvatarBehaviorEngine()
    
    /// Direct callback for 60fps tracking updates.
    var onTrackingUpdate: ((AvatarFaceTracking) -> Void)?
    
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AVAudioPlayerNode?
    private var currentFileURL: URL?
    private var currentFileIsSecurityScoped = false
    
    func start() {
        engine.onFrame = { [weak self] tracking in
            self?.onTrackingUpdate?(tracking)
        }
        engine.start()
        status = "Autonomous — Idle"
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
            player.scheduleFile(audioFile, at: nil) { [weak self] in
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
