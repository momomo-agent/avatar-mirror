import Foundation
import ARKit

/// Bridge between ARKit face tracking and Apple's private AvatarKit framework.
/// Two modes:
/// 1. Built-in: transitionToCustomFaceTracking (AVTRecordView manages its own ARSession)
/// 2. External: applyFaceAnchor() with data from HumanSenseKit
@MainActor
final class AvatarKitBridge {
    
    enum TrackingMode {
        case builtIn    // AVTRecordView manages ARSession
        case external   // We feed ARFaceAnchor data manually
    }
    
    private(set) var avtView: NSObject? // AVTRecordView (SCNView subclass)
    private var avatar: NSObject?
    private var frameworkLoaded = false
    private(set) var trackingMode: TrackingMode = .external
    
    // Cached blendshape index mapping: ARKit name -> AvatarKit index
    private var blendShapeIndexMap: [String: Int] = [:]
    private var blendShapeCount: Int = 51
    
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
        
        guard let viewClass = NSClassFromString("AVTRecordView") as? UIView.Type else {
            print("❌ AVTRecordView not found")
            return nil
        }
        
        let view = viewClass.init(frame: frame)
        self.avtView = view as? NSObject
        view.backgroundColor = .clear
        
        // Enable continuous rendering for manual updates
        let renderSel = NSSelectorFromString("setRendersContinuously:")
        if (view as NSObject).responds(to: renderSel) {
            let method = class_getInstanceMethod(type(of: view as NSObject), renderSel)!
            let imp = method_getImplementation(method)
            typealias Func = @convention(c) (NSObject, Selector, Bool) -> Void
            unsafeBitCast(imp, to: Func.self)(view as NSObject, renderSel, true)
        }
        
