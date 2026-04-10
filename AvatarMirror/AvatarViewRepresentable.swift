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

/// Container that creates AVTView with correct square aspect ratio.
private class AVTContainerView: UIView {
    var bridge: AvatarKitBridge?
    var animojiName: String = "tiger"
    private var avtViewAdded = false
    private weak var avtView: UIView?
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        guard bounds.width > 0, bounds.height > 0 else { return }
        
        if !avtViewAdded {
            guard let bridge = bridge,
                  let view = bridge.createView(frame: squareFrame()) else { return }
            
            view.autoresizingMask = []
            addSubview(view)
            avtView = view
            avtViewAdded = true
            
            bridge.loadAnimoji(animojiName)
            print("✅ AVTView created with frame: \(view.frame)")
        } else {
            // Update frame on rotation/resize
            avtView?.frame = squareFrame()
        }
    }
    
    /// Compute a centered square frame that fits within bounds
    private func squareFrame() -> CGRect {
        let side = min(bounds.width, bounds.height)
        let x = (bounds.width - side) / 2
        let y = (bounds.height - side) / 2
        return CGRect(x: x, y: y, width: side, height: side)
    }
}
