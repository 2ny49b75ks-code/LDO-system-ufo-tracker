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
        // Un vrai virage brusque confirmé (>30°, voir TrajectoryCalculator.detectSharpTurns) sert de
        // corroboration indépendante : une accélération soutenue n'est physiquement plausible QUE
        // pendant un virage réel. Sans virage confirmé, la trajectoire est essentiellement stable
        // (vitesse constante) — voir le calcul de `maxAcceleration` ci-dessous.
        let hasGenuineSharpTurn = !trajectory.curvatureEvents.isEmpty
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

        // 2. Accélération linéaire (m/s²), sur une base élargie (~0.25s) plutôt qu'un simple pas
        //    d'une image à l'autre. BUG corrigé (2026-08-25, découvert via un harnais de test
        //    numérique reproduisant le scénario réel signalé par Jean-David — un avion en vol
        //    parfaitement droit affichait encore ~1526 m/s² même après le premier correctif ci-
        //    dessous) : même la MÉDIANE d'une série calculée image par image reste dominée par le
        //    bruit quand le déplacement RÉEL par image est du même ordre de grandeur que le bruit de
        //    suivi — la médiane filtre les valeurs isolées, pas un bruit systématiquement présent sur
        //    TOUTE la série. Même principe que le correctif de
        //    `TrajectoryCalculator.detectSharpTurns` : élargir la base de comparaison accumule le
        //    vrai signal de vitesse tout en moyennant le bruit indépendant d'une image à l'autre.
        let accelerationBaselineSeconds = 0.25
        let velocityDuration = (velocitiesKmh.last?.timestamp ?? 0) - (velocitiesKmh.first?.timestamp ?? 0)
        let averageVelocityDt = velocitiesKmh.count > 1 ? velocityDuration / Double(velocitiesKmh.count - 1) : 0
        // `Swift.max` explicite : le nom local `max` (vitesse maximale, voir plus haut) masque sinon
        // la fonction globale `max(_:_:)` dans cette portée.
        let accelerationStride = averageVelocityDt > 0 ? Swift.max(1, Int((accelerationBaselineSeconds / averageVelocityDt).rounded())) : 1

        // Lissage léger (moyenne glissante sur 3 échantillons), UNIQUEMENT pour cette dérivée
        // d'accélération — la série `velocitiesKmh` brute reste inchangée pour l'affichage
        // vitesse moyenne/max ci-dessus (voir le commentaire sur `robustPeak` : préserver les vrais
        // pics de vitesse instantanée y reste voulu). Nécessaire en plus de la base élargie
        // ci-dessus (2026-08-25, même harnais de test que ci-dessus) : élargir seul la base de
        // comparaison ne suffit pas quand le bruit de suivi est présent sur TOUTE la série de
        // vitesse (pas un simple écart isolé) — un vol à vitesse constante peut alors encore
        // afficher plusieurs centaines de m/s² même sur une différence à 0,25s d'écart. Un lissage
        // à 3 échantillons avant cette différence élimine ce bruit systématique sans masquer une
        // vraie variation soutenue (qui reste, elle, présente sur plusieurs échantillons consécutifs
        // même après moyenne).
        let smoothedVelocities = Self.movingAverage(velocitiesKmh, window: 3)

        var accelerations: [Double] = []
        if smoothedVelocities.count > accelerationStride {
            for i in accelerationStride..<smoothedVelocities.count {
                let dt = smoothedVelocities[i].timestamp - smoothedVelocities[i - accelerationStride].timestamp
                guard dt > 0.001 else { continue }
                let dvMetersPerSecond = (smoothedVelocities[i].value - smoothedVelocities[i - accelerationStride].value) / 3.6
                accelerations.append(abs(dvMetersPerSecond / dt))
            }
        }
        // Pic "robuste" plutôt que le simple maximum brut : une dérivée seconde calculée sur des
        // échantillons image par image est extrêmement sensible à un seul écart de suivi isolé (même
        // bug que celui corrigé pour les forces G dans TrajectoryCalculator.robustPeak — voir ce
        // commentaire pour le détail). Corrige un cas réel (signalé par Jean-David, 2026-08-09) : un
        // avion volant à vitesse quasi constante affichait ~4197 m/s² d'accélération, provenant d'un
        // unique écart de détection sur une image, pas d'une vraie variation de vitesse soutenue.
        //
        // ANCRAGE SUR UN VRAI VIRAGE (2026-08-25, signalé par Jean-David : un avion de ligne en vol
        // parfaitement droit, vitesse mesurée cohérente à 539 km/h, affichait encore ~769 m/s²
        // soutenus, un résultat non physique) : même après `robustPeak`, le bruit corrélé d'une
        // dérivée seconde image par image reste suffisant pour franchir le seuil "soutenu" 2
        // échantillons de suite. Sans virage brusque confirmé par ailleurs (`hasGenuineSharpTurn`),
        // on retient la MÉDIANE des échantillons plutôt que leur maximum : un vol à vitesse constante
        // a une accélération réelle proche de 0 par définition, la médiane reflète ça correctement
        // là où le maximum reste dominé par le bruit résiduel.
        // Retombée à 0 (pas la médiane) sans virage confirmé (2026-08-25, même harnais de test que
        // ci-dessus — même en lissant ET en élargissant la base, un bruit de suivi soutenu sur toute
        // la série laissait encore une centaine de m/s² résiduels, un chiffre encore trompeur affiché
        // à côté d'un objet déjà identifié comme un aéronef connu). Même principe que le G-force dans
        // `TrajectoryCalculator` : l'absence de virage brusque confirmé est la preuve la plus directe
        // disponible qu'il n'y a pas d'accélération réelle — à vitesse constante, l'accélération
        // linéaire est 0 par définition. Le chiffre lissé/élargi ci-dessus reste utile pour la
        // détection de "performance impossible" ci-dessous (comparaison à un seuil, pas un affichage
        // brut), mais n'est plus présenté comme LA valeur d'accélération sans corroboration géométrique.
        let maxAcceleration: Double = hasGenuineSharpTurn ? Self.robustPeak(accelerations) : 0

        // 3. "Défie la physique" seulement si l'accélération extrême est SOUTENUE (au moins 2 échantillons
        //    consécutifs) ET corroborée par un vrai virage détecté indépendamment — un pic isolé, même
        //    soutenu sur 2 échantillons consécutifs de la même dérivée bruitée, reste plus probablement
        //    une erreur de suivi qu'une vraie variation de vitesse en l'absence de tout virage confirmé.
        let sustainedExtreme = hasGenuineSharpTurn && accelerations.enumerated().contains { index, value in
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
        // BUG CORRIGÉ (revue de code du 2026-08-27) : cette copie omettait le `abs()` déjà présent
        // dans l'implémentation jumelle de `TrajectoryCalculator.robustPeak` (même algorithme,
        // dupliqué dans les deux fichiers) — sans lui, une série qui peut aller au négatif ferait
        // gagner la paire la PLUS négative au lieu du plus grand pic en magnitude.
        guard values.count >= 2 else { return values.first.map { abs($0) } ?? 0 }
        var corroboratedPeaks: [Double] = []
        for i in 1..<values.count {
            corroboratedPeaks.append(min(abs(values[i-1]), abs(values[i])))
        }
        return corroboratedPeaks.max() ?? 0
    }

    /// Moyenne glissante centrée — voir le commentaire au point d'appel (calcul de l'accélération
    /// linéaire) pour pourquoi ce lissage supplémentaire est nécessaire en plus de la base élargie.
    private static func movingAverage(_ series: [TimedValue], window: Int) -> [TimedValue] {
        guard series.count > window else { return series }
        var result: [TimedValue] = []
        for i in 0..<series.count {
            let lo = max(0, i - window / 2)
            let hi = min(series.count - 1, i + window / 2)
            let slice = series[lo...hi]
            let avg = slice.reduce(0) { $0 + $1.value } / Double(slice.count)
            result.append(TimedValue(timestamp: series[i].timestamp, value: avg))
        }
        return result
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
