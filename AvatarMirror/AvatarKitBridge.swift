import Foundation
import ARKit

/// Bridge between ARKit face tracking and Apple's private AvatarKit framework.
@MainActor
final class AvatarKitBridge {
    
    enum AvatarType {
        case animoji(String)  // name like "tiger", "cat"
        case memoji           // random memoji with body
    }
    
    // MARK: - Private AvatarKit references
    private(set) var avtView: NSObject?
    private var avatar: NSObject?
    private var currentType: AvatarType = .animoji("tiger")
    private var frameworkLoaded = false
    
    // MARK: - ARKit blendshape order (matches AvatarKit's 51 indices)
    static let arkitBlendShapeOrder: [ARFaceAnchor.BlendShapeLocation] = [
        .eyeBlinkLeft, .eyeBlinkRight, .eyeSquintLeft, .eyeSquintRight,
        .eyeLookDownLeft, .eyeLookDownRight, .eyeLookInLeft, .eyeLookInRight,
        .eyeWideLeft, .eyeWideRight, .eyeLookOutLeft, .eyeLookOutRight,
        .eyeLookUpLeft, .eyeLookUpRight,
        .browDownLeft, .browDownRight, .browInnerUp, .browOuterUpLeft, .browOuterUpRight,
        .jawOpen, .mouthClose, .jawLeft, .jawRight, .jawForward,
        .mouthUpperUpLeft, .mouthUpperUpRight, .mouthLowerDownLeft, .mouthLowerDownRight,
        .mouthRollUpper, .mouthRollLower, .mouthSmileLeft, .mouthSmileRight,
        .mouthDimpleLeft, .mouthDimpleRight, .mouthStretchLeft, .mouthStretchRight,
        .mouthFrownLeft, .mouthFrownRight, .mouthPressLeft, .mouthPressRight,
        .mouthPucker, .mouthFunnel, .mouthLeft, .mouthRight,
        .mouthShrugLower, .mouthShrugUpper, .noseSneerLeft, .noseSneerRight,
        .cheekPuff, .cheekSquintLeft, .cheekSquintRight,
    ]
    
    // MARK: - Tracking data struct
    struct TrackingData {
        var timestamp: Double = 0
        var isTracking: Bool = true
        var blendShapes: (
            Float,Float,Float,Float,Float,Float,Float,Float,Float,Float,
            Float,Float,Float,Float,Float,Float,Float,Float,Float,Float,
            Float,Float,Float,Float,Float,Float,Float,Float,Float,Float,
            Float,Float,Float,Float,Float,Float,Float,Float,Float,Float,
            Float,Float,Float,Float,Float,Float,Float,Float,Float,Float,
            Float
        ) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        var parameters: (
            Float,Float,Float,Float,Float,Float,Float,Float,Float,Float,
            Float,Float,Float,Float,Float,Float,Float,Float,Float,Float,
            Float,Float,Float,Float,Float,Float,Float,Float,Float,Float,
            Float,Float,Float,Float,Float,Float,Float,Float,Float,Float,
            Float,Float,Float,Float,Float,Float,Float,Float,Float,Float,
            Float
        ) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        var extra: (Float, Float) = (0, 0)
    }
    
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
    
    func createView(frame: CGRect) -> UIView? {
        guard ensureFramework() else { return nil }
        
        guard let avtViewClass = NSClassFromString("AVTView") as? UIView.Type else {
            print("❌ AVTView not found")
            return nil
        }
        
        let view = avtViewClass.init(frame: frame)
        self.avtView = view as? NSObject
        
        setBool(on: view, selector: "setRendersContinuously:", value: true)
        
        if let bgSel = NSSelectorFromString("setBackgroundColor:") as Selector?,
           view.responds(to: bgSel) {
            view.perform(bgSel, with: UIColor.clear)
        }
        
        return view
    }
    
    // MARK: - Avatar Loading
    
    func loadAnimoji(_ name: String) {
        guard ensureFramework() else { return }
        guard let cls = NSClassFromString("AVTAnimoji") else { return }
        
        let sel = NSSelectorFromString("initWithName:error:")
        guard let instance = cls.alloc() as? NSObject, instance.responds(to: sel) else { return }
        
        let result = instance.perform(sel, with: name, with: nil)?.takeUnretainedValue() as? NSObject
        self.avatar = result
        self.currentType = .animoji(name)
        
        avtView?.perform(NSSelectorFromString("setAvatar:"), with: result)
        print("✅ Loaded animoji: \(name)")
    }
    
