// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation

/// Calcule la vitesse réelle de l'objet (étape 6 du pipeline LDO), à partir de la trajectoire
/// angulaire déjà produite par TrajectoryCalculator.
///
/// PRINCIPE : la caméra ne mesure qu'un déplacement ANGULAIRE (des degrés par seconde dans le ciel).
/// Pour obtenir une vitesse en km/h, il faut la distance à l'objet : v (m/s) = distance (m) × vitesse
/// angulaire (rad/s). C'est pourquoi, comme pour les forces G, la vitesse en km/h n'est affichée
/// qu'accompagnée d'un indice de confiance — jamais présentée comme une mesure certaine tant que la
/// distance elle-même reste une estimation (triangulation angulaire, pas de mesure directe).
final class SpeedCalculator {

    /// Seuil en-dessous duquel l'objet est considéré comme stationnaire (dérive de trajectoire due
    /// au bruit de détection, pas à un vrai déplacement).
    private let stationaryThresholdKmh: Double = 3.0

    /// Accélération linéaire soutenue (m/s²) au-delà de laquelle la performance dépasse ce qu'un
    /// avion ou drone connu peut réaliser en vol horizontal. Repère indicatif seulement (~10 G soutenus).
    private let physicallyImplausibleAccelerationMS2: Double = 100.0

    func estimateSpeed(trajectory: TrajectoryResult, distanceMeters: Double?) -> SpeedResult {
        guard let distance = distanceMeters, distance > 0, !trajectory.angularVelocitiesDegPerS.isEmpty else {
            // Sans distance fiable, impossible de convertir des degrés/seconde en km/h de façon
            // physiquement valable : on ne calcule PAS de chiffre, on le signale clairement.
            return SpeedResult(
                averageKmh: 0, maxKmh: 0, isStationary: false,
                maxAccelerationMS2: 0, accelerationImpliesImpossiblePerformance: false,
                confidence: 0, comparisonLabel: "Vitesse non calculable (distance à l'objet trop incertaine)"
            )
        }

        // 1. Conversion degrés/seconde -> km/h à distance constante estimée.
        let velocitiesKmh: [TimedValue] = trajectory.angularVelocitiesDegPerS.map { sample in
            let radPerSecond = sample.value * .pi / 180
            let metersPerSecond = distance * radPerSecond
            return TimedValue(timestamp: sample.timestamp, value: metersPerSecond * 3.6)
        }

        let average = velocitiesKmh.map { $0.value }.reduce(0, +) / Double(velocitiesKmh.count)
        // Pic "robuste" plutôt que le simple maximum brut — même bug que celui corrigé ci-dessous
        // pour l'accélération (voir `robustPeak`) : un seul écart de suivi isolé sur une image (le
        // tracker qui accroche un instant le bord d'une traînée de condensation, par ex.) suffit à
        // produire un pic de vitesse instantanée aberrant, sans rapport avec le déplacement réel de
        // l'objet. Corrige un cas réel (signalé par Jean-David, 2026-08-09) : une vitesse moyenne de
        // 132 km/h contre un maximum de 1302 km/h sur la même vidéo — un écart de 10× entre les deux
        // est la signature d'un point isolé, pas d'une vraie pointe de vitesse soutenue.
        let max = Self.robustPeak(velocitiesKmh.map { $0.value })
        let isStationary = max < stationaryThresholdKmh

        // 2. Accélération linéaire (m/s²) entre échantillons consécutifs de vitesse.
        var accelerations: [Double] = []
        for i in 1..<velocitiesKmh.count {
            let dt = velocitiesKmh[i].timestamp - velocitiesKmh[i - 1].timestamp
            guard dt > 0.001 else { continue }
            let dvMetersPerSecond = (velocitiesKmh[i].value - velocitiesKmh[i - 1].value) / 3.6
            accelerations.append(abs(dvMetersPerSecond / dt))
        }
        // Pic "robuste" plutôt que le simple maximum brut : une dérivée seconde calculée sur des
        // échantillons image par image est extrêmement sensible à un seul écart de suivi isolé (même
        // bug que celui corrigé pour les forces G dans TrajectoryCalculator.robustPeak — voir ce
        // commentaire pour le détail). Corrige un cas réel (signalé par Jean-David, 2026-08-09) : un
        // avion volant à vitesse quasi constante affichait ~4197 m/s² d'accélération, provenant d'un
        // unique écart de détection sur une image, pas d'une vraie variation de vitesse soutenue.
        let maxAcceleration = Self.robustPeak(accelerations)

        // 3. "Défie la physique" seulement si l'accélération extrême est SOUTENUE (au moins 2 échantillons
        //    consécutifs), pas un pic isolé qui serait plus probablement une erreur de détection.
        let sustainedExtreme = accelerations.enumerated().contains { index, value in
            guard value > physicallyImplausibleAccelerationMS2, index > 0 else { return false }
            return accelerations[index - 1] > physicallyImplausibleAccelerationMS2
        }

        return SpeedResult(
            averageKmh: average,
            maxKmh: max,
            isStationary: isStationary,
            maxAccelerationMS2: maxAcceleration,
            accelerationImpliesImpossiblePerformance: sustainedExtreme,
            confidence: trajectory.gForceConfidence,   // même confiance que le calcul de G, car dérivée de la même distance estimée
            comparisonLabel: comparisonLabel(for: max, isStationary: isStationary)
        )
    }

    /// Ne retient un pic de la série que s'il est corroboré par l'échantillon voisin (même ordre de
    /// grandeur sur 2 échantillons consécutifs, pas juste 1) — filtre le bruit d'un seul écart de
    /// détection isolé sans écraser une vraie variation soutenue sur plusieurs images. Voir le
    /// commentaire au point d'appel.
    private static func robustPeak(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return values.first ?? 0 }
        var corroboratedPeaks: [Double] = []
        for i in 1..<values.count {
            corroboratedPeaks.append(min(values[i-1], values[i]))
        }
        return corroboratedPeaks.max() ?? 0
    }

    /// Étiquette informative comparant la vitesse à des repères connus. Purement indicative :
    /// ne sert pas à trancher seule le verdict final, seulement à donner un contexte à l'utilisateur.
    /// Fourchette avion de ligne corrigée à 450-1000 km/h (2026-08-09, précisé par Jean-David) — 300
    /// km/h correspond plutôt à une phase d'approche/atterrissage qu'à un vol de croisière.
    private func comparisonLabel(for maxKmh: Double, isStationary: Bool) -> String {
        if isStationary { return "Objet stationnaire (pas de déplacement mesurable)" }
        switch maxKmh {
        case ..<80: return "Comparable à un drone de loisir ou un oiseau (<80 km/h)"
        case 80..<450: return "Comparable à un petit avion ou hélicoptère (80-450 km/h)"
        case 450..<1000: return "Comparable à un avion de ligne en croisière (450-1000 km/h)"
        case 1000..<3000: return "Supérieur à un avion de ligne, comparable à un avion militaire rapide"
        default: return "Vitesse très supérieure aux aéronefs connus à cette distance estimée"
        }
    }
}

struct SpeedResult {
    var averageKmh: Double
    var maxKmh: Double
    var isStationary: Bool
    var maxAccelerationMS2: Double
    var accelerationImpliesImpossiblePerformance: Bool
    var confidence: Double
    var comparisonLabel: String
}
