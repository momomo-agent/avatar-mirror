import UIKit

/// Wraps the private AVTAvatarEditorViewController for creating/editing Memoji.
@MainActor
final class MemojiEditorBridge: NSObject {
    
    private var editorVC: UIViewController?
    private var store: NSObject?
    private var environment: NSObject?
    private var completion: ((NSObject?) -> Void)?
    
    /// Present the system Memoji creator (with camera face scan).
    func presentCreator(from presenter: UIViewController, completion: @escaping (NSObject?) -> Void) {
        self.completion = completion
        
        guard loadFrameworks() else {
            print("❌ Failed to load AvatarKit/AvatarUI frameworks")
            completion(nil)
            return
        }
        
        // Create AVTUIEnvironment
        guard let env = createEnvironment() else {
            print("❌ Failed to create AVTUIEnvironment")
            completion(nil)
            return
        }
        self.environment = env
        
        // Create AVTAvatarStore
        guard let storeCls = NSClassFromString("AVTAvatarStore") else {
            print("❌ AVTAvatarStore not found")
            completion(nil)
            return
        }
        let storeInstance = (storeCls as! NSObject.Type).init()
        self.store = storeInstance
        
        // Create editor
        guard let editor = createEditorVC(record: nil, store: storeInstance, environment: env, isCreating: true) else {
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
        
        // Present
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
        
        guard let env = createEnvironment() else {
            completion(nil)
            return
        }
        self.environment = env
        
        guard let storeCls = NSClassFromString("AVTAvatarStore") else {
            completion(nil)
            return
        }
        let storeInstance = (storeCls as! NSObject.Type).init()
        self.store = storeInstance
        
        guard let editor = createEditorVC(record: record, store: storeInstance, environment: env, isCreating: false) else {
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
    
    // MARK: - Environment
    
    private func createEnvironment() -> NSObject? {
        guard let envCls = NSClassFromString("AVTUIEnvironment") else {
            print("❌ AVTUIEnvironment not found")
            return nil
        }
        
        // Try +defaultEnvironment class method
        let defaultSel = NSSelectorFromString("defaultEnvironment")
        guard let meta = object_getClass(envCls),
              class_getClassMethod(meta, defaultSel) != nil else {
            print("❌ +defaultEnvironment not found")
            return nil
        }
        
        let result = (envCls as AnyObject).perform(defaultSel)
        guard let env = result?.takeUnretainedValue() as? NSObject else {
            print("❌ +defaultEnvironment returned nil")
            return nil
        }
        
        print("✅ Created AVTUIEnvironment")
        return env
    }
    
    // MARK: - Editor Creation
    
    private func createEditorVC(record: NSObject?, store: NSObject, environment: NSObject, isCreating: Bool) -> UIViewController? {
        guard let editorCls = NSClassFromString("AVTAvatarEditorViewController") else {
            print("❌ AVTAvatarEditorViewController not found")
            return nil
        }
        
        // initWithAvatarRecord:avtViewSessionProvider:store:enviroment:isCreating:
        let sel = NSSelectorFromString("initWithAvatarRecord:avtViewSessionProvider:store:enviroment:isCreating:")
        
        // Allocate using objc_msgSend
        let allocSel = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(editorCls, allocSel) else { return nil }
        let allocImp = method_getImplementation(allocMethod)
        
        typealias AllocFunc = @convention(c) (AnyClass, Selector) -> NSObject
        let allocFn = unsafeBitCast(allocImp, to: AllocFunc.self)
        let instance = allocFn(editorCls, allocSel)
        
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
            NSObject,    // environment (NOT nil!)
            Bool         // isCreating
        ) -> NSObject?
        
        let initFn = unsafeBitCast(imp, to: InitFunc.self)
        return initFn(instance, sel, record, nil, store, environment, isCreating) as? UIViewController
    }
    
    // MARK: - Framework Loading
    
    private func loadFrameworks() -> Bool {
        let kit = dlopen("/System/Library/PrivateFrameworks/AvatarKit.framework/AvatarKit", RTLD_LAZY)
        let ui = dlopen("/System/Library/PrivateFrameworks/AvatarUI.framework/AvatarUI", RTLD_LAZY)
        return kit != nil && ui != nil
    }
}

// MARK: - AVTAvatarEditorViewControllerDelegate (informal protocol)
extension MemojiEditorBridge {
    
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
        environment = nil
        completion = nil
    }
}
