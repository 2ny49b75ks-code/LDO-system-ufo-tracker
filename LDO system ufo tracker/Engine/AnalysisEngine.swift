// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import Vision
import CoreImage
import AVFoundation

/// Résultat complet retourné à l'utilisateur (page annexe des résultats).
struct AnalysisSession: Identifiable, Equatable {
    let id = UUID()
    var videoURLWithOverlays: URL?
    var photosWithOverlays: [CGImage] = []
    /// `false` si la sauvegarde dans Photos a échoué (permission refusée, etc.) — voir
    /// `SessionAnalyzer`, affiché explicitement dans ResultsView plutôt que d'échouer en silence.
    var photosSavedToLibrary: Bool = true

    var shapeDescription: String = ""
    var shapeConfidence: Double = 0
    var known3DModelURL: URL?              // rendu 3D approximatif exporté (.usdz) si généré

    var trajectory: [CGPoint] = []          // trajectoire en pixels, superposée en rouge
    var trajectoryOnMap: [CLCoordinate] = [] // vue aérienne (MapKit)
    /// Position GPS de l'appareil au moment de l'enregistrement (voir `LocationProvider`) — `nil`
    /// pour une vidéo importée depuis la bibliothèque (aucune métadonnée de position disponible,
    /// comme pour la pose ARKit) ou si la permission de localisation n'a pas été accordée.
    var captureLocation: CLCoordinate?
    var isLinear: Bool = true
    var linearityR2: Double = 1.0            // 1.0 = parfaitement rectiligne
    var hasImpossibleGForce: Bool = false
    var estimatedGForce: Double = 0
    var gForceConfidence: Double = 0         // faible sans mesure de distance fiable
    var curvatureEvents: [CurvatureEvent] = []
    var isZigzagTrajectory: Bool = false      // alternance gauche-droite (voir TrajectoryCalculator)
    var trajectoryReversalCount: Int = 0
    /// Traînée de condensation détectée autour de l'objet (Mode Jour, voir ShapeClassifier).
    var hasContrail: Bool = false
    /// `true` si l'objet monte dans le ciel (position Y croissante à l'écran) sur l'ensemble du
    /// clip, `false` s'il descend, `nil` si la tendance n'est pas nette. Ne dépend PAS de la pose
    /// ARKit (contrairement à la trajectoire angulaire) — calculable même sur une vidéo importée.
    var isAscending: Bool?

    var illuminationPattern: String = ""     // "Continue" / "Variable / clignotante"
    var illuminationColor: String = ""       // ex: "blanc-bleuté (probable LED)" / "orangé (probable reflet solaire)"
    var illuminationKelvin: Double?

    var estimatedSpeedKmh: Double = 0
    var maxSpeedKmh: Double = 0
    var speedIsStationary: Bool = false
    var speedDefiesPhysics: Bool = false
    var speedConfidence: Double = 0
    var speedComparisonLabel: String = ""
    var maxLinearAccelerationMS2: Double = 0

    var soundClassification: String = ""     // texte affiché à l'utilisateur
    var soundMatchedCategory: String?        // "avion", "drone", "oiseau", "insecte"...
    var soundConfidence: Double = 0

    var estimatedDistanceMeters: Double?
    var estimatedAltitudeMeters: Double?
    var distanceConfidence: Double = 0       // faible, car estimée par triangulation, pas mesurée
    var distanceMethod: String = ""
    /// `true`/`false` si la distance par taille supposée a pu être recoupée avec la vitesse réelle
    /// typique du type détecté (voir `DistanceEstimator`) ; `nil` si le recoupement ne s'applique pas.
    var distanceCrossCheckAgrees: Bool? = nil
    /// Nom de l'astre connu (Vénus, Jupiter, Lune, Soleil, ou une étoile fixe brillante) dont la
    /// position calculée correspond à la direction observée, dans la tolérance retenue — voir
    /// `CelestialPositionCalculator`/`AnalysisEngine`. `nil` si aucune correspondance (ou recoupement
    /// non applicable, ex. vidéo importée sans position GPS ni boussole).
    var matchedCelestialBody: String? = nil
    var celestialMatchSeparationDegrees: Double? = nil

    var timestamp: Date = Date()

    var verdictLabel: String = ""            // "Indéterminé", "Phénomène anomal (OVNI)", etc.
    var verdictConfidencePercent: Int = 0
    var verdictFactors: [String] = []        // raisons affichées à l'utilisateur, pour la transparence
}

struct CLCoordinate { var lat: Double; var lon: Double }

