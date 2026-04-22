import SwiftUI

/// A stylized body silhouette drawn below the Animoji head.
///
/// Responds to body state from AutonomousController:
/// - lean: lateral weight shift
/// - tilt: forward/back lean
/// - breath: subtle vertical breathing motion
///
/// The shape is a simple neck + shoulders + torso outline that
/// matches the Animoji's cartoon aesthetic.
struct AvatarBodyOverlay: View {
    let lean: CGFloat      // -1..1
    let tilt: CGFloat      // -1..1
    let breath: CGFloat    // 0..1
    let character: String
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            
            // Body positioned in lower portion of the view
            let centerX = w * 0.5 + lean * w * 0.03
            let breathOffset = breath * 2.0
            
            // Neck + shoulders + torso shape
            BodyShape(
                lean: lean,
                tilt: tilt,
                breath: breath
            )
            .fill(bodyGradient)
            .frame(width: w * 0.7, height: h)
            .position(x: centerX, y: h * 0.5 + breathOffset)
        }
    }
    
    private var bodyGradient: LinearGradient {
        // Match character color palette
        let colors = characterColors
        return LinearGradient(
            colors: colors,
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    private var characterColors: [Color] {
        switch character {
        case "cat":
            return [Color(red: 0.95, green: 0.75, blue: 0.45),
                    Color(red: 0.85, green: 0.60, blue: 0.30)]
        case "dog":
            return [Color(red: 0.85, green: 0.70, blue: 0.50),
                    Color(red: 0.70, green: 0.55, blue: 0.35)]
        case "fox":
            return [Color(red: 0.95, green: 0.55, blue: 0.20),
                    Color(red: 0.80, green: 0.40, blue: 0.15)]
        case "robot":
            return [Color(red: 0.65, green: 0.70, blue: 0.75),
                    Color(red: 0.45, green: 0.50, blue: 0.55)]
        case "alien":
            return [Color(red: 0.55, green: 0.75, blue: 0.55),
                    Color(red: 0.40, green: 0.60, blue: 0.40)]
        case "panda":
            return [Color(red: 0.90, green: 0.90, blue: 0.90),
                    Color(red: 0.75, green: 0.75, blue: 0.75)]
        case "unicorn":
            return [Color(red: 0.90, green: 0.80, blue: 0.95),
                    Color(red: 0.75, green: 0.60, blue: 0.85)]
        case "owl":
            return [Color(red: 0.65, green: 0.50, blue: 0.35),
                    Color(red: 0.50, green: 0.35, blue: 0.25)]
        case "monkey":
            return [Color(red: 0.70, green: 0.50, blue: 0.30),
                    Color(red: 0.55, green: 0.35, blue: 0.20)]
        case "lion":
            return [Color(red: 0.90, green: 0.70, blue: 0.30),
                    Color(red: 0.75, green: 0.55, blue: 0.20)]
        default:
            return [Color(red: 0.70, green: 0.70, blue: 0.70),
                    Color(red: 0.50, green: 0.50, blue: 0.50)]
        }
    }
}

// MARK: - Body Shape

/// Custom shape: neck narrowing from top, widening into shoulders, tapering to torso.
struct BodyShape: Shape {
    let lean: CGFloat
    let tilt: CGFloat
    let breath: CGFloat
    
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = w * 0.5 + lean * w * 0.02
        
        // Proportions
        let neckWidth = w * 0.18
        let shoulderWidth = w * 0.85 + breath * w * 0.02
        let torsoWidth = w * 0.65
        let neckHeight = h * 0.08
        let shoulderY = h * 0.22
        let torsoEnd = h * 1.0
        
        // Tilt affects shoulder heights (one side higher)
        let shoulderTilt = tilt * h * 0.02
        
        var path = Path()
        
        // Start at top-left of neck
        path.move(to: CGPoint(x: cx - neckWidth * 0.5, y: 0))
        
        // Neck right side
        path.addLine(to: CGPoint(x: cx + neckWidth * 0.5, y: 0))
        
        // Neck to right shoulder (smooth curve)
        path.addCurve(
            to: CGPoint(x: cx + shoulderWidth * 0.5, y: shoulderY - shoulderTilt),
            control1: CGPoint(x: cx + neckWidth * 0.5, y: neckHeight),
            control2: CGPoint(x: cx + shoulderWidth * 0.4, y: shoulderY * 0.6 - shoulderTilt)
        )
        
        // Right shoulder to torso
        path.addCurve(
            to: CGPoint(x: cx + torsoWidth * 0.5, y: torsoEnd),
            control1: CGPoint(x: cx + shoulderWidth * 0.5, y: shoulderY + h * 0.15),
            control2: CGPoint(x: cx + torsoWidth * 0.5, y: torsoEnd - h * 0.2)
        )
        
        // Bottom
        path.addLine(to: CGPoint(x: cx - torsoWidth * 0.5, y: torsoEnd))
        
        // Left torso to left shoulder
        path.addCurve(
            to: CGPoint(x: cx - shoulderWidth * 0.5, y: shoulderY + shoulderTilt),
            control1: CGPoint(x: cx - torsoWidth * 0.5, y: torsoEnd - h * 0.2),
            control2: CGPoint(x: cx - shoulderWidth * 0.5, y: shoulderY + h * 0.15)
        )
        
        // Left shoulder to neck
        path.addCurve(
            to: CGPoint(x: cx - neckWidth * 0.5, y: 0),
            control1: CGPoint(x: cx - shoulderWidth * 0.4, y: shoulderY * 0.6 + shoulderTilt),
            control2: CGPoint(x: cx - neckWidth * 0.5, y: neckHeight)
        )
        
        path.closeSubpath()
        return path
    }
}
