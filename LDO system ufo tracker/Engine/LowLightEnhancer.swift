// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import CoreImage
import CoreGraphics

/// Rehausse l'exposition des images capturées en faible luminosité (observation de nuit), pour la
/// vidéo enregistrée ET pour les images utilisées par l'analyse/les photos.
///
/// LIMITE IMPORTANTE : ARKit ne permet aucun contrôle manuel du capteur (ISO, vitesse d'obturation)
/// pendant qu'une `ARSession` tourne — ce n'est pas configurable via l'API, contrairement à une
/// simple `AVCaptureSession`. Le seul levier disponible est un rehaussement d'image après capture
/// (exposition + gamma), appliqué ici. Ce n'est pas équivalent à un vrai mode nuit avec exposition
/// plus longue au capteur, mais ça reste la seule option pendant une session ARKit.
///
/// Le rehaussement est ADAPTATIF (mesuré par image) : appliqué seulement si la scène est
/// effectivement sombre, pour ne jamais cramer une scène normalement éclairée.
enum LowLightEnhancer {
    /// Luminance moyenne (0-255) en dessous de laquelle une scène est considérée sombre.
    private static let darknessThreshold: Double = 60
    /// Rehaussement maximal appliqué (en IL/EV), pour une scène très sombre.
    private static let maxExposureBoost: Float = 3.0

    struct Result {
        let image: CIImage
        let wasEnhanced: Bool
    }

    /// Version légère, utilisée à chaque image pendant l'enregistrement vidéo (budget temps réel :
    /// pas de réduction de bruit, seulement exposition + gamma).
    static func enhanceIfDark(_ image: CIImage, using context: CIContext) -> Result {
        let luminance = averageLuminance(of: image, using: context)
        guard luminance < darknessThreshold, luminance > 0 else { return Result(image: image, wasEnhanced: false) }

        // Rehaussement proportionnel à l'obscurité : plus la scène est sombre, plus fort le
        // relevé, plafonné pour ne pas produire une image trop bruitée/artificielle.
        let darknessRatio = 1 - (luminance / darknessThreshold)   // 0 (à la limite) ... 1 (très sombre)
        let exposureBoost = Float(darknessRatio) * maxExposureBoost

        guard let exposureFilter = CIFilter(name: "CIExposureAdjust") else { return Result(image: image, wasEnhanced: false) }
        exposureFilter.setValue(image, forKey: kCIInputImageKey)
        exposureFilter.setValue(exposureBoost, forKey: kCIInputEVKey)

        guard let gammaFilter = CIFilter(name: "CIGammaAdjust") else {
            return Result(image: exposureFilter.outputImage ?? image, wasEnhanced: true)
        }
        gammaFilter.setValue(exposureFilter.outputImage ?? image, forKey: kCIInputImageKey)
        gammaFilter.setValue(0.8, forKey: "inputPower")   // < 1 éclaircit les tons moyens/sombres

        return Result(image: gammaFilter.outputImage ?? exposureFilter.outputImage ?? image, wasEnhanced: true)
    }

    private static func averageLuminance(of image: CIImage, using context: CIContext) -> Double {
        guard let averageFilter = CIFilter(name: "CIAreaAverage") else { return 255 }
        averageFilter.setValue(image, forKey: kCIInputImageKey)
        averageFilter.setValue(CIVector(cgRect: image.extent), forKey: kCIInputExtentKey)
        guard let output = averageFilter.outputImage else { return 255 }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3.0
    }
}
