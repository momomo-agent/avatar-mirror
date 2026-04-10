import UIKit

/// Wraps the private AVTAvatarEditorViewController for creating/editing Memoji.
/// When `isCreating = true`, the editor shows the full creation flow including
/// the camera-based face scan option.
@MainActor
final class MemojiEditorBridge: NSObject {
    
    private var editorVC: UIViewController?
    private var store: NSObject?
    private var completion: ((NSObject?) -> Void)?
    
    /// Present the system Memoji creator (with camera face scan).
    /// - Parameters:
    ///   - presenter: The view controller to present from
    ///   - completion: Called with the created AVTAvatarRecord, or nil if cancelled
    func presentCreator(from presenter: UIViewController, completion: @escaping (NSObject?) -> Void) {
        self.completion = completion
        
        guard loadFrameworks() else {
            print("❌ Failed to load AvatarKit/AvatarUI frameworks")
            completion(nil)
            return
        }
        
        // Create AVTAvatarStore
        guard let storeCls = NSClassFromString("AVTAvatarStore") else {
            print("❌ AVTAvatarStore not found")
            completion(nil)
            return
        }
        
        let storeInstance = (storeCls as! NSObject.Type).init()
        self.store = storeInstance
        
        // Create AVTAvatarEditorViewController with isCreating: true
        guard let editorCls = NSClassFromString("AVTAvatarEditorViewController") else {
            print("❌ AVTAvatarEditorViewController not found")
            completion(nil)
            return
        }
        
        // initWithAvatarRecord:avtViewSessionProvider:store:enviroment:isCreating:
        let sel = NSSelectorFromString("initWithAvatarRecord:avtViewSessionProvider:store:enviroment:isCreating:")
        
        // Use NSInvocation-style approach via performSelector workaround
        guard let editor = createEditorVC(cls: editorCls, sel: sel, record: nil, store: storeInstance, isCreating: true) else {
            print("❌ Failed to create editor")
            completion(nil)
            return
        }
        
        self.editorVC = editor
        
        // Set delegate
        let delegateSel = NSSelectorFromString("setDelegate:")
        if editor.responds(to: delegateSel) {
            editor.perform(delegateSel, with: self)
        }
        
        // Present in a navigation controller
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .fullScreen
        presenter.present(nav, animated: true)
        
        print("✅ Memoji creator presented")
    }
    
    /// Present the editor for an existing Memoji record.
    func presentEditor(for record: NSObject, from presenter: UIViewController, completion: @escaping (NSObject?) -> Void) {
        self.completion = completion
        
        guard loadFrameworks() else {
            completion(nil)
            return
        }
        
        guard let storeCls = NSClassFromString("AVTAvatarStore"),
              let editorCls = NSClassFromString("AVTAvatarEditorViewController") else {
            completion(nil)
            return
        }
        
        let storeInstance = (storeCls as! NSObject.Type).init()
        self.store = storeInstance
        
        let sel = NSSelectorFromString("initWithAvatarRecord:avtViewSessionProvider:store:enviroment:isCreating:")
        
        guard let editor = createEditorVC(cls: editorCls, sel: sel, record: record, store: storeInstance, isCreating: false) else {
            completion(nil)
            return
        }
        
        self.editorVC = editor
        
        let delegateSel = NSSelectorFromString("setDelegate:")
        if editor.responds(to: delegateSel) {
            editor.perform(delegateSel, with: self)
        }
        
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .fullScreen
        presenter.present(nav, animated: true)
    }
    
    // MARK: - Framework Loading
    
    private func loadFrameworks() -> Bool {
        let kit = dlopen("/System/Library/PrivateFrameworks/AvatarKit.framework/AvatarKit", RTLD_LAZY)
        let ui = dlopen("/System/Library/PrivateFrameworks/AvatarUI.framework/AvatarUI", RTLD_LAZY)
        return kit != nil && ui != nil
    }
    
    /// Create AVTAvatarEditorViewController using ObjC runtime IMP casting.
    private func createEditorVC(cls: AnyClass, sel: Selector, record: NSObject?, store: NSObject, isCreating: Bool) -> UIViewController? {
        // Allocate using objc_msgSend
        let allocSel = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(cls, allocSel) else { return nil }
        let allocImp = method_getImplementation(allocMethod)
        
        typealias AllocFunc = @convention(c) (AnyClass, Selector) -> NSObject
        let allocFn = unsafeBitCast(allocImp, to: AllocFunc.self)
        let instance = allocFn(cls, allocSel)
        
        guard instance.responds(to: sel) else {
            print("❌ Editor doesn't respond to init selector")
            return nil
        }
        
        guard let method = class_getInstanceMethod(type(of: instance), sel) else { return nil }
        let imp = method_getImplementation(method)
        
        typealias InitFunc = @convention(c) (
            NSObject, Selector,
            NSObject?,   // avatarRecord
            NSObject?,   // avtViewSessionProvider
            NSObject,    // store
            NSObject?,   // environment
            Bool         // isCreating
        ) -> NSObject?
        
        let initFn = unsafeBitCast(imp, to: InitFunc.self)
        return initFn(instance, sel, record, nil, store, nil, isCreating) as? UIViewController
    }
}

// MARK: - AVTAvatarEditorViewControllerDelegate (informal protocol)
extension MemojiEditorBridge {
    
    // The delegate methods are discovered via runtime; these are the common ones:
    // - avatarEditorViewController:didSaveAvatarRecord:
    // - avatarEditorViewControllerDidCancel:
    
    @objc func avatarEditorViewController(_ controller: UIViewController, didSaveAvatarRecord record: NSObject) {
        print("✅ Memoji saved: \(record)")
        controller.dismiss(animated: true) {
            self.completion?(record)
            self.cleanup()
        }
    }
    
    @objc func avatarEditorViewControllerDidCancel(_ controller: UIViewController) {
        print("ℹ️ Memoji creation cancelled")
        controller.dismiss(animated: true) {
            self.completion?(nil)
            self.cleanup()
        }
    }
    
    @objc func avatarEditorViewController(_ controller: UIViewController, didFinishWithAvatarRecord record: NSObject) {
        avatarEditorViewController(controller, didSaveAvatarRecord: record)
    }
    
    private func cleanup() {
        editorVC = nil
        store = nil
        completion = nil
    }
}
