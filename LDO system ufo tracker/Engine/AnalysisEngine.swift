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

    var shapeDescription: String = ""
    var shapeConfidence: Double = 0
    var known3DModelURL: URL?              // rendu 3D approximatif exporté (.usdz) si généré

    var trajectory: [CGPoint] = []          // trajectoire en pixels, superposée en rouge
    var trajectoryOnMap: [CLCoordinate] = [] // vue aérienne (MapKit)
    var isLinear: Bool = true
    var linearityR2: Double = 1.0            // 1.0 = parfaitement rectiligne
    var hasImpossibleGForce: Bool = false
    var estimatedGForce: Double = 0
    var gForceConfidence: Double = 0         // faible sans mesure de distance fiable
    var maxAngularAccelerationDegPerS2: Double = 0  // mesure indépendante de la distance, toujours fiable
    var curvatureEvents: [CurvatureEvent] = []

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
    var distanceConfidence: Double = 0       // faible, car sans référence LiDAR à cette distance
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

    func analyze(frames: [CapturedFrame], videoURL: URL?) -> AnalysisSession {
        var session = AnalysisSession()
        session.timestamp = Date()

        // Étape 2 : détection d'objet(s) en mouvement (voir MotionDetector.swift).
        let trackedObjects = motionDetector.detectMovingObjects(in: frames)
        let mainObject = trackedObjects.max(by: { $0.detections.count < $1.detections.count })
        let detections = mainObject?.detections ?? []

        // Étape 3 : classification de forme heuristique + isolement de la zone lumineuse (voir ShapeClassifier.swift).
        let shape = shapeClassifier.classifyShape(detections: detections, frames: frames)
        session.shapeDescription = shape.label
        session.shapeConfidence = shape.confidence
        session.known3DModelURL = shapeClassifier.buildApproximate3DSilhouette(luminousRegion: shape.luminousRegion)

        // Étape 8 (avancée ici, voir DistanceEstimator.swift) : LiDAR direct si à portée (<8 m),
        // sinon triangulation angulaire à partir d'une taille réelle supposée selon la forme détectée.
        let dist = distanceEstimator.estimateDistanceAndAltitude(detections: detections, frames: frames, shapeLabel: shape.label)
        session.estimatedDistanceMeters = dist.distanceMeters
        session.estimatedAltitudeMeters = dist.altitudeMeters
        session.distanceConfidence = dist.confidence
        session.distanceMethod = dist.method
        let reliableDistance = dist.confidence > 0.3 ? dist.distanceMeters : nil

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

        // Étape 6 : vitesse (voir SpeedCalculator.swift), dérivée de la même trajectoire angulaire.
        let speed = speedCalculator.estimateSpeed(trajectory: traj, distanceMeters: reliableDistance)
        session.estimatedSpeedKmh = speed.averageKmh
        session.maxSpeedKmh = speed.maxKmh
        session.speedIsStationary = speed.isStationary
        session.speedDefiesPhysics = speed.accelerationImpliesImpossiblePerformance
        session.speedConfidence = speed.confidence
        session.speedComparisonLabel = speed.comparisonLabel
        session.maxLinearAccelerationMS2 = speed.maxAccelerationMS2

        // Étape 7 : son (voir SoundClassifier.swift). L'API SoundAnalysis est asynchrone ; on la
        // pont vers ce pipeline synchrone avec un sémaphore (acceptable ici car l'analyse tourne
        // déjà hors du fil principal, après l'enregistrement — voir CaptureManager).
        let soundSemaphore = DispatchSemaphore(value: 0)
        var soundResult = SoundResult(label: "Analyse audio non exécutée", matchedCategory: nil, confidence: 0)
        soundClassifier.classifySound(videoURL: videoURL) { result in
            soundResult = result
            soundSemaphore.signal()
        }
        _ = soundSemaphore.wait(timeout: .now() + 10)
        session.soundClassification = soundResult.label
        session.soundMatchedCategory = soundResult.matchedCategory
        session.soundConfidence = soundResult.confidence

        // Étape 9 + rendu final : incruste trajectoire rouge, date/heure, vitesse max, et le logo LDO
        // conditionnel sur les 3 photos (voir OverlayRenderer.swift). Le rendu vidéo complet suit le
        // même principe via AVVideoCompositing (squelette fourni, à compléter avec AVFoundation).
        session.photosWithOverlays = frames.prefix(3).map { OverlayRenderer.draw(on: $0.image, session: session) }
        session.videoURLWithOverlays = videoURL // overlay vidéo : voir OverlayRenderer.VideoOverlayCompositor

        // Verdict final (voir VerdictCalculator.swift), avec la liste des facteurs affichée à l'utilisateur.
        let verdict = verdictCalculator.computeVerdict(session: session, shape: shape)
        session.verdictLabel = verdict.label
        session.verdictConfidencePercent = verdict.percent
        session.verdictFactors = verdict.factors

        return session
    }
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
