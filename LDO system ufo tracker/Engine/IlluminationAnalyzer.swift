// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation

/// Étape 5 : illumination et couleur.
/// Utilise la zone lumineuse isolée par ShapeClassifier (étape 3) sur plusieurs images pour
/// déterminer si l'éclairage est continu ou variable, et estimer sa température de couleur —
/// un indice utile pour distinguer une source lumineuse propre (LED, feu de navigation) d'un
/// simple reflet du soleil sur une surface métallique.
final class IlluminationAnalyzer {

    /// Variation de luminosité (coefficient de variation) au-delà de laquelle on considère
    /// l'illumination comme "variable / clignotante" plutôt que continue.
    private let variabilityThreshold: Double = 0.25

    func analyzeIllumination(luminousRegionsOverTime: [(timestamp: TimeInterval, region: LuminousRegion)]) -> IlluminationResult {
        guard !luminousRegionsOverTime.isEmpty else {
            return IlluminationResult(pattern: "Indéterminé (zone lumineuse non isolée)", colorGuess: "Indéterminé", estimatedKelvin: nil, blinkFrequencyHz: nil, isRegularBlink: false)
        }

        // 1. Pattern : continu vs variable, à partir de la luminosité moyenne dans le temps.
        let brightnesses = luminousRegionsOverTime.map { $0.region.averageBrightness }
        let mean = brightnesses.reduce(0, +) / Double(brightnesses.count)
        let variance = brightnesses.reduce(0) { $0 + pow($1 - mean, 2) } / Double(brightnesses.count)
        let coefficientOfVariation = mean > 0 ? sqrt(variance) / mean : 0
        let isVariable = coefficientOfVariation > variabilityThreshold

        // 2. Si variable, estimation de la fréquence de clignotement ET de sa régularité, par
        //    comptage des passages sous/au-dessus de la moyenne (méthode des passages par zéro) —
        //    voir `blinkStatistics` : distingue un clignotement quasi périodique (feu stroboscopique
        //    d'aéronef/drone, intervalles réguliers) d'un scintillement erratique (intervalles très
        //    irréguliers), utilisé par `VerdictCalculator` pour les règles spécifiques au Mode Nuit.
        let blinkStats = isVariable ? blinkStatistics(luminousRegionsOverTime) : (frequencyHz: nil, isRegular: false)

        // 3. Température de couleur approximative (formule de McCamy) à partir de la couleur RVB
        //    moyenne de la zone lumineuse, moyennée sur toutes les images disponibles.
        let avgColor = averageColor(luminousRegionsOverTime.map { $0.region.averageColor })
        let kelvin = approximateColorTemperature(r: avgColor.r, g: avgColor.g, b: avgColor.b)

        let pattern: String
        if isVariable {
            let frequencySuffix = blinkStats.frequencyHz.map { String(format: " (≈ %.1f Hz)", $0) } ?? ""
            pattern = blinkStats.isRegular
                ? "Clignotante régulière" + frequencySuffix
                : "Variable / scintillante irrégulière" + frequencySuffix
        } else {
            pattern = "Continue"
        }

        let colorGuess = interpretColor(kelvin: kelvin)

        return IlluminationResult(
            pattern: pattern,
            colorGuess: colorGuess,
            estimatedKelvin: kelvin,
            blinkFrequencyHz: blinkStats.frequencyHz,
            isRegularBlink: blinkStats.isRegular
        )
    }

    // MARK: - Détail

