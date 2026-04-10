import Foundation
import ARKit

/// Bridge between ARKit face tracking and Apple's private AvatarKit framework.
@MainActor
final class AvatarKitBridge {
    
    private(set) var avtView: NSObject? // AVTRecordView (SCNView subclass)
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
    
    /// Create an AVTRecordView (SCNView subclass with built-in recording support)
    func createView(frame: CGRect) -> UIView? {
        guard ensureFramework() else { return nil }
        
        guard let viewClass = NSClassFromString("AVTRecordView") as? UIView.Type else {
            print("❌ AVTRecordView not found")
            return nil
        }
        
        let view = viewClass.init(frame: frame)
        self.avtView = view as? NSObject
        view.backgroundColor = .clear
        
        // Enable continuous rendering
        let renderSel = NSSelectorFromString("setRendersContinuously:")
        if let obj = view as? NSObject, obj.responds(to: renderSel) {
            let method = class_getInstanceMethod(type(of: obj), renderSel)!
            let imp = method_getImplementation(method)
            typealias Func = @convention(c) (NSObject, Selector, Bool) -> Void
            unsafeBitCast(imp, to: Func.self)(obj, renderSel, true)
        }
        
        print("✅ Created AVTRecordView")
        return view
    }
    
    // MARK: - Face Tracking
    
    /// Start face tracking using AVTView's built-in transitionToCustomFaceTracking
    func startFaceTracking() {
        guard let view = avtView else { return }
        
        // Method 1: transitionToCustomFaceTrackingWithDuration:style:enableBakedAnimations:faceTrackingDidStartHandlerReceiverBlock:completionHandler:
        let trackingSel = NSSelectorFromString("transitionToCustomFaceTrackingWithDuration:style:enableBakedAnimations:faceTrackingDidStartHandlerReceiverBlock:completionHandler:")
        
        if view.responds(to: trackingSel),
           let method = class_getInstanceMethod(type(of: view), trackingSel) {
            let imp = method_getImplementation(method)
            
            // duration: Double, style: Int, enableBakedAnimations: Bool, 
            // faceTrackingDidStartHandlerReceiverBlock: block, completionHandler: block
            typealias Func = @convention(c) (
                NSObject, Selector,
                Double,     // duration
                Int,        // style
                Bool,       // enableBakedAnimations
                AnyObject?, // faceTrackingDidStartHandlerReceiverBlock
                AnyObject?  // completionHandler
            ) -> Void
            
            let fn = unsafeBitCast(imp, to: Func.self)
            
            let startBlock: @convention(block) (AnyObject?) -> Void = { handler in
                print("✅ Face tracking did start!")
            }
            
            let completionBlock: @convention(block) () -> Void = {
                print("✅ Face tracking transition complete")
            }
            
            fn(view, trackingSel, 0.3, 0, true, startBlock as AnyObject, completionBlock as AnyObject)
            print("✅ transitionToCustomFaceTracking called")
            return
        }
        
        // Method 2: Fallback to startPreviewing
        let previewSel = NSSelectorFromString("startPreviewing")
        if view.responds(to: previewSel) {
            view.perform(previewSel)
            print("✅ startPreviewing called (fallback)")
        }
    }
    
    func stopFaceTracking() {
        guard let view = avtView else { return }
        let sel = NSSelectorFromString("stopPreviewing")
        if view.responds(to: sel) {
            view.perform(sel)
        }
    }
    
    // MARK: - Avatar Loading
    
    func loadAnimoji(_ name: String) {
        guard ensureFramework() else { return }
        guard let cls = NSClassFromString("AVTAnimoji") else {
            print("❌ AVTAnimoji not found")
            return
        }
        
        // Use +animojiNamed: class method
        let sel = NSSelectorFromString("animojiNamed:")
        guard let meta = object_getClass(cls),
              class_getClassMethod(meta, sel) != nil else {
            print("❌ +animojiNamed: not found, trying initWithName:error:")
            loadAnimojiFallback(name)
            return
        }
        
        let result = (cls as AnyObject).perform(sel, with: name)
        guard let animoji = result?.takeUnretainedValue() as? NSObject else {
            print("❌ animojiNamed returned nil for: \(name)")
            return
        }
        
        self.avatar = animoji
        avtView?.setValue(animoji, forKeyPath: "avatar")
        print("✅ Loaded animoji via animojiNamed: \(name)")
    }
    
