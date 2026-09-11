import Foundation

/// The catalog of lid effects. `rawValue` is the stable persisted identifier and
/// `shaderIndex` is the explicit numeric contract with the Metal fragment shader.
/// Neither may be renumbered: saved selections and the shader switch depend on both.
public enum FoldEffect: String, CaseIterable, Sendable, Identifiable {
    case duo, ghost, roll, shutter, flex, iris

    public static let fallback = FoldEffect.duo

    public var id: String { rawValue }
    public var persistedIdentifier: String { rawValue }

    /// Mirrored by `Uniforms.effect` in `FoldShader.source`.
    public var shaderIndex: UInt32 {
        switch self {
        case .duo: return 0
        case .ghost: return 5
        case .roll: return 1
        case .shutter: return 2
        case .flex: return 3
        case .iris: return 4
        }
    }

    /// An unreadable or unknown saved selection returns to the default effect.
    public static func resolve(persisted: String?) -> FoldEffect {
        guard let persisted, let effect = FoldEffect(rawValue: persisted) else { return fallback }
        return effect
    }

    /// The shader applies the same rule for an index it does not recognize.
    public static func resolve(shaderIndex: UInt32) -> FoldEffect {
        allCases.first { $0.shaderIndex == shaderIndex } ?? fallback
    }

    public var title: String {
        switch self {
        case .duo: return "Duo"
        case .ghost: return "Ghost"
        case .roll: return "Roll"
        case .shutter: return "Shutter"
        case .flex: return "Flex"
        case .iris: return "Iris"
        }
    }

    public var symbol: String {
        switch self {
        case .duo: return "macbook"
        case .ghost: return "aqi.medium"
        case .roll: return "scroll"
        case .shutter: return "square.stack.3d.down.right"
        case .flex: return "rectangle.compress.vertical"
        case .iris: return "camera.aperture"
        }
    }

    public var summary: String {
        switch self {
        case .duo: return "The desktop swells around the hinge as the lid closes."
        case .ghost: return "The desktop holds its resting plane as the lid tilts and gently falls out of focus."
        case .roll: return "The desktop curls into a roll that travels down to the hinge."
        case .shutter: return "Four rigid panels telescope behind each other into the hinge."
        case .flex: return "One bowing flexible display collapses toward the hinge."
        case .iris: return "Eight overlapping blades close an aperture above the hinge."
        }
    }

    /// Duo can skip the pyramid with Softness off. Effects that minify
    /// the source still need it for prefiltering at zero Softness.
    public var needsPrefilteredSource: Bool { self != .duo }
}
