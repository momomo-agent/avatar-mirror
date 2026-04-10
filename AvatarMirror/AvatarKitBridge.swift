import Foundation
import ARKit

/// Bridge between ARKit face tracking and Apple's private AvatarKit framework.
@MainActor
final class AvatarKitBridge {
    
    enum AvatarType {
        case animoji(String)
        case memoji
    }
    
    private(set) var avtView: NSObject?
    private var avatar: NSObject?
    private var currentType: AvatarType = .animoji("tiger")
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
    
    func createView(frame: CGRect) -> UIView? {
        guard ensureFramework() else { return nil }
        
        guard let avtViewClass = NSClassFromString("AVTView") as? UIView.Type else {
            print("❌ AVTView not found")
            return nil
        }
        
        let view = avtViewClass.init(frame: frame)
        self.avtView = view as? NSObject
        
        setBool(on: view, selector: "setRendersContinuously:", value: true)
        view.backgroundColor = .clear
        
        return view
    }
    
    // MARK: - Avatar Loading
    
    func loadAnimoji(_ name: String) {
        guard ensureFramework() else { return }
        guard let cls = NSClassFromString("AVTAnimoji") else {
            print("❌ AVTAnimoji not found")
            return
        }
        
        let allocSel = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(cls, allocSel) else { return }
        let allocImp = method_getImplementation(allocMethod)
        typealias AllocFunc = @convention(c) (AnyClass, Selector) -> NSObject
        let instance = unsafeBitCast(allocImp, to: AllocFunc.self)(cls, allocSel)
        
        let initSel = NSSelectorFromString("initWithName:error:")
        guard instance.responds(to: initSel),
              let method = class_getInstanceMethod(type(of: instance), initSel) else {
            print("❌ initWithName:error: not found")
            return
        }
        
        let imp = method_getImplementation(method)
        typealias InitFunc = @convention(c) (NSObject, Selector, NSString, UnsafeMutablePointer<NSObject?>?) -> NSObject?
        let initFn = unsafeBitCast(imp, to: InitFunc.self)
        
        var error: NSObject?
        let result = initFn(instance, initSel, name as NSString, &error)
        
        if let error = error {
            print("❌ Animoji init error: \(error)")
            return
        }
        
        guard let animoji = result else {
            print("❌ Animoji init returned nil for: \(name)")
            return
        }
        
        self.avatar = animoji
        self.currentType = .animoji(name)
        
        avtView?.perform(NSSelectorFromString("setAvatar:"), with: animoji)
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
        self.currentType = .memoji
        
        avtView?.perform(NSSelectorFromString("setAvatar:"), with: memoji)
        print("✅ Loaded random memoji")
    }
    
    func applyBodySticker(_ stickerName: String) {
        guard let avtView = avtView else { return }
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
        guard avtView.responds(to: transSel) else { return }
        
        let sig = avtView.method(for: transSel)
        typealias TransFunc = @convention(c) (NSObject, Selector, NSObject, Double, AnyObject?) -> Void
        let fn = unsafeBitCast(sig, to: TransFunc.self)
        fn(avtView, transSel, stickerCfg, 0.3, nil)
        
        print("✅ Applied body sticker: \(stickerName)")
    }
    
    // MARK: - Face Tracking (direct ARFaceAnchor → AVTPuppet)
    
    func applyFaceAnchor(_ anchor: ARFaceAnchor) {
        guard let avatar = self.avatar else { return }
        
        // Method 1: Try using AVTAvatarInstance's built-in ARKit integration
        // AVTAnimoji/AVTAvatar should have applyBlendShapes: that takes a dictionary
        let dictSel = NSSelectorFromString("applyBlendShapes:")
        if avatar.responds(to: dictSel) {
            // Convert ARFaceAnchor blendShapes to the format AvatarKit expects
            avatar.perform(dictSel, with: anchor.blendShapes)
        }
        
        // Method 2: Apply head transform via the puppet
        let puppetSel = NSSelectorFromString("puppet")
        if avatar.responds(to: puppetSel),
           let puppet = avatar.perform(puppetSel)?.takeUnretainedValue() as? NSObject {
            
            // Try applyBlendShapesFromFaceAnchor: on puppet
            let anchorSel = NSSelectorFromString("applyBlendShapesFromFaceAnchor:")
            if puppet.responds(to: anchorSel) {
                puppet.perform(anchorSel, with: anchor)
                return
            }
            
            // Try setBlendShapesDictionary: on puppet
            let bsSel = NSSelectorFromString("setBlendShapesDictionary:")
            if puppet.responds(to: bsSel) {
                puppet.perform(bsSel, with: anchor.blendShapes)
            }
            
            // Apply head rotation via transform
            let transformSel = NSSelectorFromString("setHeadTransform:")
            if puppet.responds(to: transformSel) {
                var transform = anchor.transform
                withUnsafePointer(to: &transform) { ptr in
                    let method = class_getInstanceMethod(type(of: puppet), transformSel)!
                    let imp = method_getImplementation(method)
                    typealias Func = @convention(c) (NSObject, Selector, UnsafeRawPointer) -> Void
                    unsafeBitCast(imp, to: Func.self)(puppet, transformSel, ptr)
                }
            }
        }
        
        // Method 3: Fallback — use AVTFaceTrackingInfo with correct C struct layout
        applyViaTrackingInfo(anchor: anchor)
    }
    
    private func applyViaTrackingInfo(anchor: ARFaceAnchor) {
        guard let avatar = self.avatar else { return }
        guard let trackInfoCls = NSClassFromString("AVTFaceTrackingInfo") else { return }
        
        // Build the tracking data as a flat C-compatible buffer
        // Layout: Double timestamp, UInt8 isTracking, [padding to 4-byte], 51 Float blendShapes, 51 Float parameters, 2 Float extra
        // Total: 8 + 1 + 3(pad) + 204 + 204 + 8 = 428 bytes
        var buffer = [UInt8](repeating: 0, count: 428)
        
        buffer.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            
            // timestamp (offset 0, 8 bytes)
            var ts = CACurrentMediaTime()
            memcpy(base, &ts, 8)
            
            // isTracking (offset 8, 1 byte)
            base.storeBytes(of: UInt8(1), toByteOffset: 8, as: UInt8.self)
            
            // blendShapes (offset 12, 51 * 4 = 204 bytes)
            let blendShapeOrder: [ARFaceAnchor.BlendShapeLocation] = [
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
            
            for (i, location) in blendShapeOrder.enumerated() {
                var val = anchor.blendShapes[location]?.floatValue ?? 0
                memcpy(base + 12 + i * 4, &val, 4)
            }
            
            // parameters (offset 216, 51 * 4 = 204 bytes) — copy same as blendShapes
            for (i, location) in blendShapeOrder.enumerated() {
                var val = anchor.blendShapes[location]?.floatValue ?? 0
                memcpy(base + 216 + i * 4, &val, 4)
            }
        }
        
        // Create AVTFaceTrackingInfo from buffer
        let sel = NSSelectorFromString("trackingInfoWithTrackingData:")
        guard let method = class_getClassMethod(trackInfoCls, sel) else { return }
        let imp = method_getImplementation(method)
        
        buffer.withUnsafeBytes { raw in
            typealias Func = @convention(c) (AnyClass, Selector, UnsafeRawPointer) -> NSObject?
            let fn = unsafeBitCast(imp, to: Func.self)
            guard let info = fn(trackInfoCls, sel, raw.baseAddress!) else { return }
            
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
}