/// Orchestre l'ensemble du pipeline d'analyse (étapes 2 à 9) en enchaînant les modules dédiés :
/// MotionDetector -> ShapeClassifier -> DistanceEstimator -> TrajectoryCalculator -> SpeedCalculator
/// -> IlluminationAnalyzer -> SoundClassifier -> OverlayRenderer -> VerdictCalculator.
///
/// ORDRE IMPORTANT : la distance (étape 8) est calculée AVANT la trajectoire (étape 4), car le
/// calcul des forces G et de la vitesse réels (pas seulement angulaires) a besoin d'une distance,
/// même approximative. La classification de forme (étape 3) est calculée avant la distance, car
/// l'estimateur de distance utilise la forme probable pour choisir une taille réelle de référence.
final class AnalysisEngine {

    private let motionDetector = MotionDetector()
    private let shapeClassifier = ShapeClassifier()
    private let distanceEstimator = DistanceEstimator()
    private let trajectoryCalculator = TrajectoryCalculator()
    private let speedCalculator = SpeedCalculator()
    private let illuminationAnalyzer = IlluminationAnalyzer()
    private let soundClassifier = SoundClassifier()
    private let verdictCalculator = VerdictCalculator()

    /// `mode` : choix explicite Nuit/Jour de l'utilisateur (voir `CaptureMode`), détermine la
    /// stratégie de détection de l'objet.
    /// `progress` est appelé après chaque étape terminée, avec la fraction complétée (0...1) et un
    /// libellé décrivant l'étape suivante — utilisé par `SessionAnalyzer` pour afficher une
    /// progression réelle pendant le calcul (onglets LIVE et Bibliothèque).
    /// `hintPoint` : point que l'utilisateur a touché dans `ClipTrimView` pour indiquer l'objet à
    /// analyser (repère Vision, normalisé, origine bas-gauche) — `nil` si aucun point touché, la
    /// détection reste alors entièrement automatique (comportement d'avant).
    func analyze(frames: [CapturedFrame], videoURL: URL?, mode: CaptureMode, captureLocation: CLCoordinate? = nil, hintPoint: CGPoint? = nil, progress: ((Double, String) -> Void)? = nil) -> AnalysisSession {
        var session = AnalysisSession()
        session.timestamp = Date()
        session.captureLocation = captureLocation

        let totalSteps = 9.0
        func report(_ completedSteps: Double, _ nextStepLabel: String) {
            progress?(completedSteps / totalSteps, nextStepLabel)
        }

        report(0, "Détection de l'objet…")
        // Étape 2 : détection de l'objet, selon le mode choisi par l'utilisateur (voir CaptureMode).
        // Nuit : seuillage de luminosité en priorité (trouve directement le point le plus brillant,
        // fiable même sans déplacement net entre deux images) — avec repli sur la détection par
        // mouvement si rien n'est isolé. Jour : détection par mouvement uniquement — sur une scène
        // normalement éclairée, chercher "le plus brillant" désignerait n'importe quel objet clair
        // (une main, un mur...) sans rapport avec un point lumineux isolé.
        var trackedObjects: [TrackedObject]
        switch mode {
        case .night:
            trackedObjects = motionDetector.detectByLuminosity(in: frames, hintPoint: hintPoint)
            debugLog("détection par luminosité : \(trackedObjects.first?.detections.count ?? 0) détection(s) sur \(frames.count) image(s)")
            if trackedObjects.isEmpty {
                trackedObjects = motionDetector.detectMovingObjects(in: frames)
                debugLog("repli détection par mouvement : \(trackedObjects.first?.detections.count ?? 0) détection(s)")
            }
        case .day:
            trackedObjects = motionDetector.detectDarkObjectOnBrightSky(in: frames, hintPoint: hintPoint)
            debugLog("détection silhouette sombre sur ciel clair (mode jour) : \(trackedObjects.first?.detections.count ?? 0) détection(s)")
            if trackedObjects.isEmpty {
                trackedObjects = motionDetector.detectMovingObjects(in: frames)
                debugLog("repli détection par mouvement (mode jour) : \(trackedObjects.first?.detections.count ?? 0) détection(s)")
            }
        }
        // Sélection de l'objet principal : par défaut celui suivi le plus longtemps. Si l'utilisateur
        // a touché un point, on privilégie plutôt l'objet dont la trajectoire passe le plus près de
        // ce point — c'est lui qui a été explicitement désigné, même s'il a moins de détections
        // qu'un autre artefact suivi plus longtemps ailleurs dans le cadre.
        let mainObject: TrackedObject?
        if let hintPoint, !trackedObjects.isEmpty {
            mainObject = trackedObjects.min { lhs, rhs in
                averageDistance(from: lhs, to: hintPoint) < averageDistance(from: rhs, to: hintPoint)
            }
        } else {
            mainObject = trackedObjects.max(by: { $0.detections.count < $1.detections.count })
        }
        let detections = mainObject?.detections ?? []

        report(1, "Classification de la forme…")
        // Étape 3 : classification de forme heuristique + isolement de la zone lumineuse (voir ShapeClassifier.swift).
        let shape = shapeClassifier.classifyShape(detections: detections, frames: frames, mode: mode)
        session.shapeDescription = shape.label
        session.shapeConfidence = shape.confidence
        session.known3DModelURL = shapeClassifier.buildApproximate3DSilhouette(luminousRegion: shape.luminousRegion)
        session.hasContrail = shape.hasContrail
        // Direction verticale (monte/descend) sur l'ensemble du clip — sur les positions brutes à
        // l'écran, pas la trajectoire angulaire corrigée de la pose (calculable même sans pose ARKit,
        // contrairement à cette dernière). Repère Vision : Y croissant = vers le haut de l'image.
        // Moyenne du premier/dernier cinquième des détections plutôt qu'un simple premier/dernier
        // point, pour amortir le bruit de détection sur un objet minuscule/lointain (voir
        // ShapeClassifier.pathStraightnessAndDisplacement, même principe).
        session.isAscending = verticalTrend(detections)

        // Recherche de traînée INDÉPENDANTE, sur l'image entière plutôt qu'autour de l'objet suivi
        // ci-dessus (voir MotionDetector.detectContrailCandidate) — remplace le signal ci-dessus
        // quand elle trouve quelque chose, plus robuste sur une cible minuscule/lointaine dans une
        // scène encombrée où le suivi de l'objet lui-même « saute » facilement (voir son commentaire).
        if mode == .day {
            let contrailObjects = motionDetector.detectContrailCandidate(in: frames)
            if let contrailDetections = contrailObjects.first?.detections, contrailDetections.count >= 3 {
                session.hasContrail = true
                // La dérive verticale à l'écran d'une traînée n'indique PAS de façon fiable si
                // l'avion monte ou descend réellement : un avion qui grimpe en s'éloignant de
                // l'observateur peut dériver vers le bas de l'image par pur effet de perspective
                // (angle d'élévation qui diminue avec la distance, même si l'altitude augmente).
                // Un météorite en chute, en revanche, produit une chute RAPIDE et nette en 1-2
                // secondes — bien plus vite que la dérive lente d'un avion. On ne conclut donc
                // « météorite » que si la descente est nette ET rapide ; sinon, comme une traînée
                // de condensation est très largement plus souvent le fait d'un avion que d'un
                // météorite, on retient l'hypothèse avion par défaut.
                session.isAscending = !contrailIsFastDescent(contrailDetections, yValue: { $0.maxY })
                debugLog("traînée détectée sur l'image entière : \(contrailDetections.count) détection(s), ascendant=\(String(describing: session.isAscending))")
            }
        }

        report(2, "Estimation de la distance…")
        // Passe préliminaire : vitesse angulaire (degrés/seconde) SEULE, sans distance — purement
        // géométrique (voir TrajectoryCalculator.angularVelocity), donc calculable avant même
        // d'avoir une distance. Sert à recouper la distance par taille supposée ci-dessous avec une
        // deuxième méthode indépendante (voir le commentaire dans DistanceEstimator). La trajectoire
        // complète (avec forces G) est recalculée à l'étape 4 une fois la distance réconciliée connue.
        let preliminaryTrajectory = trajectoryCalculator.computeTrajectory(detections: detections, frames: frames, estimatedDistanceMeters: nil)
        let averageAngularVelocity = preliminaryTrajectory.angularVelocitiesDegPerS.isEmpty ? nil :
            preliminaryTrajectory.angularVelocitiesDegPerS.map { $0.value }.reduce(0, +) / Double(preliminaryTrajectory.angularVelocitiesDegPerS.count)

        // Étape 8 (avancée ici, voir DistanceEstimator.swift) : triangulation angulaire à partir
        // d'une taille réelle supposée selon la forme détectée (pas de LiDAR, portée trop courte),
        // recoupée avec la vitesse réelle typique du type détecté quand c'est possible.
        let dist = distanceEstimator.estimateDistanceAndAltitude(detections: detections, frames: frames, shapeLabel: shape.label, averageAngularVelocityDegPerS: averageAngularVelocity)
        session.estimatedDistanceMeters = dist.distanceMeters
        session.estimatedAltitudeMeters = dist.altitudeMeters
        session.distanceConfidence = dist.confidence
        session.distanceMethod = dist.method
        session.distanceCrossCheckAgrees = dist.crossCheckAgrees
        // BUG CORRIGÉ : le seuil était `> 0.3` alors que `DistanceEstimator.confidence` ne dépasse
        // jamais 0.3 (0.15 pour une forme non identifiée, 0.3 au mieux pour une forme identifiée) —
        // la vitesse et les forces G étaient donc TOUJOURS "non calculables", peu importe la qualité
        // réelle de l'estimation. `> 0` laisse passer toute distance réellement calculée (les seuls
        // cas à confiance 0 sont "Aucune donnée" / "Taille apparente nulle", de vrais échecs), tout
        // en gardant l'indice de confiance affiché à l'utilisateur pour juger de sa fiabilité.
        let reliableDistance = dist.confidence > 0 ? dist.distanceMeters : nil

        report(3, "Calcul de la trajectoire…")
        // Étape 4 : trajectoire réelle (angulaire, corrigée du mouvement de la caméra) + forces G
        // (voir TrajectoryCalculator.swift).
        let traj = trajectoryCalculator.computeTrajectory(detections: detections, frames: frames, estimatedDistanceMeters: reliableDistance)
        session.trajectory = traj.points2D
        session.isLinear = traj.isLinear
        session.linearityR2 = traj.linearityR2
        session.estimatedGForce = traj.estimatedGForce
        session.gForceConfidence = traj.gForceConfidence
        session.hasImpossibleGForce = traj.exceedsHumanTolerance
        session.curvatureEvents = traj.curvatureEvents
        session.isZigzagTrajectory = traj.isZigzagPattern
        session.trajectoryReversalCount = traj.directionReversalCount

        // Recoupement astre connu (Soleil, Lune, Vénus, Jupiter, étoiles fixes brillantes) — demande
        // explicite de Jean-David (2026-08-09) : distinguer un vrai OVNI stationnaire d'une étoile ou
        // planète brillante (Vénus est la cause n°1 de signalements dans le monde). Nécessite la
        // position GPS ET la direction réelle observée (boussole ARKit, voir
        // TrajectoryCalculator.observedAzimuthElevation) — absentes toutes les deux pour une vidéo
        // importée de la bibliothèque, dans quel cas ce recoupement est simplement ignoré (nil).
        if let captureLocation, let observed = trajectoryCalculator.observedAzimuthElevation(detections: detections, frames: frames) {
            let candidates = CelestialPositionCalculator.visiblePositions(at: session.timestamp, latitude: captureLocation.lat, longitude: captureLocation.lon)
            // Tolérance volontairement large (12°) : cumul de l'imprécision de la boussole ARKit (peut
            // dériver de plusieurs degrés, surtout près d'interférences magnétiques) et de la précision
            // des formules orbitales à basse précision utilisées ci-dessus (~1°) — mieux vaut manquer
            // une vraie correspondance que d'en affirmer une fausse à tort.
            let matchToleranceDegrees = 12.0
            if let closest = candidates.min(by: {
                angularSeparationDegrees(az1: observed.azimuthDegrees, el1: observed.elevationDegrees, az2: $0.azimuthDegrees, el2: $0.elevationDegrees)
                < angularSeparationDegrees(az1: observed.azimuthDegrees, el1: observed.elevationDegrees, az2: $1.azimuthDegrees, el2: $1.elevationDegrees)
            }) {
                let separation = angularSeparationDegrees(az1: observed.azimuthDegrees, el1: observed.elevationDegrees, az2: closest.azimuthDegrees, el2: closest.elevationDegrees)
                if separation <= matchToleranceDegrees {
                    session.matchedCelestialBody = closest.name
                    session.celestialMatchSeparationDegrees = separation
                }
            }
        }

        report(4, "Analyse de l'illumination…")
        // Étape 5 : illumination et couleur (voir IlluminationAnalyzer.swift), échantillonnée sur
        // plusieurs détections (max 8, pour limiter le coût de calcul du seuillage d'image).
        let sampledDetections = stride(from: 0, to: detections.count, by: max(1, detections.count / 8)).map { detections[$0] }
        let luminousSamples: [(timestamp: TimeInterval, region: LuminousRegion)] = sampledDetections.compactMap { detection in
            guard let region = shapeClassifier.isolateLuminousRegion(for: detection, frames: frames) else { return nil }
            return (detection.timestamp, region)
        }
        let illum = illuminationAnalyzer.analyzeIllumination(luminousRegionsOverTime: luminousSamples)
        session.illuminationPattern = illum.pattern
        session.illuminationColor = illum.colorGuess
        session.illuminationKelvin = illum.estimatedKelvin

        report(5, "Calcul de la vitesse…")
        // Étape 6 : vitesse (voir SpeedCalculator.swift), dérivée de la même trajectoire angulaire.
        let speed = speedCalculator.estimateSpeed(trajectory: traj, distanceMeters: reliableDistance)
        session.estimatedSpeedKmh = speed.averageKmh
        session.maxSpeedKmh = speed.maxKmh
        session.speedIsStationary = speed.isStationary
        session.speedDefiesPhysics = speed.accelerationImpliesImpossiblePerformance
        session.speedConfidence = speed.confidence
        session.speedComparisonLabel = speed.comparisonLabel
        session.maxLinearAccelerationMS2 = speed.maxAccelerationMS2

        report(6, "Analyse du son…")
        // Étape 7 : son (voir SoundClassifier.swift). L'API SoundAnalysis est asynchrone ; on la
        // pont vers ce pipeline synchrone avec un sémaphore (acceptable ici car l'analyse tourne
        // déjà hors du fil principal, après l'enregistrement — voir CaptureManager).
        let soundSemaphore = DispatchSemaphore(value: 0)
        var soundResult = SoundResult(label: "Analyse audio non exécutée", matchedCategory: nil, confidence: 0)
        soundClassifier.classifySound(videoURL: videoURL) { result in
            soundResult = result
            soundSemaphore.signal()
        }
        _ = soundSemaphore.wait(timeout: .now() + 20)
        session.soundClassification = soundResult.label
        session.soundMatchedCategory = soundResult.matchedCategory
        session.soundConfidence = soundResult.confidence

        report(7, "Calcul du verdict…")
        // Verdict final (voir VerdictCalculator.swift), avec la liste des facteurs affichée à l'utilisateur.
        // Calculé AVANT le rendu des incrustations ci-dessous : le logo LDO n'est dessiné que si le
        // verdict penche vers "OVNI" (voir OverlayRenderer.draw), donc verdictConfidencePercent doit
        // déjà être renseigné à ce moment-là.
        let verdict = verdictCalculator.computeVerdict(session: session, shape: shape, mode: mode)
        session.verdictLabel = verdict.label
        session.verdictConfidencePercent = verdict.percent
        session.verdictFactors = verdict.factors

        report(8, "Rendu des incrustations…")
        // Étape 9 + rendu final : 3 photos (plan large, zoom auto maximum sur la cible, zoom fixe
        // ×2 — voir PhotoComposer), incrustées de la trajectoire rouge, date/heure, vitesse max et
        // du logo LDO conditionnel ; incrustations identiques sur la vidéo complète.
        let photoSet = PhotoComposer.composePhotoSet(frames: frames, detections: detections)
        session.photosWithOverlays = photoSet.enumerated().map { index, image in
            // Seule la première photo (plan large, non recadrée) a des coordonnées de trajectoire
            // valides — voir OverlayRenderer.draw.
            OverlayRenderer.draw(on: image, session: session, drawTrajectory: index == 0)
        }
        session.videoURLWithOverlays = OverlayRenderer.exportVideoWithOverlays(sourceURL: videoURL, session: session)

        report(9, "Terminé")
        return session
    }

