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

    private let bridge = AvatarBridge()

    enum AvatarMode {
        case faceTracking
        case audioFile
        case microphone
    }

    private func applyTracking(_ tracking: AvatarFaceTracking) {
        var t = tracking
        t.coordinateSpace = debugSettings.cameraSpace ? .cameraRotationOnly : .world
        if debugSettings.forceCenter {
            t.rawQuaternion = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        bridge.applyTracking(t)
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
                bridge: bridge,
                character: viewModel.currentAnimoji
            )
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
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 4)
                }

                // Debug toggles
                if showDebug {
                    HStack(spacing: 12) {
                        debugToggle("cameraSpace", isOn: $debugSettings.cameraSpace)
                        debugToggle("worldSpace", isOn: $debugSettings.worldSpace)
                        debugToggle("forceCenter", isOn: $debugSettings.forceCenter)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }

                // Controls
                HStack(spacing: 16) {
                    // Mode picker
                    Menu {
                        Button("Face Tracking") { switchMode(to: .faceTracking) }
                        Button("Audio File") { switchMode(to: .audioFile) }
                        Button("Microphone") { switchMode(to: .microphone) }
                    } label: {
                        Image(systemName: modeIcon)
                            .font(.title2)
                            .foregroundStyle(.white)
                    }

                    if mode == .audioFile {
                        Button {
                            showSamples.toggle()
                        } label: {
                            Image(systemName: "music.note.list")
                                .font(.title2)
                                .foregroundStyle(showSamples ? .orange : .white)
                        }

                        Button {
                            showFilePicker = true
                        } label: {
                            Image(systemName: "folder")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                    }

                    Spacer()

                    Button {
                        showDebug.toggle()
                    } label: {
                        Image(systemName: "ladybug")
                            .font(.title2)
                            .foregroundStyle(showDebug ? .orange : .white.opacity(0.4))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
        }
        .onChange(of: activeTracking.timestamp) { _, _ in
            applyTracking(activeTracking)
        }
        .onChange(of: debugSettings.cameraSpace) { _, _ in
            applyTracking(activeTracking)
        }
        .onChange(of: debugSettings.forceCenter) { _, _ in
            applyTracking(activeTracking)
        }
        .onAppear {
            viewModel.start()
            audioAnimator.onTrackingUpdate = { [weak debugSettings] tracking in
                guard let s = debugSettings else { return }
                var t = tracking
                t.coordinateSpace = s.cameraSpace ? .cameraRotationOnly : .world
                if s.forceCenter {
                    t.rawQuaternion = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                }
                bridge.applyTracking(t)
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav, .aiff],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                playFile(url)
            }
        }
    }

    // MARK: - Helpers

    private var statusText: String {
        switch mode {
        case .faceTracking: return viewModel.debugStatus
        case .audioFile, .microphone: return audioAnimator.status
        }
    }

    private var modeIcon: String {
        switch mode {
        case .faceTracking: return "face.smiling"
        case .audioFile: return "waveform"
        case .microphone: return "mic"
        }
    }

    private func playSample(_ sample: AudioSample) {
        guard let url = sample.url else { return }
        audioAnimator.startWithAudioFile(url)
    }

    private func playFile(_ url: URL) {
        audioAnimator.startWithAudioFile(url)
    }

    private func switchMode(to newMode: AvatarMode) {
        audioAnimator.stop()
        mode = newMode
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
