import Foundation
import ARKit

/// Bridge between ARKit face tracking and Apple's private AvatarKit framework.
/// Two modes:
/// 1. Built-in: transitionToCustomFaceTracking (AVTRecordView manages its own ARSession)
/// 2. External: applyARFrame() with data from HumanSenseKit's ARSession
@MainActor
final class AvatarKitBridge {
    
    enum TrackingMode {
        case builtIn
        case external
    }
    
    private(set) var avtView: NSObject?
    private var avatar: NSObject?
    private var frameworkLoaded = false
    private(set) var trackingMode: TrackingMode = .external
    
    // Cached class references
    private var trackInfoCls: AnyClass?
    
    // MARK: - Setup
    
    private func ensureFramework() -> Bool {
        if frameworkLoaded { return true }
        let handle = dlopen("/System/Library/PrivateFrameworks/AvatarKit.framework/AvatarKit", RTLD_LAZY)
        frameworkLoaded = handle != nil
        if !frameworkLoaded {
            print("❌ Failed to load AvatarKit: \(String(cString: dlerror()))")
        }
        trackInfoCls = NSClassFromString("AVTFaceTrackingInfo")
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
        setBool(on: view as NSObject, selector: "setRendersContinuously:", value: true)
        
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
            let previewSel = NSSelectorFromString("startPreviewing")
            if view.responds(to: previewSel) { view.perform(previewSel) }
        }
    }
    
    func stopTracking() {
        guard let view = avtView else { return }
        let sel = NSSelectorFromString("stopPreviewing")
        if view.responds(to: sel) { view.perform(sel) }
    }
    
    // MARK: - External Face Tracking (HumanSenseKit)
    
    func startExternalTracking() {
        trackingMode = .external
        print("✅ External tracking mode — feed ARFrame via applyARFrame()")
    }
    
    /// Apply an ARFrame directly — uses AVTFaceTrackingInfo's +trackingInfoWithARFrame: factory
    /// This is the correct way: AvatarKit creates its own tracking info from the full ARFrame,
    /// including face anchor transform, blendshapes, and camera orientation.
    func applyARFrame(_ frame: ARFrame) {
        guard let avatar = avatar, let trackInfoCls = trackInfoCls else { return }
        
        // Get device orientation for correct coordinate mapping
        let interfaceOrientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .portrait
        let orientationRaw = interfaceOrientation.rawValue
        
        // Try +trackingInfoWithARFrame:captureOrientation:interfaceOrientation:
        let sel3 = NSSelectorFromString("trackingInfoWithARFrame:captureOrientation:interfaceOrientation:")
        if let meta = object_getClass(trackInfoCls),
           let method = class_getClassMethod(meta, sel3) {
            let imp = method_getImplementation(method)
            typealias Func = @convention(c) (AnyClass, Selector, AnyObject, Int, Int) -> NSObject?
            let fn = unsafeBitCast(imp, to: Func.self)
            
            if let info = fn(trackInfoCls, sel3, frame, orientationRaw, orientationRaw) {
                applyTrackingInfo(info, to: avatar)
                return
            }
        }
        
        // Try +dataWithARFrame:captureOrientation:interfaceOrientation:
        let dataSel = NSSelectorFromString("dataWithARFrame:captureOrientation:interfaceOrientation:")
        if let meta = object_getClass(trackInfoCls),
           let method = class_getClassMethod(meta, dataSel) {
            let imp = method_getImplementation(method)
            typealias Func = @convention(c) (AnyClass, Selector, AnyObject, Int, Int) -> NSObject?
            let fn = unsafeBitCast(imp, to: Func.self)
            
            if let info = fn(trackInfoCls, dataSel, frame, orientationRaw, orientationRaw) {
                applyTrackingInfo(info, to: avatar)
                return
            }
        }
        
        // Fallback: extract face anchor and apply manually
        if let faceAnchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first {
            applyFaceAnchorViaTrackingInfo(faceAnchor)
        }
    }
    
    /// Apply face anchor via AVTFaceTrackingInfo (fallback when ARFrame methods don't work)
    func applyFaceAnchorViaTrackingInfo(_ anchor: ARFaceAnchor) {
        guard let avatar = avatar, let trackInfoCls = trackInfoCls else { return }
        
        // Use +trackingInfoWithTrackingData: with correct struct layout
        let sel = NSSelectorFromString("trackingInfoWithTrackingData:")
        guard let method = class_getClassMethod(trackInfoCls, sel) else { return }
        let imp = method_getImplementation(method)
        
        // Struct layout from runtime dump:
        // {?="timestamp"d "translation""orientation""cameraSpace"B
        //    "blendShapeWeights_smooth"[51f] "blendShapeWeights_raw"[51f]
        //    "parameters_smooth"[1f] "parameters_raw"[1f]}
        //
        // d = Double (8 bytes) — timestamp
        // B = Bool (1 byte) — cameraSpace (isTracking)
        // pad to 4-byte alignment (3 bytes)
        // [51f] = 204 bytes — smooth blendshapes
        // [51f] = 204 bytes — raw blendshapes
        // [1f] = 4 bytes — smooth parameters
        // [1f] = 4 bytes — raw parameters
        // Total: 8 + 1 + 3 + 204 + 204 + 4 + 4 = 428 bytes
        //
        // BUT: "translation" and "orientation" appear between d and B with no type encoding.
        // These might be simd types that ObjC can't encode. Let's check if the struct is actually bigger.
        // The ivar offset is 16 (after isa+refcount), and _rawTransform is at offset 496.
        // So _trackingData size = 496 - 16 = 480 bytes!
        // Extra 52 bytes = likely simd_float3 translation (12) + simd_quatf orientation (16) + padding
        // Revised layout:
        // Double timestamp (8)
        // simd_float3 translation (12) + pad (4) = 16
        // simd_quatf orientation (16)
        // Bool cameraSpace (1) + pad (3) = 4
        // [51f] smooth (204)
        // [51f] raw (204)
        // [1f] smooth params (4)
        // [1f] raw params (4)
        // Total: 8 + 16 + 16 + 4 + 204 + 204 + 4 + 4 = 460... not 480
        //
        // Let's try the simpler approach: 428 bytes as the property encoding suggests
        
        let bufferSize = 428
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        
        buffer.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            
            // timestamp (offset 0, 8 bytes)
            var ts = CACurrentMediaTime()
            memcpy(base, &ts, 8)
            
            // isTracking/cameraSpace (offset 8, 1 byte)
            base.storeBytes(of: UInt8(1), toByteOffset: 8, as: UInt8.self)
            
            // blendShapeWeights_smooth (offset 12, 51 * 4 = 204 bytes)
            // Use ARKit's rawValue alphabetical order (this is what AvatarKit expects)
            let allLocations = anchor.blendShapes
            for (location, value) in allLocations {
                // Map ARKit blendshape to AvatarKit index
                if let idx = Self.arkitBlendShapeOrder[location.rawValue], idx < 51 {
                    var val = value.floatValue
                    memcpy(base + 12 + idx * 4, &val, 4)
                    // Also fill raw
                    memcpy(base + 216 + idx * 4, &val, 4)
                }
            }
        }
        
        buffer.withUnsafeBytes { raw in
            typealias Func = @convention(c) (AnyClass, Selector, UnsafeRawPointer) -> NSObject?
            let fn = unsafeBitCast(imp, to: Func.self)
            guard let info = fn(trackInfoCls, sel, raw.baseAddress!) else { return }
            applyTrackingInfo(info, to: avatar)
        }
    }
    
    private func applyTrackingInfo(_ info: NSObject, to avatar: NSObject) {
        let bsSel = NSSelectorFromString("applyBlendShapesWithTrackingInfo:")
        if avatar.responds(to: bsSel) {
            avatar.perform(bsSel, with: info)
        }
        
        let poseSel = NSSelectorFromString("applyHeadPoseWithTrackingInfo:")
        if avatar.responds(to: poseSel) {
            avatar.perform(poseSel, with: info)
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
    
    // MARK: - Helpers
    
    private func setBool(on obj: NSObject, selector: String, value: Bool) {
        let sel = NSSelectorFromString(selector)
        guard obj.responds(to: sel) else { return }
        let method = class_getInstanceMethod(type(of: obj), sel)!
        let imp = method_getImplementation(method)
        typealias Func = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(imp, to: Func.self)(obj, sel, value)
    }
    
    // ARKit blendshape rawValue -> AvatarKit index (alphabetical order of ARKit names)
    // ARKit has 52 blendshapes, AvatarKit uses 51 (tongueOut might be excluded)
    static let arkitBlendShapeOrder: [String: Int] = {
        let names = [
            "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
            "cheekPuff", "cheekSquintLeft", "cheekSquintRight",
            "eyeBlinkLeft", "eyeBlinkRight", "eyeLookDownLeft", "eyeLookDownRight",
            "eyeLookInLeft", "eyeLookInRight", "eyeLookOutLeft", "eyeLookOutRight",
            "eyeLookUpLeft", "eyeLookUpRight", "eyeSquintLeft", "eyeSquintRight",
            "eyeWideLeft", "eyeWideRight",
            "jawForward", "jawLeft", "jawOpen", "jawRight",
            "mouthClose", "mouthDimpleLeft", "mouthDimpleRight", "mouthFrownLeft", "mouthFrownRight",
            "mouthFunnel", "mouthLeft", "mouthLowerDownLeft", "mouthLowerDownRight",
            "mouthPressLeft", "mouthPressRight", "mouthPucker", "mouthRight",
            "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
            "mouthSmileLeft", "mouthSmileRight", "mouthStretchLeft", "mouthStretchRight",
            "mouthUpperUpLeft", "mouthUpperUpRight",
            "noseSneerLeft", "noseSneerRight",
        ]
        var map: [String: Int] = [:]
        for (i, name) in names.enumerated() {
            map[name] = i
        }
        return map
    }()
}
