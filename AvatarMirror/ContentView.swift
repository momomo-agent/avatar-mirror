import SwiftUI
import AvatarKit
import UniformTypeIdentifiers
import simd

struct ContentView: View {
    @StateObject private var viewModel = AvatarMirrorViewModel()
    @StateObject private var audioAnimator = AudioDrivenAnimator()
    @StateObject private var autonomous = AutonomousController()
    @State private var mode: AvatarMode = .autonomous
    @State private var trackingMode: AvatarFaceTracking.TrackingMode = .camera
    @State private var showFilePicker = false
    @State private var showSamples = false
    @State private var showControls = false

    #if !targetEnvironment(simulator)
    private let bridge = AvatarBridge()
    #endif

    enum AvatarMode: String, CaseIterable {
        case autonomous = "Auto"
        case faceTracking = "Face"
        case audioFile = "Audio"
        case microphone = "Mic"
    }

    private func applyTracking(_ tracking: AvatarFaceTracking) {
        #if !targetEnvironment(simulator)
        bridge.applyTracking(tracking, frame: viewModel.lastARFrame)
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if targetEnvironment(simulator)
            simulatorPlaceholder
            #else
            AvatarView(
                bridge: bridge,
                character: viewModel.currentAnimoji
            )
            .ignoresSafeArea()
            #endif

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

                // Autonomous controls
                if mode == .autonomous && showControls {
                    autonomousControlsPanel
                        .padding(.bottom, 4)
                }

                // Sample audio picker
                if showSamples {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(AudioSample.all) { sample in
                                Button {
                                    if mode == .autonomous {
                                        autonomous.speakWithSample(sample)
                                    } else {
                                        audioAnimator.startWithAudioFile(sample.url!)
                                    }
                                } label: {
                                    VStack(spacing: 2) {
                                        Text(sample.voice)
                                            .font(.caption2)
                                        Text(sample.name)
                                            .font(.caption2)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(8)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(height: 60)
                }

                // Bottom toolbar
                HStack(spacing: 16) {
                    // Mode picker
                    Picker("Mode", selection: $mode) {
                        ForEach(AvatarMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)

                    Spacer()

                    // Controls toggle (autonomous)
                    if mode == .autonomous {
                        Button {
                            showControls.toggle()
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(.white)
                        }
                    }

                    // Samples toggle
                    if mode == .audioFile || mode == .autonomous {
                        Button {
                            showSamples.toggle()
                        } label: {
                            Image(systemName: "music.note.list")
                                .foregroundStyle(.white)
                        }
                    }

                    // File picker
                    if mode == .audioFile {
                        Button {
                            showFilePicker = true
                        } label: {
                            Image(systemName: "folder")
                                .foregroundStyle(.white)
                        }
                    }

                    // Tracking mode (face tracking only)
                    if mode == .faceTracking {
                        Picker("", selection: $trackingMode) {
                            Text("world").tag(AvatarFaceTracking.TrackingMode.world)
                            Text("camera").tag(AvatarFaceTracking.TrackingMode.camera)
                            Text("appleAR").tag(AvatarFaceTracking.TrackingMode.appleAR)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 200)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .onChange(of: mode) { _, newMode in
            switchMode(to: newMode)
        }
        .onChange(of: viewModel.trackingWorld.timestamp) { _, _ in
            guard mode == .faceTracking else { return }
            applyTracking(activeTracking)
        }
        .onAppear {
            switchMode(to: mode)
            audioAnimator.onTrackingUpdate = { tracking in
                var t = tracking
                t.coordinateSpace = .world
                t.headTranslation = .zero
                #if !targetEnvironment(simulator)
                bridge.applyTracking(t)
                #endif
            }
            autonomous.onTrackingUpdate = { tracking in
                var t = tracking
                t.coordinateSpace = .world
                t.headTranslation = .zero
                #if !targetEnvironment(simulator)
                bridge.applyTracking(t)
                #endif
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                if mode == .autonomous {
                    autonomous.speakWithFile(url)
                } else {
                    audioAnimator.startWithAudioFile(url)
                }
            }
        }
    }

    // MARK: - Autonomous Controls

    private var autonomousControlsPanel: some View {
        VStack(spacing: 8) {
            // State buttons
            HStack(spacing: 8) {
                stateButton("Idle", state: .idle) { autonomous.goIdle() }
                stateButton("Listen", state: .listening) { autonomous.startListening() }
                stateButton("Think", state: .thinking) { autonomous.startThinking() }
            }

            // Gesture buttons
            HStack(spacing: 8) {
                gestureButton("Nod") { autonomous.nod() }
                gestureButton("Shake") { autonomous.shake() }
                gestureButton("Tilt") { autonomous.tilt() }
            }

            // Expression buttons
            HStack(spacing: 8) {
                expressionButton("😊", preset: .smile)
                expressionButton("😮", preset: .surprised)
                expressionButton("😢", preset: .sad)
                expressionButton("😠", preset: .angry)
                expressionButton("😜", preset: .tongueOut)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private func stateButton(_ label: String, state: AvatarBehaviorEngine.BehaviorState, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(autonomous.currentState == state ? Color.blue : Color.gray.opacity(0.3))
                .foregroundStyle(.white)
                .cornerRadius(6)
        }
    }

    private func gestureButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.3))
                .foregroundStyle(.white)
                .cornerRadius(6)
        }
    }

    private func expressionButton(_ emoji: String, preset: ExpressionPreset) -> some View {
        Button {
            autonomous.playExpression(preset)
        } label: {
            Text(emoji)
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(Color.purple.opacity(0.3))
                .cornerRadius(8)
        }
    }

    // MARK: - Helpers

    private var activeTracking: AvatarFaceTracking {
        switch trackingMode {
        case .world: return viewModel.trackingWorld
        case .camera: return viewModel.trackingCamera
        case .appleAR: return viewModel.trackingAppleAR
        }
    }

    private var statusText: String {
        switch mode {
        case .autonomous: return autonomous.status
        case .faceTracking: return viewModel.debugStatus
        case .audioFile, .microphone: return audioAnimator.status
        }
    }

    private func switchMode(to newMode: AvatarMode) {
        // Stop everything
        audioAnimator.stop()
        autonomous.stop()
        viewModel.stop()

        switch newMode {
        case .autonomous:
            autonomous.start()
        case .faceTracking:
            viewModel.start()
        case .microphone:
            audioAnimator.startWithMicrophone()
        case .audioFile:
            break
        }
    }

    // MARK: - Simulator Placeholder

    #if targetEnvironment(simulator)
    private let animojiCharacters = ["fox", "cat", "dog", "robot", "alien", "panda", "unicorn", "owl", "monkey", "lion"]

    private var simulatorPlaceholder: some View {
        VStack(spacing: 16) {
            if let img = AvatarCatalog.headTexture(for: viewModel.currentAnimoji) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .clipShape(Circle())
                    .shadow(color: .white.opacity(0.1), radius: 20)
            } else {
                Text(characterEmoji)
                    .font(.system(size: 80))
            }
            Text(viewModel.currentAnimoji.capitalized)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
            Text("Simulator \u{2014} AVTView requires device")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            let current = viewModel.currentAnimoji
            let idx = animojiCharacters.firstIndex(of: current) ?? 0
            let next = (idx + 1) % animojiCharacters.count
            viewModel.currentAnimoji = animojiCharacters[next]
        }
    }

    private var characterEmoji: String {
        ["fox": "🦊", "cat": "🐱", "dog": "🐶", "robot": "🤖",
         "alien": "👽", "panda": "🐼", "unicorn": "🦄", "owl": "🦉",
         "monkey": "🐵", "lion": "🦁"][viewModel.currentAnimoji] ?? "🦊"
    }
    #endif
}
