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
    
    // MARK: - External Face Tracking
    
    func startExternalTracking() {
        trackingMode = .external
        print("✅ External tracking mode")
    }
    
    /// Apply an ARFrame — tries multiple approaches with detailed logging
    func applyARFrame(_ frame: ARFrame) {
        guard let avatar = avatar else { return }
        
        frameCount += 1
        let shouldLog = frameCount <= 5 || frameCount % 300 == 0
        
        let faceAnchors = frame.anchors.compactMap { $0 as? ARFaceAnchor }
        if shouldLog {
            print("🎯 Frame #\(frameCount): \(faceAnchors.count) face anchors")
        }
        
        guard let faceAnchor = faceAnchors.first else { return }
        
        if shouldLog {
            let bs = faceAnchor.blendShapes
            let jawOpen = bs[.jawOpen]?.floatValue ?? -1
            let smile = bs[.mouthSmileLeft]?.floatValue ?? -1
            print("   jawOpen=\(jawOpen) smileL=\(smile) transform=\(faceAnchor.transform)")
        }
        
        // Approach 1: trackingInfoWithARFrame:captureOrientation:interfaceOrientation:
        if let trackInfoCls = trackInfoCls {
            let orientationRaw = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.interfaceOrientation.rawValue ?? 1
            
            let sel = NSSelectorFromString("trackingInfoWithARFrame:captureOrientation:interfaceOrientation:")
            if let meta = object_getClass(trackInfoCls),
               let method = class_getClassMethod(meta, sel) {
                let imp = method_getImplementation(method)
                typealias Func = @convention(c) (AnyClass, Selector, AnyObject, Int, Int) -> NSObject?
                let fn = unsafeBitCast(imp, to: Func.self)
                
                if let info = fn(trackInfoCls, sel, frame, orientationRaw, orientationRaw) {
                    if shouldLog { print("   ✅ Approach 1: trackingInfoWithARFrame succeeded") }
                    applyTrackingInfo(info, to: avatar, log: shouldLog)
                    return
                } else {
                    if shouldLog { print("   ❌ Approach 1: trackingInfoWithARFrame returned nil") }
                }
            } else {
                if shouldLog { print("   ❌ Approach 1: method not found") }
            }
        }
        
        // Approach 2: trackingInfoWithFaceAnchor:
        if let trackInfoCls = trackInfoCls {
            let sel = NSSelectorFromString("trackingInfoWithFaceAnchor:")
            if let meta = object_getClass(trackInfoCls),
               let method = class_getClassMethod(meta, sel) {
                let imp = method_getImplementation(method)
                typealias Func = @convention(c) (AnyClass, Selector, AnyObject) -> NSObject?
                let fn = unsafeBitCast(imp, to: Func.self)
                
                if let info = fn(trackInfoCls, sel, faceAnchor) {
                    if shouldLog { print("   ✅ Approach 2: trackingInfoWithFaceAnchor succeeded") }
                    applyTrackingInfo(info, to: avatar, log: shouldLog)
                    return
                } else {
                    if shouldLog { print("   ❌ Approach 2: trackingInfoWithFaceAnchor returned nil") }
                }
            } else {
                if shouldLog { print("   ❌ Approach 2: method not found") }
            }
        }
        
        // Approach 3: Direct puppet method on AVTView
        if let view = avtView {
            let sel = NSSelectorFromString("applyFaceAnchor:")
            if view.responds(to: sel) {
                view.perform(sel, with: faceAnchor)
                if shouldLog { print("   ✅ Approach 3: applyFaceAnchor on view") }
                return
            }
            
            // Try the puppet view
            let puppetSel = NSSelectorFromString("puppetView")
            if view.responds(to: puppetSel),
               let puppet = view.perform(puppetSel)?.takeUnretainedValue() as? NSObject {
                let applyPuppetSel = NSSelectorFromString("applyFaceAnchor:")
                if puppet.responds(to: applyPuppetSel) {
                    puppet.perform(applyPuppetSel, with: faceAnchor)
                    if shouldLog { print("   ✅ Approach 3b: applyFaceAnchor on puppetView") }
                    return
                }
            }
        }
        
        // Approach 4: Direct _applyBlendShapes on avatar
        let applySel = NSSelectorFromString("_applyBlendShapes:parameters:")
        if avatar.responds(to: applySel) {
            var blendShapes = [Float](repeating: 0, count: 51)
            
            for (location, value) in faceAnchor.blendShapes {
                if let idx = Self.arkitBlendShapeOrder[location.rawValue], idx < 51 {
                    blendShapes[idx] = value.floatValue
                }
            }
            
            let method = class_getInstanceMethod(type(of: avatar), applySel)!
            let imp = method_getImplementation(method)
            typealias Func = @convention(c) (NSObject, Selector, UnsafePointer<Float>, UnsafePointer<Float>) -> Void
            let fn = unsafeBitCast(imp, to: Func.self)
            
            blendShapes.withUnsafeBufferPointer { bsPtr in
                var params: [Float] = [0]
                params.withUnsafeBufferPointer { pPtr in
                    fn(avatar, applySel, bsPtr.baseAddress!, pPtr.baseAddress!)
                }
            }
            if shouldLog { print("   ✅ Approach 4: _applyBlendShapes direct") }
            
            // Also try to apply head pose
            applyHeadTransform(faceAnchor.transform, to: avatar, log: shouldLog)
            return
        }
        
        if shouldLog { print("   ❌ All approaches failed") }
    }
    
    private func applyTrackingInfo(_ info: NSObject, to avatar: NSObject, log: Bool) {
        let bsSel = NSSelectorFromString("applyBlendShapesWithTrackingInfo:")
        let poseSel = NSSelectorFromString("applyHeadPoseWithTrackingInfo:")
        
        if avatar.responds(to: bsSel) {
            avatar.perform(bsSel, with: info)
            if log { print("   → applyBlendShapes ✅") }
        } else {
            if log { print("   → applyBlendShapes ❌ not responding") }
        }
        
        if avatar.responds(to: poseSel) {
            avatar.perform(poseSel, with: info)
            if log { print("   → applyHeadPose ✅") }
        } else {
            if log { print("   → applyHeadPose ❌ not responding") }
        }
    }
    
    /// Apply head transform from ARFaceAnchor.transform (simd_float4x4)
    private func applyHeadTransform(_ transform: simd_float4x4, to avatar: NSObject, log: Bool) {
        // Try setHeadTransform: or similar
        for selName in ["setHeadTransform:", "_setHeadTransform:", "applyHeadTransform:"] {
            let sel = NSSelectorFromString(selName)
            if avatar.responds(to: sel) {
                // simd_float4x4 is 64 bytes, pass as NSValue
                var t = transform
                let value = NSValue(bytes: &t, objCType: "{simd_float4x4=[4]}")
                avatar.perform(sel, with: value)
                if log { print("   → \(selName) ✅") }
                return
            }
        }
        
        // Try setting on the SceneKit node directly
        // AVTRecordView is a SCNView, avatar's rootNode might be accessible
        if let view = avtView {
            let nodeSel = NSSelectorFromString("avatarNode")
            if view.responds(to: nodeSel),
               let node = view.perform(nodeSel)?.takeUnretainedValue() as? NSObject {
                // SCNNode.simdTransform
                let transformSel = NSSelectorFromString("setSimdTransform:")
                if node.responds(to: transformSel) {
                    var t = transform
                    let method = class_getInstanceMethod(type(of: node), transformSel)!
                    let imp = method_getImplementation(method)
                    typealias Func = @convention(c) (NSObject, Selector, simd_float4x4) -> Void
                    unsafeBitCast(imp, to: Func.self)(node, transformSel, t)
                    if log { print("   → avatarNode.simdTransform ✅") }
                    return
                }
            }
        }
        
        if log { print("   → head transform: no method found") }
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
        
        // Dump what methods the avatar actually responds to
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
            "setHeadTransform:",
            "_setHeadTransform:",
            "applyHeadTransform:",
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
    
    // ARKit blendshape name -> index (alphabetical order)
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