    /// Distance angulaire (degrés) entre deux directions données en azimut/élévation — via leurs
    /// vecteurs unitaires, pas une simple différence de coordonnées (fausse près du zénith où
    /// l'azimut perd sa signification). Utilisée pour comparer la direction observée à la position
    /// calculée d'un astre connu (voir `CelestialPositionCalculator`).
    private func angularSeparationDegrees(az1: Double, el1: Double, az2: Double, el2: Double) -> Double {
        let az1Rad = az1 * .pi / 180, el1Rad = el1 * .pi / 180
        let az2Rad = az2 * .pi / 180, el2Rad = el2 * .pi / 180
        let x1 = cos(el1Rad) * sin(az1Rad), y1 = cos(el1Rad) * cos(az1Rad), z1 = sin(el1Rad)
        let x2 = cos(el2Rad) * sin(az2Rad), y2 = cos(el2Rad) * cos(az2Rad), z2 = sin(el2Rad)
        let dot = max(-1, min(1, x1 * x2 + y1 * y2 + z1 * z2))
        return acos(dot) * 180 / .pi
    }

    /// Distance moyenne entre les détections d'un objet suivi et un point de référence (repère
    /// Vision, normalisé) — sert à retenir l'objet le plus proche du point touché par l'utilisateur.
    private func averageDistance(from object: TrackedObject, to point: CGPoint) -> CGFloat {
        guard !object.detections.isEmpty else { return .greatestFiniteMagnitude }
        let total = object.detections.reduce(CGFloat(0)) { sum, detection in
            let center = CGPoint(x: detection.boundingBox.midX, y: detection.boundingBox.midY)
            return sum + hypot(center.x - point.x, center.y - point.y)
        }
        return total / CGFloat(object.detections.count)
    }

