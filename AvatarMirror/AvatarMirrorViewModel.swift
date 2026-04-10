import SwiftUI
import ARKit
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
        // Check ARKit support first
        guard ARFaceTrackingConfiguration.isSupported else {
            debugStatus = "❌ Face tracking not supported on this device"
            print(debugStatus)
            bridge.loadAnimoji(currentAnimoji)
            return
        }
        
        debugStatus = "ARKit supported, starting..."
        print("✅ ARFaceTrackingConfiguration.isSupported = true")
        
        kit = HumanSenseKit(enableHandGestures: false, enableSTT: false)
        kit?.start()
        
        debugStatus = "HumanSenseKit started"
        print("✅ HumanSenseKit started")
        
        let link = CADisplayLink(target: self, selector: #selector(update))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
        
        bridge.loadAnimoji(currentAnimoji)
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
        
        // Log state changes
        if isTracking != wasTracking {
            print("🔄 Tracking changed: \(wasTracking) → \(isTracking)")
        }
        
        // Periodic debug log
        frameCount += 1
        if frameCount % 300 == 0 { // Every ~5 seconds at 60fps
            let hasAnchor = kit.currentFaceAnchor != nil
            debugStatus = "Frame \(frameCount) | isPresent=\(isTracking) | anchor=\(hasAnchor)"
            print("📊 \(debugStatus)")
        }
        
        if let anchor = kit.currentFaceAnchor {
            bridge.applyFaceAnchor(anchor)
        }
    }
}
