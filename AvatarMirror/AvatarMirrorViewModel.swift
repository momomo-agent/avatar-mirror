import SwiftUI
import ARKit
import AVFoundation

@MainActor
final class AvatarMirrorViewModel: NSObject, ObservableObject {
    @Published var isTracking = false
    @Published var currentAnimoji = "tiger"
    @Published var isMemoji = false
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
                self.debugStatus = granted ? "Camera OK" : "❌ Camera denied"
            }
        }
    }
    
    /// Called by the view representable once AVTRecordView is created
    func onViewReady() {
        bridge.loadAnimoji(currentAnimoji)
        
        // Use ONLY the built-in face tracking — no backup ARSession
        // Two ARSessions fighting over the camera causes FigCaptureSourceRemote errors
        bridge.startFaceTracking()
        isTracking = true
        debugStatus = "Tracking"
    }
    
    func stop() {
        bridge.stopFaceTracking()
        isTracking = false
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
            let avatarSel = NSSelectorFromString("avatar")
            if record.responds(to: avatarSel),
               let avatar = record.perform(avatarSel)?.takeUnretainedValue() as? NSObject {
                self.bridge.avtView?.setValue(avatar, forKeyPath: "avatar")
            }
        }
    }
}
