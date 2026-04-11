import SwiftUI
import AvatarKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = AvatarMirrorViewModel()
    @StateObject private var audioAnimator = AudioDrivenAnimator()
    @State private var mode: AvatarMode = .faceTracking
    @State private var showFilePicker = false
    @State private var showSamples = false
    
    enum AvatarMode {
        case faceTracking
        case audioFile
        case microphone
    }
    
    private var activeTracking: AvatarFaceTracking {
        switch mode {
        case .faceTracking: return viewModel.tracking
        case .audioFile, .microphone: return audioAnimator.tracking
        }
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            AvatarView(
                animoji: viewModel.currentAnimoji,
                tracking: activeTracking
            )
            .trackingSource { callback in
                audioAnimator.onTrackingUpdate = callback
            }
            .ignoresSafeArea()
            
            VStack {
                // Status
                HStack {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                Spacer()
                
                // Sample audio picker (shown when in audio mode)
                if showSamples {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(AudioSample.all) { sample in
                                Button {
                                    playSample(sample)
                                } label: {
                                    VStack(spacing: 2) {
                                        Text(sample.name)
                                            .font(.caption)
                                        Text(sample.voice)
                                            .font(.caption2)
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.white.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .foregroundStyle(.white)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 4)
                }
                
                // Mode switcher
                HStack(spacing: 12) {
                    modeButton("Face", icon: "face.smiling", active: mode == .faceTracking) {
                        mode = .faceTracking
                    }
                    modeButton("Mic", icon: "mic.fill", active: mode == .microphone) {
                        mode = .microphone
                    }
                    modeButton("Samples", icon: "music.note.list", active: showSamples) {
                        showSamples.toggle()
                    }
                    
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("File", systemImage: "doc.fill")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.1))
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
    
    private func modeButton(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(active ? .blue.opacity(0.5) : .white.opacity(0.1))
                .clipShape(Capsule())
                .foregroundStyle(.white)
        }
    }
    
    private func playSample(_ sample: AudioSample) {
        guard let url = sample.url else {
            audioAnimator.status = "❌ Sample not found: \(sample.filename)"
            return
        }
        mode = .audioFile
        viewModel.stop()
        audioAnimator.stop()
        audioAnimator.startWithAudioFile(url)
    }
    
    private func switchMode(to newMode: AvatarMode) {
        audioAnimator.stop()
        switch newMode {
        case .faceTracking:
            viewModel.start()
        case .microphone:
            viewModel.stop()
            audioAnimator.startWithMicrophone()
        case .audioFile:
            viewModel.stop()
        }
    }
}