    /// `true` si l'objet monte vers le haut de l'image sur l'ensemble du clip, `false` s'il descend,
    /// `nil` si le déplacement vertical net est négligeable (objet quasi stationnaire) — voir
    /// `AnalysisSession.isAscending`. `yValue` sélectionne le point de la boîte à suivre : le centre
    /// pour un objet compact (comportement historique), le bord SUPÉRIEUR pour une traînée de
    /// condensation (voir l'appel dédié ci-dessous et son commentaire).
    private func verticalTrend(_ detections: [Detection], yValue: (CGRect) -> CGFloat = { $0.midY }) -> Bool? {
        guard detections.count >= 4 else { return nil }
        let fifth = max(1, detections.count / 5)
        let firstGroup = detections.prefix(fifth)
        let lastGroup = detections.suffix(fifth)
        let firstY = firstGroup.reduce(CGFloat(0)) { $0 + yValue($1.boundingBox) } / CGFloat(firstGroup.count)
        let lastY = lastGroup.reduce(CGFloat(0)) { $0 + yValue($1.boundingBox) } / CGFloat(lastGroup.count)
        let delta = lastY - firstY
        // Seuil minimal (fraction du cadre) pour ne pas trancher sur un déplacement vertical
        // négligeable, potentiellement dû au seul bruit de détection.
        guard abs(delta) > 0.03 else { return nil }
        return delta > 0
    }

