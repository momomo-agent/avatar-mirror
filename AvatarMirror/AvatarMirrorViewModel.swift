import SwiftUI
import ARKit
import HumanSenseKit

@MainActor
final class AvatarMirrorViewModel: ObservableObject {
    @Published var isTracking = false
    @Published var currentAnimoji = "tiger"
    @Published var isMemoji = false
    @Published var currentPose = "person_waving"
    @Published var showingMemojiCreator = false
    
    let bridge = AvatarKitBridge()
    let memojiEditor = MemojiEditorBridge()
    private var kit: HumanSenseKit?
    private var displayLink: CADisplayLink?
    
    // Saved memoji record for re-use
    private var savedMemojiRecord: NSObject?
    
    func start() {
        kit = HumanSenseKit(enableHandGestures: false, enableSTT: false)
        kit?.start()
        
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
        
        // Find the topmost presented VC
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        
        memojiEditor.presentCreator(from: topVC) { [weak self] record in
            guard let self, let record else { return }
            self.savedMemojiRecord = record
            self.isMemoji = true
            // The saved record can be used to load the custom memoji
            // For now, apply it through the bridge
            self.loadSavedMemoji(record)
        }
    }
    
    private func loadSavedMemoji(_ record: NSObject) {
        // AVTAvatarRecord has an avatar property
        let avatarSel = NSSelectorFromString("avatar")
        if record.responds(to: avatarSel),
           let avatar = record.perform(avatarSel)?.takeUnretainedValue() as? NSObject {
            // Set this avatar on the AVTView
            if let avtView = bridge.avtView {
                avtView.perform(NSSelectorFromString("setAvatar:"), with: avatar)
                print("✅ Loaded saved memoji")
            }
        }
    }
    
    // MARK: - Update Loop
    
    @objc private func update() {
        guard let kit = kit else { return }
        kit.state.update()
        isTracking = kit.state.isPresent
        
        if let anchor = kit.currentFaceAnchor {
            bridge.applyFaceAnchor(anchor)
        }
    }
}
