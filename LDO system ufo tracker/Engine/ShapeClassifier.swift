// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

/// Étape 3 : classification de la forme + isolement de la zone lumineuse.
///
/// IMPORTANT — honnêteté sur la méthode : il n'existe aucun modèle CoreML public entraîné à
/// reconnaître un "OVNI" (par définition, on n'a pas de base de données d'OVNI confirmés).
/// Ce module utilise donc des **heuristiques de mouvement et de forme** pour distinguer les
/// causes les plus fréquentes d'observations d'OVNI (insecte proche caméra, oiseau, drone,
/// avion/satellite lointain) d'un objet réellement non identifié. Un vrai modèle CoreML entraîné
/// sur des vidéos annotées (avions, drones, oiseaux, insectes) améliorerait nettement la précision
/// et peut remplacer `heuristicClassify` sans changer le reste du pipeline.
final class ShapeClassifier {

    private let ciContext = CIContext()

    func classifyShape(detections: [Detection], frames: [CapturedFrame]) -> ShapeResult {
        guard detections.count >= 3 else {
            return ShapeResult(label: "Données insuffisantes", confidence: 0, luminousRegion: nil)
        }

        // 1. Signal de mouvement : amplitude et régularité des oscillations de position.
        let motion = motionSignature(detections)

        // 2. Signal de forme : régularité de la taille apparente (un objet qui s'éloigne/rapproche
        //    change de taille progressivement ; un objet à distance constante a une taille stable).
        let sizeVariability = sizeSignature(detections)

        // 3. Isolement de la zone lumineuse sur l'image médiane (la plus représentative).
        let midDetection = detections[safe: detections.count / 2]
        let luminous = midDetection.flatMap { isolateLuminousRegion(for: $0, frames: frames) }

        // 4. Classification heuristique combinant ces signaux.
        let (label, confidence) = heuristicClassify(motion: motion, sizeVariability: sizeVariability)

        return ShapeResult(label: label, confidence: confidence, luminousRegion: luminous)
    }

    /// Isole la zone lumineuse pour une détection donnée (réutilisé par IlluminationAnalyzer pour
    /// échantillonner l'évolution de la luminosité/couleur sur plusieurs images de la séquence).
    func isolateLuminousRegion(for detection: Detection, frames: [CapturedFrame]) -> LuminousRegion? {
        guard let frame = frames.min(by: { abs($0.timestamp - detection.timestamp) < abs($1.timestamp - detection.timestamp) })
        else { return nil }

        let ciImage = CIImage(cgImage: frame.image)
        let cropRect = pixelRect(for: detection.boundingBox, imageSize: CGSize(width: frame.image.width, height: frame.image.height))
        let cropped = ciImage.cropped(to: cropRect)

        // Seuillage de luminosité : ne garde que les pixels significativement plus clairs que la
        // moyenne locale, ce qui isole la source lumineuse propre de l'objet du reste du cadrage.
        let controls = CIFilter.colorControls()
        controls.inputImage = cropped
        controls.brightness = -0.3
        controls.contrast = 4.0
        guard let isolated = controls.outputImage else { return nil }

        guard let averages = try? averageLuminance(of: isolated) else { return nil }

        return LuminousRegion(
            boundingBoxInImage: cropRect,
            averageBrightness: averages.brightness,
            averageColor: averages.color
        )
    }

    /// Génère une approximation 3D très simplifiée : extrusion de la silhouette lumineuse 2D en un
    /// volume mince. Ce n'est PAS une reconstruction 3D véritable (celle-ci demanderait plusieurs
    /// points de vue simultanés ou un scan LiDAR rapproché) — seulement une aide visuelle pour la
    /// page de résultats, clairement présentée comme une approximation.
    func buildApproximate3DSilhouette(luminousRegion: LuminousRegion?) -> URL? {
        guard luminousRegion != nil else { return nil }
        // Implémentation réelle : RealityKit — ProceduralMesh généré à partir du masque de silhouette
        // (isolateLuminousRegion), extrudé sur une faible épaisseur, exporté en .usdz via
        // Entity.write(to:). Omis ici (dépend du runtime RealityKit, non disponible hors iOS).
        return nil
    }