    /// `true` seulement si la traînée descend de façon nette ET rapide (signature d'une chute de
    /// météorite) — voir le commentaire d'appel ci-dessus sur l'ambiguïté de perspective. `false`
    /// dans tous les autres cas (montée, quasi-stationnaire, ou descente trop lente pour être une
    /// chute), ce qui fait retenir l'hypothèse avion par défaut.
    private func contrailIsFastDescent(_ detections: [Detection], yValue: (CGRect) -> CGFloat) -> Bool {
        guard detections.count >= 4 else { return false }
        let fifth = max(1, detections.count / 5)
        let firstGroup = detections.prefix(fifth)
        let lastGroup = detections.suffix(fifth)
        let firstY = firstGroup.reduce(CGFloat(0)) { $0 + yValue($1.boundingBox) } / CGFloat(firstGroup.count)
        let lastY = lastGroup.reduce(CGFloat(0)) { $0 + yValue($1.boundingBox) } / CGFloat(lastGroup.count)
        let delta = lastY - firstY
        guard delta < -0.03 else { return false }
        let firstT = firstGroup.reduce(0.0) { $0 + $1.timestamp } / Double(firstGroup.count)
        let lastT = lastGroup.reduce(0.0) { $0 + $1.timestamp } / Double(lastGroup.count)
        let dt = lastT - firstT
        guard dt > 0 else { return false }
        let speed = Double(abs(delta)) / dt
        // Seuil empirique : une chute de météorite parcourt une bonne partie du cadre en 1-2
        // secondes (~0.15-0.3+ unités normalisées/seconde) ; un avion qui recule/monte dérive
        // typiquement à moins de 0.03 unité/seconde sur ces clips.
        let fastDescentThresholdPerSecond = 0.08
        return speed > fastDescentThresholdPerSecond
    }
}

/// Log de debug actif uniquement en build Debug (aucun coût en production).
private func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("LDO_DEBUG \(message())")
    #endif
}
struct Detection {
    var boundingBox: CGRect
    var timestamp: TimeInterval
}

extension AnalysisSession {
    static func == (lhs: AnalysisSession, rhs: AnalysisSession) -> Bool {
        lhs.id == rhs.id
    }
}
