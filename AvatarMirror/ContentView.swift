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
            ZStack {
                AvatarView(
                    bridge: bridge,
                    character: viewModel.currentAnimoji
                )
                .ignoresSafeArea()
                
                // Body overlay — positioned below the avatar head
                if mode == .autonomous {
                    GeometryReader { geo in
                        AvatarBodyOverlay(
                            lean: autonomous.bodyLean,
                            tilt: autonomous.bodyTilt,
                            breath: autonomous.bodyBreath,
                            character: viewModel.currentAnimoji
                        )
                        .frame(width: geo.size.width, height: geo.size.height * 0.45)
                        .position(x: geo.size.width * 0.5, y: geo.size.height * 0.78)
                        .allowsHitTesting(false)
                    }
                    .ignoresSafeArea()
                }
            }
            #endif

            VStack(spacing: 0) {
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

                // All controls flattened — each row scrolls horizontally
                VStack(spacing: 6) {
                    // Row 1: Mode picker
                    scrollRow {
                        ForEach(AvatarMode.allCases, id: \.self) { m in
                            chip(m.rawValue, active: mode == m) { mode = m }
                        }
                    }

                    // Row 2: State (autonomous)
                    if mode == .autonomous {
                        scrollRow {
                            chip("Idle", active: autonomous.currentState == .idle) { autonomous.goIdle() }
                            chip("Listen", active: autonomous.currentState == .listening) { autonomous.startListening() }
                            chip("Think", active: autonomous.currentState == .thinking) { autonomous.startThinking() }
                            Divider().frame(height: 20).background(Color.white.opacity(0.2))
                            chip("Nod", color: .orange) { autonomous.nod() }
                            chip("Shake", color: .orange) { autonomous.shake() }
                            chip("Tilt", color: .orange) { autonomous.tilt() }
                            Divider().frame(height: 20).background(Color.white.opacity(0.2))
                            chipEmoji("😊") { autonomous.playExpression(.smile) }
                            chipEmoji("😮") { autonomous.playExpression(.surprised) }
                            chipEmoji("😢") { autonomous.playExpression(.sad) }
                            chipEmoji("😠") { autonomous.playExpression(.angry) }
                            chipEmoji("😜") { autonomous.playExpression(.tongueOut) }
                        }
                    }

                    // Row 3: Audio samples
                    if mode == .autonomous || mode == .audioFile {
                        scrollRow {
                            ForEach(AudioSample.all) { sample in
                                chip("\(sample.voice) \(sample.name)") {
                                    if mode == .autonomous {
                                        autonomous.speakWithSample(sample)
                                    } else {
                                        audioAnimator.startWithAudioFile(sample.url!)
                                    }
                                }
                            }
                            chip("File…", color: .gray) { showFilePicker = true }
                        }
                    }

                    // Row 4: Tracking mode (face tracking)
                    if mode == .faceTracking {
                        scrollRow {
                            chip("World", active: trackingMode == .world) { trackingMode = .world }
                            chip("Camera", active: trackingMode == .camera) { trackingMode = .camera }
                            chip("AppleAR", active: trackingMode == .appleAR) { trackingMode = .appleAR }
                        }
                    }

                    // Row 5: Characters
                    scrollRow {
                        ForEach(AvatarBridge.availableAnimoji, id: \.self) { name in
                            chip(name, active: viewModel.currentAnimoji == name) {
                                viewModel.currentAnimoji = name
                            }
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: mode)
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
                // Scale idle spatial movement to visible but grounded range
                // Raw values ~0.002-0.009m → want ~0.5-2.0 avatar units of subtle sway
                t.headTranslation = SIMD3(
                    t.headTranslation.x * 200,
                    t.headTranslation.y * 150,
                    t.headTranslation.z * 200 - 40
                )
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

    // MARK: - Reusable UI

    private func scrollRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) { content() }.padding(.horizontal, 12)
        }
    }

    private func chip(_ label: String, color: Color = .blue, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(active ? color : Color.white.opacity(0.12))
                .foregroundStyle(.white)
                .cornerRadius(6)
        }
    }

    private func chipEmoji(_ emoji: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(emoji)
                .font(.callout)
                .frame(width: 32, height: 28)
                .background(Color.purple.opacity(0.25))
                .cornerRadius(6)
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
