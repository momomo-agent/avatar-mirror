import SwiftUI
import ARKit

@MainActor
final class AvatarMirrorViewModel: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isTracking = false
    @Published var currentAnimoji = "tiger"
    @Published var isMemoji = false
    @Published var currentPose = "person_waving"
    
    let bridge = AvatarKitBridge()
    let memojiEditor = MemojiEditorBridge()
    
    private var arSession: ARSession?
    private var savedMemojiRecord: NSObject?
    
    func start() {
        guard ARFaceTrackingConfiguration.isSupported else {
            print("⚠️ Face tracking not supported on this device")
            // Still load the animoji for display
            bridge.loadAnimoji(currentAnimoji)
            return
        }
        
        let session = ARSession()
        session.delegate = self
        self.arSession = session
        
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        session.run(config)
        
        bridge.loadAnimoji(currentAnimoji)
    }
    
    func stop() {
        arSession?.pause()
        arSession = nil
    }
    
    // MARK: - ARSessionDelegate
    
    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let faceAnchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }
        Task { @MainActor in
            isTracking = faceAnchor.isTracked
            bridge.applyFaceAnchor(faceAnchor)
        }
    }
    
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        print("❌ AR session failed: \(error)")
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
}
