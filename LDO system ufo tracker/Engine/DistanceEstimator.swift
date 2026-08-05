// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import CoreGraphics
import simd

/// Étape 8 : distance et hauteur de l'objet, par **triangulation angulaire** uniquement — pas de
/// LiDAR, dont la portée réelle (~5-8 m) est bien trop courte pour un objet aérien observé à
/// grande distance (le cas quasi systématique en observation de phénomène dans le ciel).
///
/// La triangulation suppose une taille réelle probable de l'objet (déduite de la classification
/// heuristique de forme, étape 3) et calcule la distance nécessaire pour que cette taille produise
/// l'angle apparent mesuré à l'écran :
/// distance = (taille réelle supposée × focale en pixels) / taille apparente en pixels.
/// Cette méthode est intrinsèquement approximative : une erreur sur la taille réelle supposée
/// se répercute directement et proportionnellement sur la distance estimée — d'où la confiance
/// volontairement basse (voir `confidence` ci-dessous), affichée telle quelle à l'utilisateur.
final class DistanceEstimator {

    /// Tailles réelles typiques (en mètres, plus grande dimension) utilisées comme hypothèse selon
    /// la forme heuristique détectée à l'étape 3. Purement indicatif — la principale source
    /// d'incertitude du calcul.
    private let assumedSizes: [String: ClosedRange<Double>] = [
        "Probable insecte proche de l'objectif": 0.01...0.04,
        "Probable oiseau (mouvement oscillant régulier)": 0.2...1.0,
        "Probable avion ou satellite (trajectoire stable)": 10...60,
        "Forme non identifiée avec certitude": 0.5...15   // fourchette large faute d'hypothèse fiable
    ]

    func estimateDistanceAndAltitude(
        detections: [Detection],
        frames: [CapturedFrame],
        shapeLabel: String
    ) -> DistanceResult {
        guard let midDetection = detections[safeIndex: detections.count / 2],
              let frame = frames.min(by: { abs($0.timestamp - midDetection.timestamp) < abs($1.timestamp - midDetection.timestamp) })
        else {
            return DistanceResult(distanceMeters: nil, altitudeMeters: nil, confidence: 0, method: "Aucune donnée")
        }

        let sizeRange = assumedSizes[shapeLabel] ?? 0.5...15
        let assumedSize = (sizeRange.lowerBound + sizeRange.upperBound) / 2

        let apparentSizePixels = max(midDetection.boundingBox.width * Double(frame.image.width),
                                      midDetection.boundingBox.height * Double(frame.image.height))
        guard apparentSizePixels > 0 else {
            return DistanceResult(distanceMeters: nil, altitudeMeters: nil, confidence: 0, method: "Taille apparente nulle")
        }
        let focalLengthPixels = frame.intrinsics.map { Double($0.columns.0.x) }
            ?? Self.estimatedFocalLengthPixels(imageWidth: frame.image.width)
        let estimatedDistance = (assumedSize * focalLengthPixels) / apparentSizePixels
        let altitude = altitudeFromDistance(estimatedDistance, frame: frame)

        // Confiance volontairement basse : dépend entièrement de l'exactitude de l'hypothèse de
        // taille réelle, qui n'est PAS mesurée mais supposée à partir d'une classification heuristique.
        let confidence = shapeLabel.contains("non identifiée") ? 0.15 : 0.3

        return DistanceResult(
            distanceMeters: estimatedDistance,
            altitudeMeters: altitude,
            confidence: confidence,
            method: "Triangulation angulaire (taille réelle supposée : \(String(format: "%.1f", assumedSize)) m)"
        )
    }

    // MARK: - Altitude

    /// Altitude approximative = distance × sin(angle d'élévation de la caméra), déduit de
    /// l'orientation de la caméra (pose ARKit) au moment de la capture. `nil` si cette image n'a
    /// pas de pose ARKit associée (vidéo importée depuis la bibliothèque) : l'angle d'élévation
    /// n'est alors pas connu, donc l'altitude ne peut pas être estimée du tout (contrairement à la
    /// distance, qui reste calculable par triangulation avec une focale supposée).
    private func altitudeFromDistance(_ distance: Double, frame: CapturedFrame) -> Double? {
        guard let cameraTransform = frame.cameraTransform else { return nil }
        let forward = SIMD3<Double>(
            -Double(cameraTransform.columns.2.x),
            -Double(cameraTransform.columns.2.y),
            -Double(cameraTransform.columns.2.z)
        )
        let elevationRadians = asin(max(-1, min(1, forward.y)))
        return distance * sin(elevationRadians)
    }

    /// Sans intrinsèques ARKit (vidéo importée depuis la bibliothèque, sans métadonnées de pose),
    /// on suppose un champ de vision horizontal typique de caméra arrière de smartphone (~60°) pour
    /// pouvoir quand même produire une distance approximative — avec une confiance déjà volontairement
    /// basse (voir `confidence` ci-dessus), cette hypothèse supplémentaire n'aggrave pas la fiabilité
    /// affichée, juste sa marge d'erreur réelle.
    private static func estimatedFocalLengthPixels(imageWidth: Int) -> Double {
        let assumedHorizontalFOVRadians = 60.0 * Double.pi / 180
        return Double(imageWidth) / (2 * tan(assumedHorizontalFOVRadians / 2))
    }
}

struct DistanceResult {
    let distanceMeters: Double?
    let altitudeMeters: Double?
    let confidence: Double
    let method: String
}

private extension Array {
    subscript(safeIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
