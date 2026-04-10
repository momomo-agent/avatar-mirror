import SwiftUI
import ARKit
import AVFoundation
import HumanSenseKit

@MainActor
final class AvatarMirrorViewModel: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isTracking = false
    @Published var currentAnimoji = "tiger"
    @Published var isMemoji = false
    @Published var debugStatus = "Starting..."
    @Published var useHumanSenseKit = true // Toggle between HumanSenseKit and built-in
    
    let bridge = AvatarKitBridge()
    let memojiEditor = MemojiEditorBridge()
    
    // HumanSenseKit for external tracking
    private var kit: HumanSenseKit?
    private var displayLink: CADisplayLink?
    
    // Direct ARSession as fallback
    private var arSession: ARSession?
    
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
        
        if useHumanSenseKit {
            startHumanSenseKitTracking()
        } else {
            bridge.startBuiltInTracking()
            debugStatus = "Built-in tracking"
        }
    }
    
    // MARK: - HumanSenseKit Tracking
    
    private func startHumanSenseKitTracking() {
        bridge.startExternalTracking()
        
        kit = HumanSenseKit(enableHandGestures: false, enableSTT: false)
        kit?.start()
        
        debugStatus = "HumanSenseKit tracking"
        print("✅ HumanSenseKit started for external tracking")
        
        // Display link to poll HumanSenseKit state
        let link = CADisplayLink(target: self, selector: #selector(updateFromHSK))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }
    
    private var frameCount = 0
    
    @objc private func updateFromHSK() {
        guard let kit = kit else { return }
        kit.state.update()
        
        isTracking = kit.state.isPresent
        
        frameCount += 1
        if frameCount % 300 == 0 {
            let hasAnchor = kit.currentFaceAnchor != nil
            debugStatus = "HSK | present=\(isTracking) | anchor=\(hasAnchor)"
        }
        
        if let anchor = kit.currentFaceAnchor {
            bridge.applyFaceAnchor(anchor)
        }
    }
    
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        kit?.stop()
        kit = nil
        bridge.stopTracking()
        arSession?.pause()
        arSession = nil
    }
    
    // MARK: - Toggle Tracking Mode
    
    func toggleTrackingMode() {
        stop()
        useHumanSenseKit.toggle()
        onViewReady()
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
