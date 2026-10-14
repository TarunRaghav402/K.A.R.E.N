import SwiftUI

/// Shared state colors used by the orb, space backdrop, and app controls.
enum KarenTheme {
    static func accentRGB(for state: OrbState) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch state {
        case .listening, .processing:
            return (0.12, 0.92, 0.48)   // green: hearing and handling a voice request
        case .speaking, .error:
            return (1.00, 0.20, 0.27)   // red: voice output / attention
        case .permission:
            return (1.00, 0.64, 0.20)
        case .idle:
            return (0.22, 0.52, 1.00)   // blue: ready and thinking
        }
    }

    static func accent(for state: OrbState) -> Color {
        let rgb = accentRGB(for: state)
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    static func backdrop(for state: OrbState) -> [Color] {
        let rgb = accentRGB(for: state)
        return [
            Color(red: 0.004 + rgb.r * 0.010,
                  green: 0.008 + rgb.g * 0.010,
                  blue: 0.020 + rgb.b * 0.018),
            Color(red: 0.008 + rgb.r * 0.028,
                  green: 0.014 + rgb.g * 0.026,
                  blue: 0.035 + rgb.b * 0.038)
        ]
    }

    static func panel(for state: OrbState) -> Color {
        let rgb = accentRGB(for: state)
        return Color(red: 0.018 + rgb.r * 0.025,
                     green: 0.024 + rgb.g * 0.025,
                     blue: 0.045 + rgb.b * 0.035)
    }
}
