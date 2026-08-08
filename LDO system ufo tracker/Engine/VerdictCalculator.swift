// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import CoreGraphics

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

    /// Confiance à partir de laquelle une forme identifiée (main, insecte, oiseau, avion/satellite)
    /// est traitée comme une explication connue plutôt qu'un simple facteur parmi d'autres.
    private let confidentKnownShapeThreshold: Double = 0.4

    func computeVerdict(session: AnalysisSession, shape: ShapeResult, mode: CaptureMode) -> VerdictResult {
        // 0. Sur-priorité absolue : si la forme est identifiée avec une confiance suffisante comme
        //    quelque chose de connu (main, insecte, oiseau, avion/satellite) — pas juste "non
        //    identifiée avec certitude" — aucun autre facteur ne doit pouvoir faire remonter le
        //    verdict. Une main qui bouge devant la caméra ne devient pas un phénomène ambigu parce
        //    que sa trajectoire est irrégulière ou que le son est absent : c'est une main.
        if shape.confidence >= confidentKnownShapeThreshold,
           !shape.label.contains("non identifiée"),
           shape.label != "Données insuffisantes" {
            return VerdictResult(
                label: "Probablement identifié (objet connu)",
                percent: 0,
                factors: ["Forme identifiée avec confiance : \(shape.label) (\(Int(shape.confidence * 100))%) — aucun autre facteur ne peut compenser une identification aussi claire"]
            )
        }

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

        // 6. Scintillement de luminosité IRRÉGULIER (par opposition à un clignotement régulier de
        //    type feu stroboscopique, voir IlluminationAnalyzer) : signal notable pour un OVNI, à
        //    l'opposé d'un projecteur ou d'un feu fixe dont l'intensité reste constante. Une
        //    luminosité continue, elle, est au contraire cohérente avec une source connue.
        if session.illuminationPattern.contains("scintillante irrégulière") {
            score += 15
            factors.append("Luminosité scintillante de façon irrégulière — atypique d'un projecteur ou feu fixe à intensité constante")
        } else if session.illuminationPattern == "Continue" {
            score -= 10
            factors.append("Luminosité continue et stable — cohérent avec un projecteur ou feu de navigation connu")
        }

        // 6bis. Irrégularité du contour de la tache lumineuse isolée elle-même (forme non circulaire,
        //    bords irréguliers plutôt qu'un point net — voir ShapeClassifier.contourIrregularity).
        //    Facteur pondéré demandé explicitement par Jean-David comme point important de
        //    l'analyse : un contour net et rond est cohérent avec un point lumineux ponctuel connu
        //    (feu de navigation, étoile, reflet) ; un contour amorphe/irrégulier est atypique.
        if let irregularity = shape.luminousRegion?.contourIrregularity {
            if irregularity > 0.5 {
                score += 20
                factors.append("Contour de la source lumineuse irrégulier/amorphe (indice : \(String(format: "%.2f", irregularity))) — atypique d'un point lumineux net et rond")
            } else if irregularity < 0.2 {
                score -= 5
                factors.append("Contour de la source lumineuse net et rond — cohérent avec un point lumineux ponctuel connu")
            }
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

        // 9. Dampening global : si les mesures sous-jacentes (distance, donc G et vitesse) reposent
        //    sur une confiance globalement faible, on plafonne le score pour ne pas afficher une
        //    conclusion plus assurée que les données ne le permettent.
        let dataConfidence = max(session.distanceConfidence, session.gForceConfidence, session.speedConfidence)
        var cappedScore = dataConfidence < 0.25 ? min(score, 70) : score

        // 10. Règles Mode Nuit demandées explicitement par Jean-David — appliquées APRÈS le
        //     dampening ci-dessus, car elles reposent sur des signaux indépendants de la distance
        //     estimée (régularité de la lumière, forme angulaire de la trajectoire), pas sur elle :
        //     un scintillement irrégulier combiné à une trajectoire variable/courbe est jugé un
        //     signal quasi certain d'OVNI (plancher sur le score) ; à l'inverse, une lumière stable
        //     ou un clignotement régulier (feu stroboscopique) combiné à une trajectoire continue et
        //     stable est jugé un signal quasi certain d'un aéronef, drone ou satellite connu
        //     (plafond sur le score). Uniquement en Mode Nuit — en Mode Jour la détection ne porte
        //     pas sur une source lumineuse isolée, ces règles n'ont pas de sens. Le plafond global de
        //     90% (jamais 100%, voir plus bas) reste appliqué dans tous les cas : LDO ne prétend
        //     jamais à une certitude absolue, même pour ce cas jugé quasi certain.
        if mode == .night {
            let isIrregularFlicker = session.illuminationPattern.contains("scintillante irrégulière")
            let isSteadyOrRegularBlink = session.illuminationPattern.contains("Clignotante régulière")
                || session.illuminationPattern == "Continue"
            let isErraticTrajectory = session.linearityR2 < 0.5 || session.isZigzagTrajectory
            let isStableTrajectory = !session.isZigzagTrajectory && session.linearityR2 >= 0.5
            // Trajectoire continue, droite ou légèrement courbe (mais pas erratique/zigzag) — la
            // condition de trajectoire est plus permissive que `isStableTrajectory` ci-dessus car une
            // météorite peut avoir une légère courbe sans être aussi stricte qu'une trajectoire
            // d'aéronef parfaitement rectiligne.
            let isContinuousOrSlightlyCurved = !session.isZigzagTrajectory && session.linearityR2 > 0.3
            // Traînée lumineuse allongée derrière l'objet : rapport largeur/hauteur de la zone
            // lumineuse isolée très supérieur à 1 (contrairement à un point source rond) — signature
            // visuelle typique d'une météorite qui laisse une traînée pendant l'exposition.
            let hasTrailShape: Bool = {
                guard let box = shape.luminousRegion?.boundingBoxInImage, box.width > 0, box.height > 0 else { return false }
                let elongation = max(box.width, box.height) / min(box.width, box.height)
                return elongation > 2.5
            }()

            if isIrregularFlicker && isErraticTrajectory {
                cappedScore = max(cappedScore, 85)
                factors.append("Règle Mode Nuit : lumière scintillante de façon irrégulière + trajectoire variable/courbe — signal jugé quasi certain d'objet volant non identifié")
            } else if hasTrailShape && isContinuousOrSlightlyCurved {
                // Priorité sur la règle avion/drone/satellite ci-dessous : la traînée est une
                // signature visuelle plus spécifique qu'une simple lumière stable.
                cappedScore = min(cappedScore, 10)
                factors.append("Règle Mode Nuit : traînée lumineuse allongée derrière l'objet + trajectoire continue (légèrement courbe ou non) — signal jugé quasi certain (90%) de météorite")
            } else if isSteadyOrRegularBlink && isStableTrajectory {
                cappedScore = min(cappedScore, 15)
                let objectKind = session.illuminationPattern == "Continue" ? "un avion ou un satellite" : "un avion, un drone ou un satellite"
                factors.append("Règle Mode Nuit : lumière stable/clignotement régulier + trajectoire continue et stable — signal jugé quasi certain de \(objectKind) connu")
            }
        }

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