        print("✅ Created AVTRecordView")
        return view
    }
    
    // MARK: - Built-in Face Tracking
    
    func startBuiltInTracking() {
        guard let view = avtView else { return }
        trackingMode = .builtIn
        
        let sel = NSSelectorFromString("transitionToCustomFaceTrackingWithDuration:style:enableBakedAnimations:faceTrackingDidStartHandlerReceiverBlock:completionHandler:")
        if view.responds(to: sel),
           let method = class_getInstanceMethod(type(of: view), sel) {
            let imp = method_getImplementation(method)
            typealias Func = @convention(c) (NSObject, Selector, Double, Int, Bool, AnyObject?, AnyObject?) -> Void
            let fn = unsafeBitCast(imp, to: Func.self)
            
            let startBlock: @convention(block) (AnyObject?) -> Void = { _ in
                print("✅ Built-in face tracking started")
            }
            let completionBlock: @convention(block) () -> Void = {
                print("✅ Built-in face tracking transition complete")
            }
            fn(view, sel, 0.3, 0, true, startBlock as AnyObject, completionBlock as AnyObject)
        } else {
            // Fallback to startPreviewing
            let previewSel = NSSelectorFromString("startPreviewing")
            if view.responds(to: previewSel) {
                view.perform(previewSel)
                print("✅ startPreviewing (fallback)")
            }
        }
    }
    
    func stopTracking() {
        guard let view = avtView else { return }
        let sel = NSSelectorFromString("stopPreviewing")
        if view.responds(to: sel) { view.perform(sel) }
    }
    
    // MARK: - External Face Tracking (HumanSenseKit data)
    
    func startExternalTracking() {
        trackingMode = .external
        print("✅ External tracking mode — waiting for ARFaceAnchor data")
    }
    
    /// Build the blendshape index mapping by querying the avatar
    private func buildBlendShapeMapping() {
        guard let avatar = avatar else { return }
        
        let sel = NSSelectorFromString("blendShapeIndexForARKitBlendShapeName:")
        guard avatar.responds(to: sel),
              let method = class_getInstanceMethod(type(of: avatar), sel) else {
            print("⚠️ blendShapeIndexForARKitBlendShapeName: not available")
            return
        }
        
        let imp = method_getImplementation(method)
        typealias Func = @convention(c) (NSObject, Selector, NSString) -> Int
        let fn = unsafeBitCast(imp, to: Func.self)
        
        let arkitNames: [ARFaceAnchor.BlendShapeLocation] = [
            .browDownLeft, .browDownRight, .browInnerUp, .browOuterUpLeft, .browOuterUpRight,
            .cheekPuff, .cheekSquintLeft, .cheekSquintRight,
            .eyeBlinkLeft, .eyeBlinkRight, .eyeLookDownLeft, .eyeLookDownRight,
            .eyeLookInLeft, .eyeLookInRight, .eyeLookOutLeft, .eyeLookOutRight,
            .eyeLookUpLeft, .eyeLookUpRight, .eyeSquintLeft, .eyeSquintRight,
            .eyeWideLeft, .eyeWideRight,
            .jawForward, .jawLeft, .jawOpen, .jawRight,
            .mouthClose, .mouthDimpleLeft, .mouthDimpleRight, .mouthFrownLeft, .mouthFrownRight,
            .mouthFunnel, .mouthLeft, .mouthLowerDownLeft, .mouthLowerDownRight,
            .mouthPressLeft, .mouthPressRight, .mouthPucker, .mouthRight,
            .mouthRollLower, .mouthRollUpper, .mouthShrugLower, .mouthShrugUpper,
            .mouthSmileLeft, .mouthSmileRight, .mouthStretchLeft, .mouthStretchRight,
            .mouthUpperUpLeft, .mouthUpperUpRight,
            .noseSneerLeft, .noseSneerRight,
            .tongueOut
        ]
        
        blendShapeIndexMap.removeAll()
        for location in arkitNames {
            let name = location.rawValue
            let index = fn(avatar, sel, name as NSString)
            if index >= 0 {
                blendShapeIndexMap[name] = index
            }
        }
        
        print("✅ Built blendshape mapping: \(blendShapeIndexMap.count) entries")
        if let maxIdx = blendShapeIndexMap.values.max() {
            blendShapeCount = maxIdx + 1
            print("   Max index: \(maxIdx), count: \(blendShapeCount)")
        }
    }
    
    /// Apply face anchor data from HumanSenseKit to the avatar
    func applyFaceAnchor(_ anchor: ARFaceAnchor) {
        guard let avatar = avatar else { return }
        
        // Method 1: Use _applyBlendShapes:parameters: with correct index mapping
        let applySel = NSSelectorFromString("_applyBlendShapes:parameters:")
        if avatar.responds(to: applySel), !blendShapeIndexMap.isEmpty {
            var blendShapes = [Float](repeating: 0, count: blendShapeCount)
            
            for (name, value) in anchor.blendShapes {
                if let index = blendShapeIndexMap[name.rawValue] {
                    blendShapes[index] = value.floatValue
                }
            }
            
            let method = class_getInstanceMethod(type(of: avatar), applySel)!
            let imp = method_getImplementation(method)
            typealias Func = @convention(c) (NSObject, Selector, UnsafePointer<Float>, UnsafePointer<Float>) -> Void
            let fn = unsafeBitCast(imp, to: Func.self)
            
            blendShapes.withUnsafeBufferPointer { bsPtr in
                // parameters = same as blendshapes for now (1 element but pass full array)
                fn(avatar, applySel, bsPtr.baseAddress!, bsPtr.baseAddress!)
            }
        }
        
        // Method 2: Apply head pose via _applyHeadPoseWithTrackingData:gazeCorrection:pointOfView:
        let poseSel = NSSelectorFromString("_applyHeadPoseWithTrackingData:gazeCorrection:pointOfView:")
        if avatar.responds(to: poseSel) {
            // Build tracking data with head transform from ARFaceAnchor
            applyHeadPose(anchor: anchor, avatar: avatar)
        }
    }
    
    private func applyHeadPose(anchor: ARFaceAnchor, avatar: NSObject) {
        // The tracking data struct: Double(timestamp) + Bool(isTracking) + pad + [51f] + [51f] + [1f] + [1f]
        // But for head pose, the key data is the transform matrix from ARFaceAnchor
        
        // Try applyHeadPoseWithTrackingInfo: which uses AVTFaceTrackingInfo
        let infoSel = NSSelectorFromString("applyHeadPoseWithTrackingInfo:")
        guard avatar.responds(to: infoSel) else { return }
        guard let trackInfoCls = NSClassFromString("AVTFaceTrackingInfo") else { return }
        
        // Build TrackingData buffer matching the struct layout: dB[51f][51f][1f][1f]
        // d = Double timestamp (8 bytes)
        // B = Bool isTracking (1 byte) + 3 bytes padding
        // [51f] = smooth blendshapes (204 bytes)
        // [51f] = raw blendshapes (204 bytes)
        // [1f] = smooth parameters (4 bytes)
        // [1f] = raw parameters (4 bytes)
        // Total = 8 + 4 + 204 + 204 + 4 + 4 = 428 bytes
        
        var buffer = [UInt8](repeating: 0, count: 428)
        
        buffer.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            
            // timestamp
            var ts = CACurrentMediaTime()
            memcpy(base, &ts, 8)
            
            // isTracking
            base.storeBytes(of: UInt8(1), toByteOffset: 8, as: UInt8.self)
            
            // Fill blendshapes using correct index mapping
            for (name, value) in anchor.blendShapes {
                if let index = blendShapeIndexMap[name.rawValue], index < 51 {
                    var val = value.floatValue
                    // smooth
                    memcpy(base + 12 + index * 4, &val, 4)
                    // raw
                    memcpy(base + 216 + index * 4, &val, 4)
                }
            }
        }
        
        // Create AVTFaceTrackingInfo
        let createSel = NSSelectorFromString("trackingInfoWithTrackingData:")
        guard let createMethod = class_getClassMethod(trackInfoCls, createSel) else { return }
        let createImp = method_getImplementation(createMethod)
        
        buffer.withUnsafeBytes { raw in
            typealias CreateFunc = @convention(c) (AnyClass, Selector, UnsafeRawPointer) -> NSObject?
            let fn = unsafeBitCast(createImp, to: CreateFunc.self)
            guard let info = fn(trackInfoCls, createSel, raw.baseAddress!) else { return }
            
            // Apply both blendshapes and head pose via tracking info
            avatar.perform(NSSelectorFromString("applyBlendShapesWithTrackingInfo:"), with: info)
            avatar.perform(NSSelectorFromString("applyHeadPoseWithTrackingInfo:"), with: info)
        }
    }
    
    // MARK: - Avatar Loading
    
    func loadAnimoji(_ name: String) {
        guard ensureFramework() else { return }
        guard let cls = NSClassFromString("AVTAnimoji") else {
            print("❌ AVTAnimoji not found")
            return
        }
        
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
        avtView?.setValue(animoji, forKeyPath: "avatar")
        
        // Build blendshape mapping for this avatar
        buildBlendShapeMapping()
        
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
        if memoji.responds(to: randomSel) { memoji.perform(randomSel) }
        
        self.avatar = memoji
        avtView?.setValue(memoji, forKeyPath: "avatar")
        buildBlendShapeMapping()
        print("✅ Loaded random memoji")
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
}
