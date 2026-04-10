import SwiftUI
import ARKit
import AVFoundation
import HumanSenseKit

@MainActor
final class AvatarMirrorViewModel: NSObject, ObservableObject {
    @Published var isTracking = false
    @Published var currentAnimoji = "tiger"
    @Published var isMemoji = false
    @Published var currentPose = "person_waving"
    @Published var debugStatus = "Starting..."
    
    let bridge = AvatarKitBridge()
    let memojiEditor = MemojiEditorBridge()
    
    private var kit: HumanSenseKit?
    private var displayLink: CADisplayLink?
    private var savedMemojiRecord: NSObject?
    
    func start() {
        guard ARFaceTrackingConfiguration.isSupported else {
            debugStatus = "❌ Face tracking not supported"
            return
        }
        
        debugStatus = "Requesting camera permission..."
        print("📷 Requesting camera permission...")
        
        // Explicitly request camera permission before starting ARSession
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    print("✅ Camera permission granted")
                    self.debugStatus = "Camera granted, starting AR..."
                    self.startTracking()
                } else {
                    print("❌ Camera permission denied")
                    self.debugStatus = "❌ Camera permission denied — go to Settings"
                }
            }
        }
    }
    
    private func startTracking() {
        kit = HumanSenseKit(enableHandGestures: false, enableSTT: false)
        kit?.start()
        
        debugStatus = "HumanSenseKit started"
        print("✅ HumanSenseKit started")
        
        let link = CADisplayLink(target: self, selector: #selector(update))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }
    
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        kit?.stop()
    }
    
    // MARK: - Switching
    
    func switchToAnimoji(_ name: String) {
        currentAnimoji = name
        isMemoji = false
        bridge.loadAnimoji(name)
    }
    
    func switchToMemoji() {
        isMemoji = true
        bridge.loadMemoji()
    }
    
    func switchPose(_ pose: String) {
        currentPose = pose
        bridge.applyBodySticker(pose)
    }
    
    // MARK: - Memoji Creator
    
    func presentMemojiCreator() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }
        
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        
        memojiEditor.presentCreator(from: topVC) { [weak self] record in
            guard let self, let record else { return }
            self.savedMemojiRecord = record
            self.isMemoji = true
            self.loadSavedMemoji(record)
        }
    }
    
    private func loadSavedMemoji(_ record: NSObject) {
        let avatarSel = NSSelectorFromString("avatar")
        if record.responds(to: avatarSel),
           let avatar = record.perform(avatarSel)?.takeUnretainedValue() as? NSObject {
            if let avtView = bridge.avtView {
                avtView.perform(NSSelectorFromString("setAvatar:"), with: avatar)
                print("✅ Loaded saved memoji")
            }
        }
    }
    
    // MARK: - Update Loop
    
    private var frameCount = 0
    
    @objc private func update() {
        guard let kit = kit else { return }
        kit.state.update()
        
        let wasTracking = isTracking
        isTracking = kit.state.isPresent
        
        if isTracking != wasTracking {
            print("🔄 Tracking: \(wasTracking) → \(isTracking)")
        }
        
        frameCount += 1
        if frameCount % 300 == 0 {
            let hasAnchor = kit.currentFaceAnchor != nil
            debugStatus = "F\(frameCount) | present=\(isTracking) | anchor=\(hasAnchor)"
            print("📊 \(debugStatus)")
        }
        
        if let anchor = kit.currentFaceAnchor {
            bridge.applyFaceAnchor(anchor)
        }
    }
}
