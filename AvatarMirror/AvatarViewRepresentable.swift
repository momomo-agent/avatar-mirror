import SwiftUI
import UIKit

/// UIViewRepresentable wrapper for AvatarKit's AVTView
struct AvatarViewRepresentable: UIViewRepresentable {
    @ObservedObject var viewModel: AvatarMirrorViewModel
    
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        
        if let avtView = viewModel.bridge.createView(frame: .zero) {
            avtView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(avtView)
            NSLayoutConstraint.activate([
                avtView.topAnchor.constraint(equalTo: container.topAnchor),
                avtView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                avtView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                avtView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            
            // Load default animoji
            viewModel.bridge.loadAnimoji(viewModel.currentAnimoji)
        }
        
        return container
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // Updates happen via the bridge's applyFaceAnchor called from ViewModel
    }
}
