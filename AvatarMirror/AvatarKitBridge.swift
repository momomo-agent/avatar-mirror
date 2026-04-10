import Foundation
import ARKit

/// Bridge between ARKit face tracking and Apple's private AvatarKit framework.
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
    
    private var trackInfoCls: AnyClass?
    private var frameCount = 0
    private var lastFrame: ARFrame?
    
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
        
        setBool(on: view as NSObject, selector: "setRendersContinuously:", value: true)
        
        // Diagnose: check if world was created
        let worldSel = NSSelectorFromString("world")
        if let nsView = view as? NSObject, nsView.responds(to: worldSel) {
            let world = nsView.perform(worldSel)?.takeUnretainedValue()
            print("🔍 AVTRecordView.world = \(String(describing: world))")
        } else {
            print("🔍 AVTRecordView does not respond to 'world'")
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
        }
    }
    
    func stopTracking() {
        guard let view = avtView else { return }
        // Stop any internal ARSession
        let sel = NSSelectorFromString("stopPreviewing")
        if view.responds(to: sel) { view.perform(sel) }
    }
    
    // MARK: - External Face Tracking
    
    func startExternalTracking() {
        trackingMode = .external
        // IMPORTANT: Do NOT call startPreviewing or transitionToCustomFaceTracking
        // We manage our own ARSession — AVTRecordView must not start its own
        print("✅ External tracking mode — no internal ARSession")
    }
    
    /// Apply an ARFrame from our own ARSession
    func applyARFrame(_ frame: ARFrame) {
        guard let avatar = avatar, let trackInfoCls = trackInfoCls else { return }
        
        self.lastFrame = frame
        frameCount += 1
        let shouldLog = frameCount <= 10 || frameCount % 300 == 0
        
        let faceAnchors = frame.anchors.compactMap { $0 as? ARFaceAnchor }
        guard let faceAnchor = faceAnchors.first else { return }
        
        let interfaceOrientationRaw = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation.rawValue ?? 1
        let captureOrientationRaw = 4 // front camera sensor = landscapeRight
        
        if shouldLog {
            let bs = faceAnchor.blendShapes
            print("🎯 Frame #\(frameCount): jawOpen=\(bs[.jawOpen]?.floatValue ?? -1)")
        }
        
        // Strategy: use trackingInfo for BLENDSHAPES only, apply head pose separately
        var blendShapesApplied = false
        
        // Try dataWithARFrame → trackingInfoWithTrackingData → applyBlendShapes
        if let meta = object_getClass(trackInfoCls) {
            let dataSel = NSSelectorFromString("dataWithARFrame:captureOrientation:interfaceOrientation:")
            if let method = class_getClassMethod(meta, dataSel) {
                let imp = method_getImplementation(method)
                typealias Func = @convention(c) (AnyClass, Selector, AnyObject, Int, Int) -> NSObject?
                let fn = unsafeBitCast(imp, to: Func.self)
                
                if let data = fn(trackInfoCls, dataSel, frame, captureOrientationRaw, interfaceOrientationRaw) {
                    // data is NSData — convert to trackingInfo
                    let infoSel = NSSelectorFromString("trackingInfoWithTrackingData:")
                    if let nsData = data as? Data,
                       let infoMethod = class_getClassMethod(meta, infoSel) {
                        let infoImp = method_getImplementation(infoMethod)
                        nsData.withUnsafeBytes { rawBuf in
                            typealias InfoFunc = @convention(c) (AnyClass, Selector, UnsafeRawPointer) -> NSObject?
                            let infoFn = unsafeBitCast(infoImp, to: InfoFunc.self)
                            if let info = infoFn(trackInfoCls, infoSel, rawBuf.baseAddress!) {
                                let bsSel = NSSelectorFromString("applyBlendShapesWithTrackingInfo:")
                                if avatar.responds(to: bsSel) {
                                    avatar.perform(bsSel, with: info)
                                    blendShapesApplied = true
                                    if shouldLog { print("   ✅ blendshapes via trackingInfo") }
                                }
                            }
                        }
                    }
                    // Maybe data responds to trackingData (is already a trackingInfo)
                    if !blendShapesApplied {
                        let tdSel = NSSelectorFromString("trackingData")
                        if data.responds(to: tdSel) {
                            let bsSel = NSSelectorFromString("applyBlendShapesWithTrackingInfo:")
                            if avatar.responds(to: bsSel) {
                                avatar.perform(bsSel, with: data)
                                blendShapesApplied = true
                                if shouldLog { print("   ✅ blendshapes via trackingInfo (direct)") }
                            }
                        }
                    }
                }
            }
        }
        
        if !blendShapesApplied {
            if shouldLog { print("   ⚠️ blendshapes fallback not implemented yet") }
        }
        
        // HEAD POSE: always apply directly from ARFaceAnchor
        // applyHeadPoseWithTrackingInfo flips 180° in external mode, so we do it ourselves
        applyHeadPose(from: faceAnchor, log: shouldLog)
    }
    
    private func applyTrackingInfo(_ info: NSObject, to avatar: NSObject, log: Bool) {
        let bsSel = NSSelectorFromString("applyBlendShapesWithTrackingInfo:")
        if avatar.responds(to: bsSel) {
            avatar.perform(bsSel, with: info)
            if log { print("   → applyBlendShapes ✅") }
        }
    }
    
    /// Apply head pose using AvatarKit's own applyHeadPoseWithTrackingInfo method
    /// or fall back to direct node manipulation
    private func applyHeadPose(from anchor: ARFaceAnchor, log: Bool) {
        guard let avatar = avatar else { return }
        
        // Check avatarNode.world — required by applyHeadPoseWithTrackingInfo
        let avatarNodeSel = NSSelectorFromString("avatarNode")
        if log {
            if avatar.responds(to: avatarNodeSel),
               let avatarNode = avatar.perform(avatarNodeSel)?.takeUnretainedValue() as? NSObject {
                let worldSel = NSSelectorFromString("world")
                if avatarNode.responds(to: worldSel) {
                    let world = avatarNode.perform(worldSel)?.takeUnretainedValue()
                    print("   🔍 avatarNode.world = \(String(describing: world))")
                }
            }
        }
        
        // Strategy: Use AvatarKit's own trackingInfo-based head pose method.
        // Build trackingInfo from ARFrame data, then call applyHeadPoseWithTrackingInfo:
        guard let trackInfoCls = trackInfoCls else {
            if log { print("   → headPose: no trackInfoCls") }
            return
        }
        
        // Use dataWithARFrame:captureOrientation:interfaceOrientation: to build proper tracking data
        // This is what AvatarKit uses internally
        let dataFromFrameSel = NSSelectorFromString("dataWithARFrame:captureOrientation:interfaceOrientation:")
        guard let meta = object_getClass(trackInfoCls),
              let method = class_getClassMethod(meta, dataFromFrameSel) else {
            if log { print("   → headPose: dataWithARFrame: not found, trying manual") }
            applyHeadPoseManual(from: anchor, to: avatar, log: log)
            return
        }
        
        // We need the ARFrame, not just the anchor
        // The ARFrame is stored in lastFrame by the ARSession delegate
        guard let frame = lastFrame else {
            if log { print("   → headPose: no lastFrame available") }
            return
        }
        
        let imp = method_getImplementation(method)
        // captureOrientation: 1 = portrait, interfaceOrientation: 1 = portrait
        typealias DataFunc = @convention(c) (AnyClass, Selector, ARFrame, Int, Int) -> NSObject?
        let dataFn = unsafeBitCast(imp, to: DataFunc.self)
        guard let data = dataFn(trackInfoCls, dataFromFrameSel, frame, 1, 1) else {
            if log { print("   → headPose: dataWithARFrame returned nil") }
            return
        }
        
        // Now create trackingInfo from data
        let infoSel = NSSelectorFromString("trackingInfoWithTrackingData:")
        guard let infoMethod = class_getClassMethod(meta, infoSel) else {
            if log { print("   → headPose: trackingInfoWithTrackingData: not found") }
            return
        }
        let infoImp = method_getImplementation(infoMethod)
        typealias InfoFunc = @convention(c) (AnyClass, Selector, NSObject) -> NSObject?
        let infoFn = unsafeBitCast(infoImp, to: InfoFunc.self)
        guard let info = infoFn(trackInfoCls, infoSel, data) else {
            if log { print("   → headPose: trackingInfoWithTrackingData returned nil") }
            return
        }
        
        // Call applyHeadPoseWithTrackingInfo:gazeCorrection:pointOfView:
        let poseSel = NSSelectorFromString("applyHeadPoseWithTrackingInfo:gazeCorrection:pointOfView:")
        if avatar.responds(to: poseSel),
           let poseMethod = class_getInstanceMethod(type(of: avatar), poseSel) {
            let poseImp = method_getImplementation(poseMethod)
            typealias PoseFunc = @convention(c) (NSObject, Selector, NSObject, Bool, NSObject?) -> Void
            let poseFn = unsafeBitCast(poseImp, to: PoseFunc.self)
            poseFn(avatar, poseSel, info, false, nil)
            if log { print("   → headPose via applyHeadPoseWithTrackingInfo ✅") }
        } else {
            if log { print("   → headPose: applyHeadPoseWithTrackingInfo not available") }
        }
    }
    
    /// Fallback: direct node manipulation
    private func applyHeadPoseManual(from anchor: ARFaceAnchor, to avatar: NSObject, log: Bool) {
        let avatarNodeSel = NSSelectorFromString("avatarNode")
        guard avatar.responds(to: avatarNodeSel),
              let avatarNode = avatar.perform(avatarNodeSel)?.takeUnretainedValue() as? NSObject else {
            if log { print("   → headPose manual: avatar.avatarNode not available") }
            return
        }
        
        let findSel = NSSelectorFromString("childNodeWithName:recursively:")
        guard avatarNode.responds(to: findSel) else { return }
        
        let headJointName = "head_JNT" as NSString
        guard let headJoint = avatarNode.perform(findSel, with: headJointName, with: NSNumber(value: true))?.takeUnretainedValue() as? NSObject else {
            if log { print("   → headPose manual: head_JNT not found") }
            return
        }
        
        let setOrientationSel = NSSelectorFromString("setSimdOrientation:")
        if headJoint.responds(to: setOrientationSel),
           let method = class_getInstanceMethod(type(of: headJoint), setOrientationSel) {
            let imp = method_getImplementation(method)
            typealias Func = @convention(c) (NSObject, Selector, simd_quatf) -> Void
            let fn = unsafeBitCast(imp, to: Func.self)
            fn(headJoint, setOrientationSel, simd_quatf(anchor.transform))
        }
        
        if log { print("   → headPose manual via head_JNT ✅") }
    }
    
    /// Manual fallback: build TrackingData struct and create AVTFaceTrackingInfo
    private func applyFaceAnchorManually(_ anchor: ARFaceAnchor, to avatar: NSObject, log: Bool) {
        guard let trackInfoCls = trackInfoCls else { return }
        
        // From the runtime dump, the ivar type encoding is:
        // {?="timestamp"d"translation""orientation""cameraSpace"B
        //   "blendShapeWeights_smooth"[51f]"blendShapeWeights_raw"[51f]
        //   "parameters_smooth"[1f]"parameters_raw"[1f]}
        //
        // _trackingData offset=16, _rawTransform offset=496
        // So struct size = 496 - 16 = 480 bytes
        //
        // Layout (480 bytes):
        // 0:   Double timestamp (8)
        // 8:   simd_float3 translation (12) — from "translation" field name
        // 20:  padding (4) to align to 16
        // 24:  simd_quatf orientation (16) — from "orientation" field name  
        // 40:  Bool cameraSpace (1) + padding (3)
        // 44:  [51f] blendShapeWeights_smooth (204)
        // 248: [51f] blendShapeWeights_raw (204)
        // 452: [1f] parameters_smooth (4)
        // 456: [1f] parameters_raw (4)
        // 460: padding to 480? Or maybe translation/orientation are bigger
        //
        // Actually let's try the property encoding: dB[51f][51f][1f][1f] = 428 bytes
        // And also try 480 bytes
        // The safest approach: use the property encoding (428) first
        
        let bufferSize = 480 // match ivar size (496 - 16)
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        
        buffer.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            
            // timestamp (offset 0)
            var ts = CACurrentMediaTime()
            memcpy(base, &ts, 8)
            
            // translation from face anchor transform (offset 8, simd_float3 = 12 bytes)
            // Mirror X for front camera (selfie mirror effect)
            var translation = simd_float3(
                -anchor.transform.columns.3.x,  // mirror X
                anchor.transform.columns.3.y,
                anchor.transform.columns.3.z
            )
            memcpy(base + 8, &translation, 12)
            
            // orientation from face anchor transform (offset 24, simd_quatf = 16 bytes)
            // Mirror around Y axis: negate x and z components of quaternion
            let q = simd_quatf(anchor.transform)
            var orientation = simd_quatf(ix: -q.imag.x, iy: q.imag.y, iz: -q.imag.z, r: q.real)
            memcpy(base + 24, &orientation, 16)
            
            // cameraSpace = true (offset 40)
            base.storeBytes(of: UInt8(1), toByteOffset: 40, as: UInt8.self)
            
            // blendShapeWeights_smooth (offset 44, 51 * 4 = 204 bytes)
            for (location, value) in anchor.blendShapes {
                if let idx = Self.arkitBlendShapeOrder[location.rawValue], idx < 51 {
                    var val = value.floatValue
                    memcpy(base + 44 + idx * 4, &val, 4)
                    // raw = same
                    memcpy(base + 248 + idx * 4, &val, 4)
                }
            }
        }
        
        // Create AVTFaceTrackingInfo from our manually built struct
        let sel = NSSelectorFromString("trackingInfoWithTrackingData:")
        guard let meta = object_getClass(trackInfoCls),
              let method = class_getClassMethod(meta, sel) else {
            if log { print("   ❌ trackingInfoWithTrackingData: not found") }
            return
        }
        
        let imp = method_getImplementation(method)
        buffer.withUnsafeBytes { rawBuf in
            typealias Func = @convention(c) (AnyClass, Selector, UnsafeRawPointer) -> NSObject?
            let fn = unsafeBitCast(imp, to: Func.self)
            guard let info = fn(trackInfoCls, sel, rawBuf.baseAddress!) else {
                if log { print("   ❌ trackingInfoWithTrackingData returned nil") }
                return
            }
            if log { print("   ✅ Manual TrackingData → trackingInfo created") }
            applyTrackingInfo(info, to: avatar, log: log)
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
        
        dumpAvatarCapabilities(animoji)
        print("✅ Loaded animoji: \(name)")
    }
    
    private func dumpAvatarCapabilities(_ obj: NSObject) {
        let methods = [
            "applyBlendShapesWithTrackingInfo:",
            "applyHeadPoseWithTrackingInfo:",
            "_applyBlendShapes:parameters:",
            "_applyBlendShapesWithTrackingData:",
            "_applyHeadPoseWithTrackingData:gazeCorrection:pointOfView:",
            "blendShapeIndexForARKitBlendShapeName:",
        ]
        print("📋 Avatar capabilities:")
        for m in methods {
            let responds = obj.responds(to: NSSelectorFromString(m))
            print("   \(responds ? "✅" : "❌") \(m)")
        }
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
        for (i, name) in names.enumerated() { map[name] = i }
        return map
    }()
}
