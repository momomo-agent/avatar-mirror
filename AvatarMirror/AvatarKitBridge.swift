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
        
        frameCount += 1
        let shouldLog = frameCount <= 10 || frameCount % 300 == 0
        
        let faceAnchors = frame.anchors.compactMap { $0 as? ARFaceAnchor }
        guard let faceAnchor = faceAnchors.first else { return }
        
        if shouldLog {
            let bs = faceAnchor.blendShapes
            print("🎯 Frame #\(frameCount): jawOpen=\(bs[.jawOpen]?.floatValue ?? -1)")
        }
        
        let orientationRaw = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation.rawValue ?? 1
        
        // Step 1: Get tracking DATA from ARFrame
        // dataWithARFrame: returns NSData/NSInlineData (raw bytes of TrackingData struct)
        let dataSel = NSSelectorFromString("dataWithARFrame:captureOrientation:interfaceOrientation:")
        if let meta = object_getClass(trackInfoCls),
           let method = class_getClassMethod(meta, dataSel) {
            let imp = method_getImplementation(method)
            typealias Func = @convention(c) (AnyClass, Selector, AnyObject, Int, Int) -> NSObject?
            let fn = unsafeBitCast(imp, to: Func.self)
            
            if let data = fn(trackInfoCls, dataSel, frame, orientationRaw, orientationRaw) {
                if shouldLog {
                    print("   ✅ dataWithARFrame returned: \(type(of: data)) length=\((data as? Data)?.count ?? -1)")
                    // Check if it's NSData
                    if let nsData = data as? Data {
                        print("   Data size: \(nsData.count) bytes")
                    }
                }
                
                // Step 2: Create AVTFaceTrackingInfo from the data
                let infoSel = NSSelectorFromString("trackingInfoWithTrackingData:")
                if let infoMethod = class_getClassMethod(meta, infoSel) {
                    let infoImp = method_getImplementation(infoMethod)
                    
                    // trackingInfoWithTrackingData: expects the raw struct, not NSData
                    // We need to get the bytes from the NSData and pass them
                    if let nsData = data as? Data {
                        nsData.withUnsafeBytes { rawBuf in
                            typealias InfoFunc = @convention(c) (AnyClass, Selector, UnsafeRawPointer) -> NSObject?
                            let infoFn = unsafeBitCast(infoImp, to: InfoFunc.self)
                            if let info = infoFn(trackInfoCls, infoSel, rawBuf.baseAddress!) {
                                if shouldLog { print("   ✅ trackingInfoWithTrackingData created: \(type(of: info))") }
                                applyTrackingInfo(info, to: avatar, log: shouldLog)
                                return
                            }
                        }
                    }
                }
                
                // If data is not NSData, maybe it IS the tracking info already?
                // Check if it responds to trackingData
                let tdSel = NSSelectorFromString("trackingData")
                if data.responds(to: tdSel) {
                    if shouldLog { print("   ✅ dataWithARFrame returned a trackingInfo object directly") }
                    applyTrackingInfo(data, to: avatar, log: shouldLog)
                    return
                }
            } else {
                if shouldLog { print("   ❌ dataWithARFrame returned nil") }
            }
        }
        
        // Approach 2: trackingInfoWithARFrame: (might also return data, handle both)
        let infoFrameSel = NSSelectorFromString("trackingInfoWithARFrame:captureOrientation:interfaceOrientation:")
        if let meta = object_getClass(trackInfoCls),
           let method = class_getClassMethod(meta, infoFrameSel) {
            let imp = method_getImplementation(method)
            typealias Func = @convention(c) (AnyClass, Selector, AnyObject, Int, Int) -> NSObject?
            let fn = unsafeBitCast(imp, to: Func.self)
            
            if let result = fn(trackInfoCls, infoFrameSel, frame, orientationRaw, orientationRaw) {
                if shouldLog { print("   trackingInfoWithARFrame returned: \(type(of: result))") }
                
                // If it's NSData, extract bytes and create tracking info
                if let nsData = result as? Data {
                    nsData.withUnsafeBytes { rawBuf in
                        let createSel = NSSelectorFromString("trackingInfoWithTrackingData:")
                        if let createMethod = class_getClassMethod(meta, createSel) {
                            let createImp = method_getImplementation(createMethod)
                            typealias CreateFunc = @convention(c) (AnyClass, Selector, UnsafeRawPointer) -> NSObject?
                            let createFn = unsafeBitCast(createImp, to: CreateFunc.self)
                            if let info = createFn(trackInfoCls, createSel, rawBuf.baseAddress!) {
                                if shouldLog { print("   ✅ Created trackingInfo from data bytes") }
                                applyTrackingInfo(info, to: avatar, log: shouldLog)
                            }
                        }
                    }
                    return
                }
                
                // If it's already a tracking info object
                let tdSel = NSSelectorFromString("trackingData")
                if result.responds(to: tdSel) {
                    applyTrackingInfo(result, to: avatar, log: shouldLog)
                    return
                }
            }
        }
        
        // Approach 3: Build TrackingData struct manually from ARFaceAnchor
        applyFaceAnchorManually(faceAnchor, to: avatar, log: shouldLog)
    }
    
    private func applyTrackingInfo(_ info: NSObject, to avatar: NSObject, log: Bool) {
        let bsSel = NSSelectorFromString("applyBlendShapesWithTrackingInfo:")
        let poseSel = NSSelectorFromString("applyHeadPoseWithTrackingInfo:")
        
        if avatar.responds(to: bsSel) {
            avatar.perform(bsSel, with: info)
            if log { print("   → applyBlendShapes ✅") }
        }
        
        if avatar.responds(to: poseSel) {
            avatar.perform(poseSel, with: info)
            if log { print("   → applyHeadPose ✅") }
        }
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
            var translation = simd_float3(
                anchor.transform.columns.3.x,
                anchor.transform.columns.3.y,
                anchor.transform.columns.3.z
            )
            memcpy(base + 8, &translation, 12)
            
            // orientation from face anchor transform (offset 24, simd_quatf = 16 bytes)
            var orientation = simd_quatf(anchor.transform)
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
