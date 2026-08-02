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
/// distance elle-même reste une estimation (hors portée LiDAR au-delà de ~5 m).
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
        let max = velocitiesKmh.map { $0.value }.max() ?? 0
        let isStationary = max < stationaryThresholdKmh

        // 2. Accélération linéaire (m/s²) entre échantillons consécutifs de vitesse.
        var accelerations: [Double] = []
        for i in 1..<velocitiesKmh.count {
            let dt = velocitiesKmh[i].timestamp - velocitiesKmh[i - 1].timestamp
            guard dt > 0.001 else { continue }
            let dvMetersPerSecond = (velocitiesKmh[i].value - velocitiesKmh[i - 1].value) / 3.6
            accelerations.append(abs(dvMetersPerSecond / dt))
        }
        let maxAcceleration = accelerations.max() ?? 0

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

    /// Étiquette informative comparant la vitesse à des repères connus. Purement indicative :
    /// ne sert pas à trancher seule le verdict final, seulement à donner un contexte à l'utilisateur.
    private func comparisonLabel(for maxKmh: Double, isStationary: Bool) -> String {
        if isStationary { return "Objet stationnaire (pas de déplacement mesurable)" }
        switch maxKmh {
        case ..<80: return "Comparable à un drone de loisir ou un oiseau (<80 km/h)"
        case 80..<300: return "Comparable à un petit avion ou hélicoptère (80-300 km/h)"
        case 300..<1000: return "Comparable à un avion de ligne en croisière (300-1000 km/h)"
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
