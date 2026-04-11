import SwiftUI
import AvatarKit
import UniformTypeIdentifiers
import simd

struct ContentView: View {
    @StateObject private var viewModel = AvatarMirrorViewModel()
    @StateObject private var audioAnimator = AudioDrivenAnimator()
    @State private var mode: AvatarMode = .faceTracking
    @State private var showFilePicker = false
    @State private var showSamples = false
    @State private var showDebug = false
    @StateObject private var debugSettings = DebugSettings()
    
    enum AvatarMode {
        case faceTracking
        case audioFile
        case microphone
    }
    
    private var activeTracking: AvatarFaceTracking {
        var t: AvatarFaceTracking
        switch mode {
        case .faceTracking: t = viewModel.tracking
        case .audioFile, .microphone: t = audioAnimator.tracking
        }
        t.cameraSpace = debugSettings.cameraSpace
        if debugSettings.forceCenter {
            t.headRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return t
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            AvatarView(
                animoji: viewModel.currentAnimoji,
                tracking: activeTracking
            )
            .trackingSource { callback in
                audioAnimator.onTrackingUpdate = { [weak debugSettings] tracking in
                    var t = tracking
                    if let s = debugSettings {
                        t.cameraSpace = s.cameraSpace
                        if s.forceCenter {
                            t.headRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                        }
                    }
                    callback(t)
                }
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
                    
                    Button {
                        showDebug.toggle()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.caption)
                            .padding(8)
                            .background(showDebug ? .orange.opacity(0.5) : .white.opacity(0.1))
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                    }
                }
                .padding(.bottom, 4)
                
                // Debug toggles
                if showDebug {
                    HStack(spacing: 16) {
                        debugToggle("Camera Space", isOn: $debugSettings.cameraSpace)
                        debugToggle("World Space", isOn: $debugSettings.worldSpace)
                        debugToggle("Center", isOn: $debugSettings.forceCenter)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }
                
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
            debugSettings.cameraSpace = true
            viewModel.start()
        case .microphone:
            debugSettings.cameraSpace = false
            viewModel.stop()
            audioAnimator.startWithMicrophone()
        case .audioFile:
            debugSettings.cameraSpace = false
            viewModel.stop()
        }
    }
    
    private func debugToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.caption2)
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(isOn.wrappedValue ? .orange : .white.opacity(0.5))
        }
    }
}

class DebugSettings: ObservableObject {
    @Published var cameraSpace = true
    @Published var worldSpace = false
    @Published var forceCenter = false
}