    /// Fréquence de clignotement (méthode des passages par zéro) + régularité : coefficient de
    /// variation des intervalles entre passages successifs. Un feu stroboscopique d'aéronef/drone
    /// clignote à intervalles quasi identiques (CV faible) ; un scintillement erratique produit des
    /// intervalles très inégaux (CV élevé). Seuil `0.35` choisi empiriquement — pas une mesure
    /// physique exacte, juste un ordre de grandeur suffisant pour distinguer les deux cas.
    private func blinkStatistics(_ samples: [(timestamp: TimeInterval, region: LuminousRegion)]) -> (frequencyHz: Double?, isRegular: Bool) {
        guard samples.count >= 4 else { return (nil, false) }
        let mean = samples.map { $0.region.averageBrightness }.reduce(0, +) / Double(samples.count)
        var crossingTimestamps: [TimeInterval] = []
        for i in 1..<samples.count {
            let previousAbove = samples[i-1].region.averageBrightness > mean
            let currentAbove = samples[i].region.averageBrightness > mean
            if previousAbove != currentAbove { crossingTimestamps.append(samples[i].timestamp) }
        }
        let duration = samples.last!.timestamp - samples.first!.timestamp
        guard duration > 0, crossingTimestamps.count >= 2 else { return (nil, false) }
        // 2 passages par zéro = 1 cycle complet.
        let frequency = (Double(crossingTimestamps.count) / 2.0) / duration

        var intervals: [TimeInterval] = []
        for i in 1..<crossingTimestamps.count {
            intervals.append(crossingTimestamps[i] - crossingTimestamps[i - 1])
        }
        guard intervals.count >= 2 else { return (frequency, false) }
        let intervalMean = intervals.reduce(0, +) / Double(intervals.count)
        guard intervalMean > 0 else { return (frequency, false) }
        let intervalVariance = intervals.reduce(0) { $0 + pow($1 - intervalMean, 2) } / Double(intervals.count)
        let intervalCV = sqrt(intervalVariance) / intervalMean
        return (frequency, intervalCV < 0.35)
    }

    private func averageColor(_ colors: [(r: Double, g: Double, b: Double)]) -> (r: Double, g: Double, b: Double) {
        let count = Double(colors.count)
        guard count > 0 else { return (1, 1, 1) }
        let r = colors.reduce(0) { $0 + $1.r } / count
        let g = colors.reduce(0) { $0 + $1.g } / count
        let b = colors.reduce(0) { $0 + $1.b } / count
        return (r, g, b)
    }

    /// Approximation de McCamy : convertit une couleur RVB en une température de couleur corrélée
    /// (en Kelvin), via l'espace de chromaticité CIE xy. Donne un ordre de grandeur, pas une mesure
    /// spectrométrique précise — suffisant pour distinguer "blanc froid type LED" de "orangé type
    /// reflet solaire au crépuscule".
    private func approximateColorTemperature(r: Double, g: Double, b: Double) -> Double {
        // Conversion sRGB -> XYZ (approximation linéaire, sans correction gamma complète — suffisant ici).
        let x = 0.4124 * r + 0.3576 * g + 0.1805 * b
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = 0.0193 * r + 0.1192 * g + 0.9505 * b
        let sum = x + y + z
        guard sum > 0 else { return 6500 }
        let cx = x / sum
        let cy = y / sum

        let n = (cx - 0.3320) / (0.1858 - cy)
        let cct = 449 * pow(n, 3) + 3525 * pow(n, 2) + 6823.3 * n + 5520.33
        return max(1000, min(cct, 12000))
    }

    private func interpretColor(kelvin: Double) -> String {
        switch kelvin {
        case ..<2200: return "Orangé/rouge très chaud — cohérent avec un reflet du soleil au lever/coucher, ou un feu de navigation classique"
        case 2200..<3200: return "Blanc chaud/orangé — cohérent avec un éclairage incandescent ou un reflet solaire rasant"
        case 3200..<5000: return "Blanc neutre — indéterminé entre reflet et source LED"
        case 5000..<6800: return "Blanc-bleuté — cohérent avec une source LED (éclairage embarqué)"
        default: return "Bleuté froid — cohérent avec une source LED haute température de couleur ou une surexposition de la caméra"
        }
    }
}

struct IlluminationResult {
    let pattern: String
    let colorGuess: String
    let estimatedKelvin: Double?
    let blinkFrequencyHz: Double?
    /// `true` si un clignotement détecté est quasi périodique (feu stroboscopique connu) plutôt
    /// qu'un scintillement erratique — voir `IlluminationAnalyzer.blinkStatistics`.
    let isRegularBlink: Bool
}
