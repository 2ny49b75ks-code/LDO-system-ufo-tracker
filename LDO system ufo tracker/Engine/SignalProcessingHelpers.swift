// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation

/// Consolide trois algorithmes qui existaient auparavant en plusieurs copies quasi identiques à
/// travers le pipeline d'analyse (relevé par la revue de code du 2026-08-27) — un correctif futur à
/// l'un de ces algorithmes n'a désormais qu'un seul endroit à toucher, au lieu de risquer d'en oublier
/// une copie et de faire silencieusement diverger le comportement entre deux fichiers.

/// Tout type porteur d'un horodatage — `CapturedFrame`, `Detection`, `PersistedFramePose`.
protocol Timestamped {
    var timestamp: TimeInterval { get }
}

extension Array where Element: Timestamped {
    /// Élément le plus proche en temps de `timestamp` — remplace 5 réécritures indépendantes de
    /// `min(by: { abs($0.timestamp - t) < abs($1.timestamp - t) })` à travers le projet
    /// (`DistanceEstimator`, `TrajectoryCalculator`, `PhotoComposer`, `ShapeClassifier`,
    /// `VideoFrameExtractor`).
    func nearest(to timestamp: TimeInterval) -> Element? {
        self.min { abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp) }
    }
}

/// Moyenne glissante centrée générique — remplace 3 copies quasi identiques (`ShapeClassifier.
/// smoothedCenters` sur `[CGPoint]`, `TrajectoryCalculator.smooth` sur `[AngularSample]`,
/// `SpeedCalculator.movingAverage` sur `[TimedValue]`), qui ne différaient que par la façon de
/// moyenner un élément (chacune fournie ici via la closure `average`). `average` reçoit l'index
/// D'ORIGINE `i` (pour conserver, par exemple, l'horodatage exact de cet élément plutôt qu'une
/// moyenne des horodatages de la fenêtre) et la tranche `[lo...hi]` centrée sur `i`.
func centeredMovingAverage<T>(_ values: [T], window: Int, average: (_ index: Int, _ slice: ArraySlice<T>) -> T) -> [T] {
    guard values.count > window else { return values }
    var result: [T] = []
    result.reserveCapacity(values.count)
    for i in 0..<values.count {
        let lo = max(0, i - window / 2)
        let hi = min(values.count - 1, i + window / 2)
        result.append(average(i, values[lo...hi]))
    }
    return result
}

/// Pic « robuste » : ne retient un pic de la série que s'il est corroboré par l'échantillon voisin
/// (même ordre de grandeur sur 2 échantillons consécutifs, pas juste 1) — filtre le bruit d'un seul
/// écart de détection isolé sans écraser une vraie variation soutenue sur plusieurs images. Remplace
/// 2 copies indépendantes (`TrajectoryCalculator.robustPeak`, `SpeedCalculator.robustPeak`) dont l'une
/// avait fini par diverger de l'autre (`abs()` manquant, corrigé le 2026-08-27 avant cette
/// consolidation). Corrige un bug réel (signalé par Jean-David, 2026-08-09) : un avion volant en ligne
/// quasi parfaitement droite affichait ~427,9 G / une accélération aberrante, provenant d'un unique
/// écart de détection isolé sur une image, pas d'un vrai virage/changement de vitesse.
/// Base de comparaison commune (secondes), PAS un simple pas d'une image à l'autre — remplace la même
/// constante `0.25` déclarée indépendamment sous 2 noms différents (`curvatureBaselineSeconds` dans
/// `TrajectoryCalculator`, `accelerationBaselineSeconds` dans `SpeedCalculator`). BUG corrigé
/// (2026-08-25, découvert via un harnais de test numérique reproduisant un scénario réel signalé par
/// Jean-David : un avion de ligne à ~7 km, vitesse mesurée correcte à 539 km/h, déclenchait encore
/// ~13 600 G / ~1526 m/s² même après un premier correctif) : comparer deux échantillons consécutifs
/// (~1/12s d'écart) rend une mesure de changement extrêmement instable dès que le déplacement RÉEL par
/// image est du même ordre de grandeur que le bruit de suivi — cas typique d'un objet lointain qui
/// bouge lentement à l'écran malgré une vraie vitesse élevée. Élargir la base à ~0.25s accumule le
/// vrai signal tout en moyennant le bruit indépendant d'une image à l'autre.
let noiseAveragingBaselineSeconds: Double = 0.25

/// Nombre d'échantillons correspondant à `noiseAveragingBaselineSeconds`, déduit de l'intervalle moyen
/// entre les horodatages fournis — remplace 3 dérivations indépendantes du même calcul (2 dans
/// `TrajectoryCalculator`, 1 dans `SpeedCalculator`).
func robustStrideCount(forTimestamps timestamps: [TimeInterval]) -> Int {
    guard timestamps.count > 1, let first = timestamps.first, let last = timestamps.last else { return 1 }
    let averageDt = (last - first) / Double(timestamps.count - 1)
    guard averageDt > 0 else { return 1 }
    return max(1, Int((noiseAveragingBaselineSeconds / averageDt).rounded()))
}

func robustPeak(_ values: [Double]) -> Double {
    guard values.count >= 2 else { return values.first.map { abs($0) } ?? 0 }
    var corroboratedPeaks: [Double] = []
    corroboratedPeaks.reserveCapacity(values.count - 1)
    for i in 1..<values.count {
        corroboratedPeaks.append(min(abs(values[i - 1]), abs(values[i])))
    }
    return corroboratedPeaks.max() ?? 0
}
