// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import CoreVideo
import ARKit

/// Étape 8 : distance et hauteur de l'objet.
///
/// DEUX MÉTHODES, SELON LA PORTÉE :
/// 1. **LiDAR direct** (fiable, haute confiance) — valide seulement si l'objet est à moins de
///    ~5-8 mètres de la caméra, portée réelle du capteur LiDAR de l'iPhone. Utile par exemple
///    pour un objet manipulé de près, pas pour un objet dans le ciel.
/// 2. **Triangulation angulaire** (estimation, confiance faible à modérée) — utilisée pour tout
///    objet hors de portée LiDAR. Elle suppose une taille réelle probable de l'objet (déduite de
///    la classification heuristique de forme, étape 3) et calcule la distance nécessaire pour
///    que cette taille produise l'angle apparent mesuré à l'écran :
///    distance = (taille réelle supposée × focale en pixels) / taille apparente en pixels.
///    Cette méthode est intrinsèquement approximative : une erreur sur la taille réelle supposée
///    se répercute directement et proportionnellement sur la distance estimée.
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

        // 1. Tentative LiDAR direct.
        if let lidarDistance = directLidarDistance(box: midDetection.boundingBox, depthMap: frame.depthMap),
           lidarDistance < 8.0 {
            let altitude = altitudeFromDistance(lidarDistance, frame: frame)
            return DistanceResult(distanceMeters: lidarDistance, altitudeMeters: altitude, confidence: 0.9, method: "Mesure LiDAR directe")
        }

        // 2. Repli sur la triangulation angulaire.
        let sizeRange = assumedSizes[shapeLabel] ?? 0.5...15
        let assumedSize = (sizeRange.lowerBound + sizeRange.upperBound) / 2

        let apparentSizePixels = max(midDetection.boundingBox.width * Double(frame.image.width),
                                      midDetection.boundingBox.height * Double(frame.image.height))
        guard apparentSizePixels > 0 else {
            return DistanceResult(distanceMeters: nil, altitudeMeters: nil, confidence: 0, method: "Taille apparente nulle")
        }
        let focalLengthPixels = Double(frame.intrinsics.columns.0.x)
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

    // MARK: - LiDAR direct

    private func directLidarDistance(box: CGRect, depthMap: CVPixelBuffer?) -> Double? {
        guard let depthMap else { return nil }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let x = Int(box.midX * Double(width))
        let y = Int((1 - box.midY) * Double(height))
        guard x >= 0, x < width, y >= 0, y < height,
              let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let floatBuffer = base.assumingMemoryBound(to: Float32.self)
        let value = floatBuffer[y * (bytesPerRow / MemoryLayout<Float32>.size) + x]
        guard value.isFinite, value > 0 else { return nil }
        return Double(value)
    }

    // MARK: - Altitude

    /// Altitude approximative = distance × sin(angle d'élévation de la caméra), déduit de
    /// l'orientation de la caméra (pose ARKit) au moment de la capture.
    private func altitudeFromDistance(_ distance: Double, frame: CapturedFrame) -> Double {
        let forward = SIMD3<Double>(
            -Double(frame.cameraTransform.columns.2.x),
            -Double(frame.cameraTransform.columns.2.y),
            -Double(frame.cameraTransform.columns.2.z)
        )
        let elevationRadians = asin(max(-1, min(1, forward.y)))
        return distance * sin(elevationRadians)
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
