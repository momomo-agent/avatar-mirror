import SwiftUI
import os

@main
struct AvatarMirrorApp: App {
    init() {
        dumpTrackingInfo()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
    
    private func dumpTrackingInfo() {
        dlopen("/System/Library/PrivateFrameworks/AvatarKit.framework/AvatarKit", RTLD_LAZY)
        
        var output = ""
        
        for className in ["AVTFaceTrackingInfo", "AVTTrackingData", "AVTFaceTrackingDataSource", "AVTAnimoji"] {
            guard let cls = NSClassFromString(className) else {
                output += "❌ \(className) NOT FOUND\n\n"
                continue
            }
            
            output += "=== \(className) ===\n"
            if let superCls = class_getSuperclass(cls) {
                output += "  super: \(NSStringFromClass(superCls))\n"
            }
            
            // Instance methods
            var count: UInt32 = 0
            if let methods = class_copyMethodList(cls, &count) {
                let names = (0..<Int(count)).map { NSStringFromSelector(method_getName(methods[$0])) }.sorted()
                for name in names {
                    output += "  - \(name)\n"
                }
                free(methods)
            }
            
            // Class methods
            if let meta = object_getClass(cls) {
                var ccount: UInt32 = 0
                if let cmethods = class_copyMethodList(meta, &ccount) {
                    let names = (0..<Int(ccount)).map { NSStringFromSelector(method_getName(cmethods[$0])) }.sorted()
                    for name in names {
                        output += "  + \(name)\n"
                    }
                    free(cmethods)
                }
            }
            
            // Properties
            var pcount: UInt32 = 0
            if let props = class_copyPropertyList(cls, &pcount) {
                for i in 0..<Int(pcount) {
                    let name = String(cString: property_getName(props[i]))
                    let attrs = property_getAttributes(props[i]).map { String(cString: $0) } ?? ""
                    output += "  @property \(name) [\(attrs)]\n"
                }
                free(props)
            }
            
            // Ivars (memory layout!)
            var icount: UInt32 = 0
            if let ivars = class_copyIvarList(cls, &icount) {
                for i in 0..<Int(icount) {
                    let name = ivar_getName(ivars[i]).map { String(cString: $0) } ?? "?"
                    let type = ivar_getTypeEncoding(ivars[i]).map { String(cString: $0) } ?? "?"
                    let offset = ivar_getOffset(ivars[i])
                    output += "  ivar \(name) type=\(type) offset=\(offset)\n"
                }
                free(ivars)
            }
            output += "\n"
        }
        
        let path = NSTemporaryDirectory() + "avt_tracking_dump.txt"
        try? output.write(toFile: path, atomically: true, encoding: .utf8)
        print("📋 Tracking dump written to \(path)")
        print(output)
    }
}
