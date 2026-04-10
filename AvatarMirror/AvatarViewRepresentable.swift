import SwiftUI
import UIKit

/// UIViewRepresentable wrapper for AvatarKit's AVTRecordView (SCNView subclass)
struct AvatarViewRepresentable: UIViewRepresentable {
    @ObservedObject var viewModel: AvatarMirrorViewModel
    
    func makeUIView(context: Context) -> UIView {
        let container = AVTContainerView()
        container.backgroundColor = .clear
        container.viewModel = viewModel
        return container
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Container that creates AVTRecordView once it has a real frame size.
private class AVTContainerView: UIView {
    var viewModel: AvatarMirrorViewModel?
    private var avtViewAdded = false
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        guard bounds.width > 0, bounds.height > 0 else { return }
        
        if !avtViewAdded {
            guard let viewModel = viewModel,
                  let avtView = viewModel.bridge.createView(frame: bounds) else { return }
            
            avtView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(avtView)
            avtViewAdded = true
            
            print("✅ AVTRecordView added with frame: \(bounds)")
            
            // Notify ViewModel that view is ready
            DispatchQueue.main.async {
                viewModel.onViewReady()
            }
        } else if let avtView = subviews.first {
            avtView.frame = bounds
        }
    }
}
