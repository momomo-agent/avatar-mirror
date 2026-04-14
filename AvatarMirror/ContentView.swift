import SwiftUI
import AvatarKit
import UniformTypeIdentifiers
import simd

struct ContentView: View {
    @StateObject private var viewModel = AvatarMirrorViewModel()
    @StateObject private var audioAnimator = AudioDrivenAnimator()
    @State private var mode: AvatarMode = .faceTracking
    @State private var trackingMode: AvatarFaceTracking.TrackingMode = .camera
    @State private var showFilePicker = false
    @State private var showSamples = false

    private let bridge = AvatarBridge()

    enum AvatarMode {
        case faceTracking
        case audioFile
        case microphone
    }

    private func applyTracking(_ tracking: AvatarFaceTracking) {
        bridge.applyTracking(tracking, frame: viewModel.lastARFrame)
    }

    private var activeTracking: AvatarFaceTracking {
        switch mode {
        case .faceTracking:
            switch trackingMode {
            case .world: return viewModel.trackingWorld
            case .camera: return viewModel.trackingCamera
            case .appleAR: return viewModel.trackingAppleAR
            }
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

                // Sample audio picker
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

                // Tracking mode picker
                if mode == .faceTracking {
                    HStack(spacing: 0) {
                        ForEach(AvatarFaceTracking.TrackingMode.allCases, id: \.self) { tm in
                            Button {
                                trackingMode = tm
                                applyTracking(activeTracking)
                            } label: {
                                Text(tm.rawValue)
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(trackingMode == tm ? .white.opacity(0.2) : .clear)
                            }
                            .foregroundStyle(trackingMode == tm ? .white : .white.opacity(0.4))
                        }
                    }
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.bottom, 4)
                }

                // Controls
                HStack(spacing: 16) {
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
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
        }
        .onChange(of: viewModel.trackingWorld.timestamp) { _, _ in
            applyTracking(activeTracking)
        }
        .onChange(of: audioAnimator.tracking.timestamp) { _, _ in
            applyTracking(activeTracking)
        }
        .onAppear {
            viewModel.start()
            audioAnimator.onTrackingUpdate = { tracking in
                var t = tracking
                t.coordinateSpace = .world
                t.headTranslation = .zero
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
            viewModel.start()
        case .microphone:
            viewModel.stop()
            audioAnimator.startWithMicrophone()
        case .audioFile:
            viewModel.stop()
        }
    }
}
