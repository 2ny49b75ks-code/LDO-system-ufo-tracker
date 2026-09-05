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
    ///
    /// Reconnaissance par MOT-CLÉ dans l'étiquette plutôt que par correspondance exacte de chaîne —
    /// bug corrigé (2026-08-09, signalé par Jean-David sur un avion réel dont la vitesse et
    /// l'altitude sortaient très sous-estimées) : `ShapeClassifier.heuristicClassify` produit
    /// plusieurs variantes de libellé pour « avion » selon le signal qui a déclenché la détection
    /// (« trajectoire stable », « silhouette large, envergure d'ailes », « trajectoire continue »...)
    /// — une correspondance exacte par dictionnaire ne couvrait que la toute première variante et
    /// retombait silencieusement sur la fourchette générique « forme non identifiée » (0,5 à 15 m)
    /// pour toutes les autres, sous-estimant d'un facteur ~4 à 5× la taille réelle d'un avion (10 à
    /// 60 m) — et donc, en cascade, la distance, la vitesse et l'altitude estimées.
    private func assumedSize(for shapeLabel: String) -> Double {
        let range: ClosedRange<Double>
        if shapeLabel.contains("insecte") {
            range = 0.01...0.04
        } else if shapeLabel.contains("oiseau") {
            range = 0.2...1.0
        } else if shapeLabel.contains("avion") {
            range = 10...60
        } else {
            range = 0.5...15   // fourchette large faute d'hypothèse fiable (forme non identifiée)
        }
        return (range.lowerBound + range.upperBound) / 2
    }

    /// Vitesse réelle typique (km/h) selon le type d'objet — contrainte physique DIFFÉRENTE de la
    /// taille supposée (performance connue du type plutôt que ses dimensions), qui sert à recouper
    /// la distance par taille avec une deuxième estimation indépendante (voir `estimateDistanceAndAltitude`).
    /// Repères vérifiés par recherche (2026-08-09) : avion de ligne en vol 450-1000 km/h (croisière
    /// réelle 850-950 km/h, la borne basse couvre montée/approche) ; oiseau en vol de croisière
    /// 20-80 km/h. Pas de repère pour insecte/forme non identifiée — le recoupement ne s'applique pas
    /// à ces catégories (mouvement trop erratique près de l'objectif pour qu'une "vitesse typique"
    /// ait un sens physique comparable).
    private func typicalSpeedRangeKmh(for shapeLabel: String) -> ClosedRange<Double>? {
        if shapeLabel.contains("avion") { return 450...1000 }
        if shapeLabel.contains("oiseau") { return 20...80 }
        return nil
    }

    func estimateDistanceAndAltitude(
        detections: [Detection],
        frames: [CapturedFrame],
        shapeLabel: String,
        averageAngularVelocityDegPerS: Double? = nil
    ) -> DistanceResult {
        guard let midDetection = detections[safeIndex: detections.count / 2],
              let frame = frames.nearest(to: midDetection.timestamp)
        else {
            return DistanceResult(distanceMeters: nil, altitudeMeters: nil, confidence: 0, method: "Aucune donnée")
        }

        let assumedSizeMeters = assumedSize(for: shapeLabel)

        let apparentSizePixels = max(midDetection.boundingBox.width * Double(frame.image.width),
                                      midDetection.boundingBox.height * Double(frame.image.height))
        guard apparentSizePixels > 0 else {
            return DistanceResult(distanceMeters: nil, altitudeMeters: nil, confidence: 0, method: "Taille apparente nulle")
        }
        let focalLengthPixels = frame.intrinsics.map { Double($0.columns.0.x) }
            ?? Self.estimatedFocalLengthPixels(imageWidth: frame.image.width)
        let sizeBasedDistance = (assumedSizeMeters * focalLengthPixels) / apparentSizePixels

        // Confiance volontairement basse : dépend entièrement de l'exactitude de l'hypothèse de
        // taille réelle, qui n'est PAS mesurée mais supposée à partir d'une classification heuristique.
        var confidence = shapeLabel.contains("non identifiée") ? 0.15 : 0.3
        var method = "Triangulation angulaire (taille réelle supposée : \(String(format: "%.1f", assumedSizeMeters)) m)"
        var finalDistance = sizeBasedDistance
        var crossCheckAgrees: Bool? = nil

        // Recoupement par une DEUXIÈME méthode de distance, indépendante de la taille supposée :
        // distance = vitesse réelle typique du type détecté (m/s) / vitesse angulaire mesurée (rad/s).
        // Demande explicite de Jean-David (2026-08-09) : chaque type d'objet a ses propres
        // caractéristiques standard (forme, vitesse, G, etc.) — seule la distance varie d'une capture
        // à l'autre ; on peut donc s'en servir pour VALIDER la distance plutôt que de se fier à une
        // seule hypothèse (la taille). Si les deux méthodes concordent, la confiance augmente
        // (corroboration physique indépendante) ; si elles divergent fortement, ça révèle que l'objet
        // ne se comporte pas comme un membre typique du type classifié — un signal en soi, remonté
        // au verdict plutôt que caché derrière un chiffre de distance qui semblerait fiable.
        if let angularVelocity = averageAngularVelocityDegPerS, angularVelocity > 0,
           let speedRange = typicalSpeedRangeKmh(for: shapeLabel) {
            let typicalSpeedMS = ((speedRange.lowerBound + speedRange.upperBound) / 2) / 3.6
            let angularVelocityRadPerS = angularVelocity * .pi / 180
            let speedBasedDistance = typicalSpeedMS / angularVelocityRadPerS

            let ratio = max(speedBasedDistance, sizeBasedDistance) / min(speedBasedDistance, sizeBasedDistance)
            if ratio < 3 {
                finalDistance = (sizeBasedDistance + speedBasedDistance) / 2
                confidence = min(confidence + 0.15, 0.5)
                crossCheckAgrees = true
                method += " — recoupée avec la vitesse typique du type détecté (concordance)"
            } else {
                confidence = max(confidence - 0.1, 0.1)
                crossCheckAgrees = false
                method += " — ⚠️ ne concorde pas avec la vitesse typique attendue pour ce type"
            }
        }

        let altitude = altitudeFromDistance(finalDistance, frame: frame)

        return DistanceResult(
            distanceMeters: finalDistance,
            altitudeMeters: altitude,
            confidence: confidence,
            method: method,
            crossCheckAgrees: crossCheckAgrees
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
    /// `true` si la distance par taille supposée et la distance par vitesse typique du type détecté
    /// concordent (voir `DistanceEstimator.estimateDistanceAndAltitude`) ; `false` si elles divergent
    /// fortement ; `nil` si le recoupement ne s'applique pas (type sans vitesse typique connue, ou
    /// vitesse angulaire indisponible).
    var crossCheckAgrees: Bool? = nil
}

private extension Array {
    subscript(safeIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
