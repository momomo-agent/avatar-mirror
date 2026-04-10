import SwiftUI
import AvatarKit

struct ContentView: View {
    @StateObject private var viewModel = AvatarMirrorViewModel()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            AvatarView(animoji: viewModel.currentAnimoji, tracking: viewModel.tracking)
                .ignoresSafeArea()
            
            VStack {
                HStack {
                    Text(viewModel.debugStatus)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                Spacer()
                
                // Animoji picker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AvatarView.availableAnimoji, id: \.self) { name in
                            Button {
                                viewModel.currentAnimoji = name
                            } label: {
                                Text(name.capitalized)
                                    .font(.caption2)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(viewModel.currentAnimoji == name ? .white.opacity(0.3) : .white.opacity(0.1))
                                    .clipShape(Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 8)
            }
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .statusBarHidden()
    }
}