    // MARK: - Signaux

    private func motionSignature(_ detections: [Detection]) -> MotionSignature {
        let centers = detections.map { CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY) }
        var directionChanges = 0
        var totalDisplacement: CGFloat = 0

        if centers.count > 2 {
            for i in 2..<centers.count {
                let v1 = CGVector(dx: centers[i-1].x - centers[i-2].x, dy: centers[i-1].y - centers[i-2].y)
                let v2 = CGVector(dx: centers[i].x - centers[i-1].x, dy: centers[i].y - centers[i-1].y)
                let dot = v1.dx * v2.dx + v1.dy * v2.dy
                if dot < 0 { directionChanges += 1 } // inversion de direction = battement/oscillation
                totalDisplacement += hypot(v2.dx, v2.dy)
            }
        }

        let oscillationRate = Double(directionChanges) / Double(max(centers.count - 2, 1))
        return MotionSignature(oscillationRate: oscillationRate, averageDisplacementPerFrame: Double(totalDisplacement) / Double(max(centers.count, 1)))
    }

    private func sizeSignature(_ detections: [Detection]) -> Double {
        let areas = detections.map { $0.boundingBox.width * $0.boundingBox.height }
        guard let mean = areas.isEmpty ? nil : areas.reduce(0, +) / CGFloat(areas.count), mean > 0 else { return 0 }
        let variance = areas.reduce(0) { $0 + pow($1 - mean, 2) } / CGFloat(areas.count)
        return Double(sqrt(variance) / mean) // coefficient de variation : 0 = taille parfaitement stable
    }

    private func heuristicClassify(motion: MotionSignature, sizeVariability: Double) -> (String, Double) {
        // Oscillation très fréquente + déplacement irrégulier de faible amplitude à l'écran =>
        // signature typique d'un insecte volant tout près de l'objectif (cause très fréquente de
        // faux signalements d'OVNI).
        if motion.oscillationRate > 0.5 && motion.averageDisplacementPerFrame < 0.05 {
            return ("Probable insecte proche de l'objectif", 0.55)
        }
        // Oscillation modérée et régulière => battements d'ailes, évoque un oiseau.
        if motion.oscillationRate > 0.2 && motion.oscillationRate <= 0.5 {
            return ("Probable oiseau (mouvement oscillant régulier)", 0.45)
        }
        // Déplacement très linéaire, taille stable => avion ou satellite à distance constante.
        if motion.oscillationRate < 0.1 && sizeVariability < 0.15 {
            return ("Probable avion ou satellite (trajectoire stable)", 0.4)
        }
        // Aucun signal net dominant => on ne force pas une conclusion.
        return ("Forme non identifiée avec certitude", 0.15)
    }

    // MARK: - Isolement de la zone lumineuse (voir la méthode publique isolateLuminousRegion ci-dessus)

    private func averageLuminance(of image: CIImage) throws -> (brightness: Double, color: (r: Double, g: Double, b: Double)) {
        let extentVector = CIVector(x: image.extent.origin.x, y: image.extent.origin.y, z: image.extent.size.width, w: image.extent.size.height)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: extentVector]),
              let outputImage = filter.outputImage else {
            return (0, (0, 0, 0))
        }
        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(outputImage, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let r = Double(bitmap[0]) / 255, g = Double(bitmap[1]) / 255, b = Double(bitmap[2]) / 255
        let brightness = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return (brightness, (r, g, b))
    }

    private func pixelRect(for normalizedBox: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: normalizedBox.origin.x * imageSize.width,
            y: (1 - normalizedBox.origin.y - normalizedBox.height) * imageSize.height,
            width: normalizedBox.width * imageSize.width,
            height: normalizedBox.height * imageSize.height
        )
    }
}

private struct MotionSignature {
    let oscillationRate: Double
    let averageDisplacementPerFrame: Double
}

struct LuminousRegion {
    let boundingBoxInImage: CGRect
    let averageBrightness: Double     // 0 (noir) à 1 (blanc pur)
    let averageColor: (r: Double, g: Double, b: Double)
}

struct ShapeResult {
    let label: String
    let confidence: Double
    let luminousRegion: LuminousRegion?
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
