import SwiftUI
import ARKit
import AVFoundation

@MainActor
final class AvatarMirrorViewModel: NSObject, ObservableObject {
    @Published var isTracking = false
    @Published var currentAnimoji = "tiger"
    @Published var isMemoji = false
    @Published var currentPose = "person_waving"
    @Published var debugStatus = "Starting..."
    
    let bridge = AvatarKitBridge()
    let memojiEditor = MemojiEditorBridge()
    
    private var savedMemojiRecord: NSObject?
    
    func start() {
        guard ARFaceTrackingConfiguration.isSupported else {
            debugStatus = "❌ Face tracking not supported"
            return
        }
        
        debugStatus = "Requesting camera..."
        
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.debugStatus = "Camera OK"
                    // AVTRecordView.startPreviewing will be called after view is created
                } else {
                    self.debugStatus = "❌ Camera denied"
                }
            }
        }
    }
    
    /// Called by the view representable once AVTRecordView is created and laid out
    func onViewReady() {
        bridge.loadAnimoji(currentAnimoji)
        
        // Start face tracking — AVTRecordView handles ARSession internally
        bridge.startPreviewing()
        debugStatus = "Previewing..."
        
        // Monitor tracking state via KVO on the record view
        if let view = bridge.recordView {
            let previewingSel = NSSelectorFromString("isPreviewing")
            if view.responds(to: previewingSel) {
                let isPreviewing = (view.perform(previewingSel)?.toOpaque() != nil)
                debugStatus = isPreviewing ? "✅ Previewing" : "⚠️ Preview not started"
                print("📊 isPreviewing: \(isPreviewing)")
            }
        }
    }
    
    func stop() {
        bridge.stopPreviewing()
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
            bridge.recordView?.setValue(avatar, forKeyPath: "avatar")
            print("✅ Loaded saved memoji")
        }
    }
}
