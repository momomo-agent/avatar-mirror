import SwiftUI
import AvatarKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = AvatarMirrorViewModel()
    @StateObject private var audioAnimator = AudioDrivenAnimator()
    @State private var mode: AvatarMode = .faceTracking
    @State private var showFilePicker = false
    
    enum AvatarMode {
        case faceTracking
        case audioFile
        case microphone
    }
    
    /// Active tracking source based on mode.
    private var activeTracking: AvatarFaceTracking {
        switch mode {
        case .faceTracking: return viewModel.tracking
        case .audioFile, .microphone: return audioAnimator.tracking
        }
    }
    
    /// Active transition — smooth for audio, none for face tracking.
    private var activeTransition: AvatarTransition {
        switch mode {
        case .faceTracking: return .none
        case .audioFile, .microphone: return .none // audio animator handles its own interpolation
        }
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            AvatarView(
                animoji: viewModel.currentAnimoji,
                tracking: activeTracking,
                transition: activeTransition
            )
            .ignoresSafeArea()
            
            VStack {
                // Status bar
                HStack {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                Spacer()
                
                // Mode switcher
                HStack(spacing: 12) {
                    modeButton("Face", icon: "face.smiling", mode: .faceTracking)
                    modeButton("Mic", icon: "mic.fill", mode: .microphone)
                    
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Audio", systemImage: "doc.fill")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(mode == .audioFile ? .blue.opacity(0.5) : .white.opacity(0.1))
                            .clipShape(Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .padding(.bottom, 4)
                
                // Animoji picker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AvatarView.availableAnimoji, id: \.self) { name in
                            Button {
                                viewModel.currentAnimoji = name
                            } label: {
                                Text(name.capitalized)
                                    .font(.caption2)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(viewModel.currentAnimoji == name ? .white.opacity(0.3) : .white.opacity(0.1))
                                    .clipShape(Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 8)
            }
        }
        .onAppear { viewModel.start() }
        .onDisappear {
            viewModel.stop()
            audioAnimator.stop()
        }
        .onChange(of: mode) { _, newMode in
            switchMode(to: newMode)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav, .aiff],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                mode = .audioFile
                audioAnimator.stop()
                audioAnimator.startWithAudioFile(url)
            }
        }
        .statusBarHidden()
    }
    
    private var statusText: String {
        switch mode {
        case .faceTracking: return viewModel.debugStatus
        case .audioFile, .microphone: return audioAnimator.status
        }
    }
    
    private func modeButton(_ title: String, icon: String, mode: AvatarMode) -> some View {
        Button {
            self.mode = mode
        } label: {
            Label(title, systemImage: icon)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(self.mode == mode ? .blue.opacity(0.5) : .white.opacity(0.1))
                .clipShape(Capsule())
                .foregroundStyle(.white)
        }
    }
    
    private func switchMode(to newMode: AvatarMode) {
        // Stop previous
        audioAnimator.stop()
        
        switch newMode {
        case .faceTracking:
            viewModel.start()
        case .microphone:
            viewModel.stop()
            audioAnimator.startWithMicrophone()
        case .audioFile:
            viewModel.stop()
            // File picker handles start
            break
        }
    }
}