    private func loadAnimojiFallback(_ name: String) {
        guard let cls = NSClassFromString("AVTAnimoji") else { return }
        
        let allocSel = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(cls, allocSel) else { return }
        let allocImp = method_getImplementation(allocMethod)
        typealias AllocFunc = @convention(c) (AnyClass, Selector) -> NSObject
        let instance = unsafeBitCast(allocImp, to: AllocFunc.self)(cls, allocSel)
        
        let initSel = NSSelectorFromString("initWithName:error:")
        guard instance.responds(to: initSel),
              let method = class_getInstanceMethod(type(of: instance), initSel) else { return }
        
        let imp = method_getImplementation(method)
        typealias InitFunc = @convention(c) (NSObject, Selector, NSString, UnsafeMutablePointer<NSObject?>?) -> NSObject?
        
        var error: NSObject?
        guard let animoji = unsafeBitCast(imp, to: InitFunc.self)(instance, initSel, name as NSString, &error) else { return }
        
        self.avatar = animoji
        avtView?.setValue(animoji, forKeyPath: "avatar")
        print("✅ Loaded animoji via initWithName: \(name)")
    }
    
    func loadMemoji() {
        guard ensureFramework() else { return }
        guard let cls = NSClassFromString("AVTMemoji") else { return }
        
        // Try +neutralMemoji first
        let neutralSel = NSSelectorFromString("neutralMemoji")
        if let meta = object_getClass(cls),
           class_getClassMethod(meta, neutralSel) != nil,
           let result = (cls as AnyObject).perform(neutralSel),
           let memoji = result.takeUnretainedValue() as? NSObject {
            self.avatar = memoji
            avtView?.setValue(memoji, forKeyPath: "avatar")
            print("✅ Loaded neutral memoji")
            return
        }
        
        // Fallback: alloc+init+randomize
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
        if memoji.responds(to: randomSel) { memoji.perform(randomSel) }
        
        self.avatar = memoji
        avtView?.setValue(memoji, forKeyPath: "avatar")
        print("✅ Loaded random memoji")
    }
    
    // MARK: - Manual face tracking (if built-in doesn't work)
    
    func applyFaceAnchor(_ anchor: ARFaceAnchor) {
        guard let avatar = self.avatar else { return }
        guard let trackInfoCls = NSClassFromString("AVTFaceTrackingInfo") else { return }
        
        // Try trackingInfoWithFaceAnchor: first (if available)
        let anchorSel = NSSelectorFromString("trackingInfoWithFaceAnchor:")
        if let meta = object_getClass(trackInfoCls),
           class_getClassMethod(meta, anchorSel) != nil {
            let result = (trackInfoCls as AnyObject).perform(anchorSel, with: anchor)
            if let info = result?.takeUnretainedValue() as? NSObject {
                avatar.perform(NSSelectorFromString("applyBlendShapesWithTrackingInfo:"), with: info)
                avatar.perform(NSSelectorFromString("applyHeadPoseWithTrackingInfo:"), with: info)
                return
            }
        }
        
        // Fallback: trackingInfoWithTrackingData: with raw buffer
        applyViaRawTrackingData(anchor: anchor, avatar: avatar, trackInfoCls: trackInfoCls)
    }
    
    private func applyViaRawTrackingData(anchor: ARFaceAnchor, avatar: NSObject, trackInfoCls: AnyClass) {
        let sel = NSSelectorFromString("trackingInfoWithTrackingData:")
        guard let method = class_getClassMethod(trackInfoCls, sel) else { return }
        let imp = method_getImplementation(method)
        
        // Build raw tracking data buffer
        // Layout based on runtime analysis: Double(8) + Bool as UInt8(1) + pad(3) + 51 floats + 51 floats + 2 floats = 428 bytes
        var buffer = [UInt8](repeating: 0, count: 428)
        
        buffer.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            
            var ts = CACurrentMediaTime()
            memcpy(base, &ts, 8)
            base.storeBytes(of: UInt8(1), toByteOffset: 8, as: UInt8.self)
            
            let order: [ARFaceAnchor.BlendShapeLocation] = [
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
            
            for (i, loc) in order.enumerated() {
                var val = anchor.blendShapes[loc]?.floatValue ?? 0
                memcpy(base + 12 + i * 4, &val, 4)
                memcpy(base + 216 + i * 4, &val, 4)
            }
        }
        
        buffer.withUnsafeBytes { raw in
            typealias Func = @convention(c) (AnyClass, Selector, UnsafeRawPointer) -> NSObject?
            let fn = unsafeBitCast(imp, to: Func.self)
            guard let info = fn(trackInfoCls, sel, raw.baseAddress!) else { return }
            
            avatar.perform(NSSelectorFromString("applyBlendShapesWithTrackingInfo:"), with: info)
            avatar.perform(NSSelectorFromString("applyHeadPoseWithTrackingInfo:"), with: info)
        }
    }
    
    // MARK: - Available Content
    
    static let availableAnimoji: [String] = {
        dlopen("/System/Library/PrivateFrameworks/AvatarKit.framework/AvatarKit", RTLD_LAZY)
        if let cls = NSClassFromString("AVTAnimoji"),
           let names = (cls as AnyObject).value(forKeyPath: "animojiNames") as? [String] {
            return names
        }
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