    func loadMemoji() {
        guard ensureFramework() else { return }
        guard let cls = NSClassFromString("AVTMemoji") else { return }
        
        guard let instance = cls.alloc() as? NSObject else { return }
        instance.perform(NSSelectorFromString("randomize"))
        
        self.avatar = instance
        self.currentType = .memoji
        
        avtView?.perform(NSSelectorFromString("setAvatar:"), with: instance)
        print("✅ Loaded random memoji")
        
        // Apply a body sticker for full-body view
        applyBodySticker("person_waving")
    }
    
    func applyBodySticker(_ stickerName: String) {
        guard let avtView = avtView else { return }
        guard let stickerCfgCls = NSClassFromString("AVTStickerConfiguration") else { return }
        
        // Try stickers pack first, then posesPack
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
        
        // transitionToStickerConfiguration:duration:completionHandler:
        let transSel = NSSelectorFromString("transitionToStickerConfiguration:duration:completionHandler:")
        guard avtView.responds(to: transSel) else { return }
        
        let sig = avtView.method(for: transSel)
        typealias TransFunc = @convention(c) (NSObject, Selector, NSObject, Double, AnyObject?) -> Void
        let fn = unsafeBitCast(sig, to: TransFunc.self)
        fn(avtView, transSel, stickerCfg, 0.3, nil)
        
        print("✅ Applied body sticker: \(stickerName)")
    }
    
    // MARK: - Face Tracking
    
    func applyFaceAnchor(_ anchor: ARFaceAnchor) {
        guard let avatar = self.avatar else { return }
        
        var data = TrackingData()
        data.timestamp = CACurrentMediaTime()
        data.isTracking = true
        
        withUnsafeMutablePointer(to: &data.blendShapes) { ptr in
            let floatPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Float.self)
            for (i, location) in Self.arkitBlendShapeOrder.enumerated() {
                floatPtr[i] = anchor.blendShapes[location]?.floatValue ?? 0
            }
        }
        
        guard let trackInfoCls = NSClassFromString("AVTFaceTrackingInfo") else { return }
        
        withUnsafePointer(to: &data) { dataPtr in
            let trackInfo = invokeClassMethod(
                cls: trackInfoCls,
                selector: "trackingInfoWithTrackingData:",
                pointerArg: dataPtr
            )
            guard let info = trackInfo else { return }
            
            avatar.perform(NSSelectorFromString("applyBlendShapesWithTrackingInfo:"), with: info)
            avatar.perform(NSSelectorFromString("applyHeadPoseWithTrackingInfo:"), with: info)
        }
    }
    
    // MARK: - Available Content
    
    static let availableAnimoji = [
        "alien", "bear", "boar", "cat", "chicken", "cow",
        "dog", "dragon", "fox", "ghost", "giraffe", "koala",
        "lion", "monkey", "mouse", "octopus", "owl", "panda",
        "pig", "poo", "rabbit", "robot", "shark", "skull",
        "tiger", "trex", "unicorn"
    ]
    
    static let memojiBodyStickers = [
        "callMe", "beKind", "person_waving", "thumbs_up",
        "face_with_tears_of_joy", "smiling_face_with_heart-shaped_eyes",
        "exploding_head", "sleeping_face"
    ]
    
    static let memojiBodyPoses = [
        "yearbook", "hands_on_hips", "head_tilt", "happy", "wink",
        "grizzled", "one_raised_eyebrow", "tongue_out", "pursed_lips",
        "pleasant_neutral", "proud", "surprise", "front_pucker",
        "big_happy", "annoyed"
    ]
    
    // MARK: - Helpers
    
    private func setBool(on obj: NSObject, selector: String, value: Bool) {
        let sel = NSSelectorFromString(selector)
        guard obj.responds(to: sel) else { return }
        let method = class_getInstanceMethod(type(of: obj), sel)!
        let imp = method_getImplementation(method)
        typealias SetBoolFunc = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(imp, to: SetBoolFunc.self)(obj, sel, value)
    }
    
    private func invokeClassMethod(cls: AnyClass, selector: String, pointerArg: UnsafeRawPointer) -> NSObject? {
        let sel = NSSelectorFromString(selector)
        guard let method = class_getClassMethod(cls, sel) else { return nil }
        let imp = method_getImplementation(method)
        typealias Func = @convention(c) (AnyClass, Selector, UnsafeRawPointer) -> NSObject?
        return unsafeBitCast(imp, to: Func.self)(cls, sel, pointerArg)
    }
}
