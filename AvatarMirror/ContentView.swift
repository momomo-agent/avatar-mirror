import SwiftUI
import HumanSenseKit

struct ContentView: View {
    @StateObject private var viewModel = AvatarMirrorViewModel()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            AvatarViewRepresentable(viewModel: viewModel)
                .ignoresSafeArea()
            
            VStack {
                HStack {
                    Circle()
                        .fill(viewModel.isTracking ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(viewModel.isTracking ? "Tracking" : "No Face")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    
                    Spacer()
                    
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
                
                if viewModel.isMemoji {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(AvatarKitBridge.memojiBodyPoses, id: \.self) { pose in
                                Button {
                                    viewModel.switchPose(pose)
                                } label: {
                                    Text(pose.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.caption2)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(viewModel.currentPose == pose ? .white.opacity(0.3) : .white.opacity(0.1))
                                        .clipShape(Capsule())
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 8)
                } else {
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
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .statusBarHidden()
    }
}
