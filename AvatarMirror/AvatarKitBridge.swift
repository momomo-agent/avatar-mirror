import Foundation
import ARKit

/// Bridge between ARKit face tracking and Apple's private AvatarKit framework.
/// Uses AVTRecordView which handles its own ARSession + face tracking internally.
@MainActor
final class AvatarKitBridge {
    
    private(set) var recordView: NSObject? // AVTRecordView (subclass of SCNView)
    private var avatar: NSObject?
    private var frameworkLoaded = false
    
    // MARK: - Setup
    
    private func ensureFramework() -> Bool {
        if frameworkLoaded { return true }
        let handle = dlopen("/System/Library/PrivateFrameworks/AvatarKit.framework/AvatarKit", RTLD_LAZY)
        frameworkLoaded = handle != nil
        if !frameworkLoaded {
            print("❌ Failed to load AvatarKit: \(String(cString: dlerror()))")
        }
        return frameworkLoaded
    }
    
    /// Create an AVTRecordView — it's a SCNView subclass that handles face tracking internally.
    func createView(frame: CGRect) -> UIView? {
        guard ensureFramework() else { return nil }
        
        // Use AVTRecordView — it manages its own ARSession for face tracking
        guard let recordViewClass = NSClassFromString("AVTRecordView") as? UIView.Type else {
            print("❌ AVTRecordView not found, falling back to AVTView")
            return createBasicView(frame: frame)
        }
        
        let view = recordViewClass.init(frame: frame)
        self.recordView = view as? NSObject
        view.backgroundColor = .clear
        
        print("✅ Created AVTRecordView (SCNView subclass)")
        return view
    }
    
    private func createBasicView(frame: CGRect) -> UIView? {
        guard let avtViewClass = NSClassFromString("AVTView") as? UIView.Type else {
            print("❌ AVTView not found")
            return nil
        }
        let view = avtViewClass.init(frame: frame)
        self.recordView = view as? NSObject
        view.backgroundColor = .clear
        return view
    }
    
    /// Start face tracking preview — AVTRecordView handles ARSession internally
    func startPreviewing() {
        guard let view = recordView else { return }
        let sel = NSSelectorFromString("startPreviewing")
        if view.responds(to: sel) {
            view.perform(sel)
            print("✅ startPreviewing called — AVTRecordView now tracking face")
        } else {
            print("⚠️ startPreviewing not available")
        }
    }
    
    /// Stop face tracking preview
    func stopPreviewing() {
        guard let view = recordView else { return }
        let sel = NSSelectorFromString("stopPreviewing")
        if view.responds(to: sel) {
            view.perform(sel)
            print("✅ stopPreviewing called")
        }
    }
    
    // MARK: - Avatar Loading
    
    func loadAnimoji(_ name: String) {
        guard ensureFramework() else { return }
        guard let cls = NSClassFromString("AVTAnimoji") else {
            print("❌ AVTAnimoji not found")
            return
        }
        
        // Use +animojiNamed: class method (the correct way)
        let sel = NSSelectorFromString("animojiNamed:")
        guard let meta = object_getClass(cls),
              class_getClassMethod(meta, sel) != nil else {
            print("❌ +animojiNamed: not found")
            return
        }
        
        let result = (cls as AnyObject).perform(sel, with: name)
        guard let animoji = result?.takeUnretainedValue() as? NSObject else {
            print("❌ animojiNamed returned nil for: \(name)")
            return
        }
        
        self.avatar = animoji
        
        // Set avatar on the view via KVC (how SBSAnimoji does it)
        recordView?.setValue(animoji, forKeyPath: "avatar")
        print("✅ Loaded animoji: \(name)")
    }
    
    func loadMemoji() {
        guard ensureFramework() else { return }
        guard let cls = NSClassFromString("AVTMemoji") else { return }
        
        let allocSel = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(cls, allocSel) else { return }
        let allocImp = method_getImplementation(allocMethod)
        typealias AllocFunc = @convention(c) (AnyClass, Selector) -> NSObject
        let instance = unsafeBitCast(allocImp, to: AllocFunc.self)(cls, allocSel)
        
        let initSel = NSSelectorFromString("init")
        guard let initMethod = class_getInstanceMethod(type(of: instance), initSel) else { return }
        let initImp = method_getImplementation(initMethod)
        typealias InitFunc = @convention(c) (NSObject, Selector) -> NSObject?
        guard let memoji = unsafeBitCast(initImp, to: InitFunc.self)(instance, initSel) else { return }
        
        let randomSel = NSSelectorFromString("randomize")
        if memoji.responds(to: randomSel) {
            memoji.perform(randomSel)
        }
        
        self.avatar = memoji
        recordView?.setValue(memoji, forKeyPath: "avatar")
        print("✅ Loaded random memoji")
    }
    
    func applyBodySticker(_ stickerName: String) {
        guard let view = recordView else { return }
        guard let stickerCfgCls = NSClassFromString("AVTStickerConfiguration") else { return }
        
        var cfg: NSObject?
        for pack in ["stickers", "posesPack"] {
            let sel = NSSelectorFromString("stickerConfigurationForMemojiInStickerPack:stickerName:")
            if let result = (stickerCfgCls as? NSObject.Type)?.perform(sel, with: pack, with: stickerName) {
                cfg = result.takeUnretainedValue() as? NSObject
                if cfg != nil { break }
            }
        }
        
        guard let stickerCfg = cfg else {
            print("❌ Sticker \(stickerName) not found")
            return
        }
        
        let transSel = NSSelectorFromString("transitionToStickerConfiguration:duration:completionHandler:")
        guard view.responds(to: transSel) else { return }
        
        let sig = view.method(for: transSel)
        typealias TransFunc = @convention(c) (NSObject, Selector, NSObject, Double, AnyObject?) -> Void
        let fn = unsafeBitCast(sig, to: TransFunc.self)
        fn(view, transSel, stickerCfg, 0.3, nil)
        
        print("✅ Applied body sticker: \(stickerName)")
    }
    
    // MARK: - Available Content
    
    static let availableAnimoji: [String] = {
        // Try to get from AvatarKit at runtime
        dlopen("/System/Library/PrivateFrameworks/AvatarKit.framework/AvatarKit", RTLD_LAZY)
        if let cls = NSClassFromString("AVTAnimoji"),
           let names = (cls as AnyObject).value(forKeyPath: "animojiNames") as? [String] {
            return names
        }
        // Fallback
        return [
            "alien", "bear", "boar", "cat", "chicken", "cow",
            "dog", "dragon", "fox", "ghost", "giraffe", "koala",
            "lion", "monkey", "mouse", "octopus", "owl", "panda",
            "pig", "poo", "rabbit", "robot", "shark", "skull",
            "tiger", "trex", "unicorn"
        ]
    }()
    
    static let memojiBodyPoses = [
        "yearbook", "hands_on_hips", "head_tilt", "happy", "wink",
        "grizzled", "one_raised_eyebrow", "tongue_out", "pursed_lips",
        "pleasant_neutral", "proud", "surprise", "front_pucker",
        "big_happy", "annoyed"
    ]
}
