import SwiftUI
import UIKit

/// UIViewRepresentable wrapper for AvatarKit's AVTView
struct AvatarViewRepresentable: UIViewRepresentable {
    @ObservedObject var viewModel: AvatarMirrorViewModel
    
    func makeUIView(context: Context) -> UIView {
        let container = AVTContainerView()
        container.backgroundColor = .clear
        container.bridge = viewModel.bridge
        container.animojiName = viewModel.currentAnimoji
        return container
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Container that creates AVTView once it has a real frame size.
private class AVTContainerView: UIView {
    var bridge: AvatarKitBridge?
    var animojiName: String = "tiger"
    private var avtViewAdded = false
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        guard !avtViewAdded, bounds.width > 0, bounds.height > 0 else {
            // Update existing AVTView frame
            if let avtView = subviews.first {
                avtView.frame = bounds
            }
            return
        }
        
        guard let bridge = bridge,
              let avtView = bridge.createView(frame: bounds) else { return }
        
        avtView.frame = bounds
        avtView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(avtView)
        avtViewAdded = true
        
        bridge.loadAnimoji(animojiName)
        print("✅ AVTView created with frame: \(bounds)")
    }
}
