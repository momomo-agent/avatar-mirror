import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AvatarMirrorViewModel()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            AvatarViewRepresentable(viewModel: viewModel)
                .ignoresSafeArea()
            
            VStack {
                HStack {
                    Text(viewModel.debugStatus)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    
                    Spacer()
                    
                    // Toggle tracking mode
                    Button {
                        viewModel.toggleTrackingMode()
                    } label: {
                        Text(viewModel.useHumanSenseKit ? "HSK" : "Built-in")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(viewModel.useHumanSenseKit ? .green.opacity(0.3) : .blue.opacity(0.3))
                            .clipShape(Capsule())
                            .foregroundStyle(.white)
                    }
                    
                    Button {
                        viewModel.presentMemojiCreator()
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.body)
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    
                    Button {
                        if viewModel.isMemoji {
                            viewModel.switchToAnimoji(viewModel.currentAnimoji)
                        } else {
                            viewModel.switchToMemoji()
                        }
                    } label: {
                        Text(viewModel.isMemoji ? "🧑 Memoji" : "🐯 Animoji")
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                Spacer()
                
                // Animoji picker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AvatarKitBridge.availableAnimoji, id: \.self) { name in
                            Button {
                                viewModel.switchToAnimoji(name)
                            } label: {
                                Text(name.capitalized)
                                    .font(.caption2)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(viewModel.currentAnimoji == name && !viewModel.isMemoji ? .white.opacity(0.3) : .white.opacity(0.1))
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
