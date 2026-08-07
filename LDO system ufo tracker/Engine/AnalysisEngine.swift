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
    var maxAngularAccelerationDegPerS2: Double = 0  // mesure indépendante de la distance, toujours fiable
    var curvatureEvents: [CurvatureEvent] = []
    var isZigzagTrajectory: Bool = false      // alternance gauche-droite (voir TrajectoryCalculator)
    var trajectoryReversalCount: Int = 0

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
        let shape = shapeClassifier.classifyShape(detections: detections, frames: frames)
        session.shapeDescription = shape.label
        session.shapeConfidence = shape.confidence
        session.known3DModelURL = shapeClassifier.buildApproximate3DSilhouette(luminousRegion: shape.luminousRegion)

        report(2, "Estimation de la distance…")
        // Étape 8 (avancée ici, voir DistanceEstimator.swift) : triangulation angulaire à partir
        // d'une taille réelle supposée selon la forme détectée (pas de LiDAR, portée trop courte).
        let dist = distanceEstimator.estimateDistanceAndAltitude(detections: detections, frames: frames, shapeLabel: shape.label)
        session.estimatedDistanceMeters = dist.distanceMeters
        session.estimatedAltitudeMeters = dist.altitudeMeters
        session.distanceConfidence = dist.confidence
        session.distanceMethod = dist.method
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
        session.maxAngularAccelerationDegPerS2 = traj.maxAngularAccelerationDegPerS2
        session.curvatureEvents = traj.curvatureEvents
        session.isZigzagTrajectory = traj.isZigzagPattern
        session.trajectoryReversalCount = traj.directionReversalCount

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
        let verdict = verdictCalculator.computeVerdict(session: session, shape: shape)
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
