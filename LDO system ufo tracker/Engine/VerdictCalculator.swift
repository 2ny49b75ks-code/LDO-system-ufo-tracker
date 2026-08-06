// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation

/// Combine tous les signaux produits par le pipeline (forme, trajectoire/G, vitesse, illumination,
/// son) en un verdict final et un pourcentage de possibilité.
///
/// PRINCIPE DE TRANSPARENCE : chaque facteur qui contribue au score est retourné dans
/// `factors`, affiché à l'utilisateur dans la page de résultats. LDO ne prétend jamais donner une
/// certitude scientifique — seulement une aide à l'interprétation, avec le détail de son raisonnement.
final class VerdictCalculator {

    /// Vitesse maximale publiquement documentée d'un F-35 (~Mach 1.6, en palier). Sert de repère
    /// pour juger si une vitesse mesurée dépasse largement tout aéronef militaire connu.
    private let f35MaxSpeedKmh: Double = 1960.0

    func computeVerdict(session: AnalysisSession, shape: ShapeResult) -> VerdictResult {
        var score = 0.0
        var factors: [String] = []

        // 1. Forme non identifiée avec confiance -> augmente le score, proportionnellement à
        //    l'incertitude de la classification (plus la confiance de la classification est basse,
        //    plus la contribution est forte).
        let shapeContribution = (1 - shape.confidence) * 25
        score += shapeContribution
        if shape.confidence < 0.3 {
            factors.append("Forme non reconnue avec confiance (classification : \(Int(shape.confidence * 100))%)")
        }

        // 2. Force G dépassant la tolérance humaine — pondérée par la confiance de l'estimation
        //    (elle-même dépendante de la distance estimée, toujours incertaine pour un objet lointain).
        if session.hasImpossibleGForce {
            score += 20
            factors.append("Changement de direction impliquant ~\(String(format: "%.1f", session.estimatedGForce)) G (confiance sur la valeur : \(Int(session.gForceConfidence * 100))%)")
        }

        // 3. Accélération linéaire soutenue au-delà de la performance des aéronefs connus.
        if session.speedDefiesPhysics {
            score += 20
            factors.append("Accélération soutenue de \(Int(session.maxLinearAccelerationMS2)) m/s², supérieure aux aéronefs connus")
        }

        // 4. Trajectoire très irrégulière (R² de linéarité faible) — signal plus faible, car un
        //    mouvement de caméra mal corrigé peut aussi produire de l'irrégularité.
        if session.linearityR2 < 0.5 && session.linearityR2 > 0 {
            score += 10
            factors.append("Trajectoire irrégulière (R² : \(String(format: "%.2f", session.linearityR2)))")
        }

        // 5. Son : un son clairement identifié (avion, drone, oiseau, insecte) est une preuve
        //    directe d'explication connue et fait fortement BAISSER le score. L'absence de son
        //    n'est en revanche qu'un indice faible (beaucoup d'aéronefs sont inaudibles à distance).
        if let category = session.soundMatchedCategory, session.soundConfidence > 0.5 {
            score -= 30
            factors.append("Son identifié comme cohérent avec : \(category) (\(Int(session.soundConfidence * 100))%) — explication probable")
        } else {
            score += 5
        }

        // 6. Scintillement de luminosité variable : signal notable pour un OVNI, à l'opposé d'un
        //    projecteur ou d'un feu fixe dont l'intensité reste constante. Une luminosité continue,
        //    elle, est au contraire cohérente avec une source connue.
        if session.illuminationPattern.contains("Variable") {
            score += 15
            factors.append("Luminosité variable / scintillante — atypique d'un projecteur ou feu fixe à intensité constante")
        } else if session.illuminationPattern == "Continue" {
            score -= 10
            factors.append("Luminosité continue et stable — cohérent avec un projecteur ou feu de navigation connu")
        }

        // 7. Vitesse très supérieure à celle de tout aéronef militaire connu (repère : F-35, ~Mach
        //    1.6). Un objet 2 à 3 fois plus rapide qu'un chasseur révèle une performance hors de
        //    portée de l'aviation connue.
        if session.speedConfidence > 0 {
            if session.maxSpeedKmh >= 3 * f35MaxSpeedKmh {
                score += 30
                factors.append("Vitesse ~\(Int(session.maxSpeedKmh)) km/h — plus de 3× la vitesse maximale d'un F-35 (~\(Int(f35MaxSpeedKmh)) km/h)")
            } else if session.maxSpeedKmh >= 2 * f35MaxSpeedKmh {
                score += 20
                factors.append("Vitesse ~\(Int(session.maxSpeedKmh)) km/h — plus de 2× la vitesse maximale d'un F-35 (~\(Int(f35MaxSpeedKmh)) km/h)")
            }
        }

        // 8. Trajectoire en zigzag gauche-droite : un aéronef, un drone ou un satellite connu suit
        //    une trajectoire linéaire ou une courbe continue dans une seule direction — des
        //    changements de sens répétés ne correspondent à aucun comportement de vol connu.
        if session.isZigzagTrajectory {
            score += 25
            factors.append("Trajectoire en zigzag gauche-droite (\(session.trajectoryReversalCount) changements de direction) — atypique d'un aéronef, drone ou satellite connu")
        }

        score = max(0, score)

        // 7. Dampening global : si les mesures sous-jacentes (distance, donc G et vitesse) reposent
        //    sur une confiance globalement faible, on plafonne le score pour ne pas afficher une
        //    conclusion plus assurée que les données ne le permettent.
        let dataConfidence = max(session.distanceConfidence, session.gForceConfidence, session.speedConfidence)
        let cappedScore = dataConfidence < 0.25 ? min(score, 70) : score

        let percent = Int(min(cappedScore, 90))  // jamais 100% : LDO reste une aide à l'interprétation

        let label: String
        switch percent {
        case 60...: label = "Phénomène anomal non identifié (OVNI possible)"
        case 30..<60: label = "Indéterminé"
        default: label = "Probablement identifié (objet connu)"
        }

        if factors.isEmpty {
            factors.append("Aucun signal fort détecté dans les données disponibles")
        }

        return VerdictResult(label: label, percent: percent, factors: factors)
    }
}

struct VerdictResult {
    let label: String
    let percent: Int
    let factors: [String]
}
