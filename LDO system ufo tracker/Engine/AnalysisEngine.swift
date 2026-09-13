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
    /// Recoupement avec le réseau ADS-B public (voir `AircraftLookupService`, pivot du 2026-09-12) —
    /// identification GÉOMÉTRIQUE d'un avion réel et actuellement en vol dans l'axe visé, plutôt
    /// qu'une physique devinée à partir d'une taille supposée (voir la dépréciation de
    /// `DistanceEstimator`). `aircraftLookupStatus` distingue une correspondance trouvée d'un simple
    /// échec réseau, d'une absence d'avion à proximité, ou d'une vidéo trop ancienne pour qu'une
    /// vérification en temps réel ait un sens — affiché honnêtement à l'utilisateur (`ResultsView`)
    /// plutôt que de laisser un silence ambigu.
    var aircraftLookupStatus: AircraftLookupStatus = .notAttempted
    var matchedAircraftCallsign: String? = nil
    var matchedAircraftICAO24: String? = nil
    var aircraftMatchSeparationDegrees: Double? = nil
    var aircraftMatchDistanceKm: Double? = nil

    /// Heure absolue de la CAPTATION (pas de l'analyse) quand elle est connue — voir
    /// `RecordedSession.captureStartedAt`/`LibraryTabView.extractEmbeddedCreationDate` et le
    /// paramètre `captureStartedAt` d'`AnalysisEngine.analyze` ci-dessous. Repli sur l'heure de
    /// l'analyse (comportement d'avant le pivot du 2026-09-12) quand elle est inconnue (ancien
    /// enregistrement, métadonnées absentes).
    var timestamp: Date = Date()

    var verdictLabel: String = ""            // "Indéterminé", "Phénomène anomal (OVNI)", etc.
    var verdictConfidencePercent: Int = 0
    var verdictFactors: [String] = []        // raisons affichées à l'utilisateur, pour la transparence
}

struct CLCoordinate { var lat: Double; var lon: Double }

/// Orchestre l'ensemble du pipeline d'analyse (étapes 2 à 9) en enchaînant les modules dédiés :
/// MotionDetector -> ShapeClassifier -> AircraftLookupService/SatelliteLookupService/
/// CelestialPositionCalculator -> TrajectoryCalculator -> SpeedCalculator -> IlluminationAnalyzer ->
/// SoundClassifier -> OverlayRenderer -> VerdictCalculator.
///
/// PIVOT DU 2026-09-12 : l'ancienne triangulation par taille réelle supposée (voir la note de
/// dépréciation en tête de `DistanceEstimator.swift`) a été retirée du pipeline — elle ne peut
/// mathématiquement pas produire une distance/vitesse/force G fiable à partir d'une seule caméra
/// 2D sans profondeur connue (le LiDAR de l'iPhone plafonne à ~5 m, inutile pour un objet aérien),
/// ce qui a causé une série de bugs jamais réglés (21G/399 m/s² pour un avion en vol droit, etc.).
/// Remplacée par un recoupement avec des données RÉELLES et publiques : réseau ADS-B (voir
/// `AircraftLookupService`) pour un avion connu dans l'axe visé, à défaut position calculée d'un
/// astre connu (voir `CelestialPositionCalculator`, déjà existant). La classification de forme
/// (étape 3) reste calculée avant ce recoupement : sans correspondance ADS-B/astrale, elle demeure
/// la première ligne d'identification (voir `VerdictCalculator`, règle 0).
final class AnalysisEngine {

    private let motionDetector = MotionDetector()
    private let shapeClassifier = ShapeClassifier()
    private let trajectoryCalculator = TrajectoryCalculator()
    private let speedCalculator = SpeedCalculator()
    private let illuminationAnalyzer = IlluminationAnalyzer()
    private let soundClassifier = SoundClassifier()
    private let verdictCalculator = VerdictCalculator()

    /// Au-delà de ce délai entre la captation et l'analyse, on ne tente même pas le recoupement
    /// ADS-B (voir `AircraftLookupService`) : l'accès anonyme d'OpenSky ne couvre que le trafic EN
    /// TEMPS RÉEL, une requête pour une vidéo plus ancienne ne pourrait de toute façon rien prouver
    /// — mieux vaut l'annoncer clairement (`AircraftLookupStatus.skippedStaleCapture`) que de
    /// gaspiller un appel réseau pour un résultat sans valeur.
    private let maxUsefulLookupAgeHours: Double = 1.0

    /// `mode` : choix explicite Nuit/Jour de l'utilisateur (voir `CaptureMode`), détermine la
    /// stratégie de détection de l'objet.
    /// `progress` est appelé après chaque étape terminée, avec la fraction complétée (0...1) et un
    /// libellé décrivant l'étape suivante — utilisé par `SessionAnalyzer` pour afficher une
    /// progression réelle pendant le calcul (onglets LIVE et Bibliothèque).
    /// `hintPoint` : point que l'utilisateur a touché/ciblé (repère Vision, normalisé, origine
    /// bas-gauche) pour indiquer l'objet à analyser — soit dans `ClipTrimView` après l'enregistrement,
    /// soit sur le réticule de ciblage en direct dans `LiveTabView` (voir `RecordingStore`, qui
    /// persiste ce ciblage avec la vidéo). `nil` si aucun point touché, la détection reste alors
    /// entièrement automatique (comportement d'avant).
    /// `hintRadius` : rayon (fraction de la diagonale du cadre, 0...1) de la zone de ciblage — quand
    /// fourni avec `hintPoint`, restreint STRICTEMENT la détection à cette zone (voir le commentaire
    /// détaillé dans `MotionDetector` sur le bug d'un arbre/objet hors cible faussement détecté).
    /// `captureStartedAt` : heure absolue (UTC) du début de la captation, quand elle est connue
    /// (voir `RecordedSession.captureStartedAt`/`LibraryTabView.extractEmbeddedCreationDate`) —
    /// utilisée pour `session.timestamp` à la place de l'heure de l'analyse (comportement d'avant le
    /// pivot du 2026-09-12), qui peut être bien plus tardive pour une vidéo déjà existante. `nil` si
    /// inconnue (ancien enregistrement, métadonnées absentes) : repli sur l'heure de l'analyse.
    func analyze(frames: [CapturedFrame], videoURL: URL?, mode: CaptureMode, captureLocation: CLCoordinate? = nil, captureStartedAt: Date? = nil, hintPoint: CGPoint? = nil, hintRadius: CGFloat? = nil, progress: ((Double, String) -> Void)? = nil) -> AnalysisSession {
        var session = AnalysisSession()
        session.timestamp = captureStartedAt ?? Date()
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
            trackedObjects = motionDetector.detectByLuminosity(in: frames, hintPoint: hintPoint, hintRadius: hintRadius)
            debugLog("détection par luminosité : \(trackedObjects.first?.detections.count ?? 0) détection(s) sur \(frames.count) image(s)")
            if trackedObjects.isEmpty {
                trackedObjects = motionDetector.detectMovingObjects(in: frames, hintPoint: hintPoint, hintRadius: hintRadius)
                debugLog("repli détection par mouvement : \(trackedObjects.first?.detections.count ?? 0) détection(s)")
            }
        case .day:
            trackedObjects = motionDetector.detectDarkObjectOnBrightSky(in: frames, hintPoint: hintPoint, hintRadius: hintRadius)
            debugLog("détection silhouette sombre sur ciel clair (mode jour) : \(trackedObjects.first?.detections.count ?? 0) détection(s)")
            if trackedObjects.isEmpty {
                trackedObjects = motionDetector.detectMovingObjects(in: frames, hintPoint: hintPoint, hintRadius: hintRadius)
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

        report(2, "Recoupement ADS-B et astres…")
        // Étape 8 (remplace l'ancienne triangulation par taille supposée — voir la note de
        // dépréciation en tête de DistanceEstimator.swift) : direction réelle observée (boussole
        // ARKit, voir TrajectoryCalculator.observedAzimuthElevation), comparée à deux sources de
        // vérité externes : 1) le réseau ADS-B public (AircraftLookupService/OpenSky) pour un avion
        // réel et actuellement en vol dans l'axe visé ; 2) à défaut, la position calculée d'un astre
        // connu (CelestialPositionCalculator, demande explicite de Jean-David du 2026-08-09— Vénus
        // est la cause n°1 de signalements dans le monde). Les deux nécessitent la position GPS ET
        // la direction observée — absentes toutes les deux pour une vidéo importée sans métadonnées,
        // dans quel cas ce recoupement est simplement ignoré.
        let observedDirection = trajectoryCalculator.observedAzimuthElevation(detections: detections, frames: frames)

        if let captureLocation, let observed = observedDirection {
            let hoursSinceCapture = max(0, Date().timeIntervalSince(session.timestamp) / 3600)
            if hoursSinceCapture > maxUsefulLookupAgeHours {
                // Accès anonyme OpenSky = trafic en temps réel seulement (voir AircraftLookupService)
                // — inutile de dépenser une requête pour une vidéo trop ancienne pour qu'elle puisse
                // rien prouver ; on l'annonce clairement plutôt que de laisser un silence ambigu.
                session.aircraftLookupStatus = .skippedStaleCapture(hoursElapsed: hoursSinceCapture)
            } else {
                // Pontage synchrone du même type que celui déjà utilisé et documenté pour
                // SoundClassifier plus bas (acceptable ici pour la même raison : l'analyse tourne
                // déjà hors du fil principal, voir SessionAnalyzer) — PAS l'anti-patron
                // Task+sémaphore qui avait causé le plantage de l'ancienne fonctionnalité RA : ici on
                // bloque un thread d'arrière-plan déjà hors fil principal, en attendant un callback
                // réseau qui ne dépend jamais du MainActor.
                let aircraftSemaphore = DispatchSemaphore(value: 0)
                var lookupResult: Result<[AircraftLookupService.AircraftCandidate], AircraftLookupService.LookupError> = .failure(.networkUnavailable)
                AircraftLookupService.fetchAircraftStates(around: captureLocation) { result in
                    lookupResult = result
                    aircraftSemaphore.signal()
                }
                _ = aircraftSemaphore.wait(timeout: .now() + 8)

                switch lookupResult {
                case .failure:
                    session.aircraftLookupStatus = .networkUnavailable
                case .success(let candidates):
                    if candidates.isEmpty {
                        session.aircraftLookupStatus = .queriedNoAircraftNearby
                    } else if let match = AircraftLookupService.closestMatch(
                        candidates: candidates, observerLocation: captureLocation,
                        observedAzimuthDegrees: observed.azimuthDegrees, observedElevationDegrees: observed.elevationDegrees
                    ) {
                        session.matchedAircraftCallsign = match.candidate.callsign
                        session.matchedAircraftICAO24 = match.candidate.icao24
                        session.aircraftMatchSeparationDegrees = match.separationDegrees
                        session.aircraftMatchDistanceKm = match.distanceKm
                        session.aircraftLookupStatus = .matched
                    } else {
                        session.aircraftLookupStatus = .queriedNoBearingMatch(nearbyCount: candidates.count)
                    }
                }
            }

            // Recoupement astre connu — effectué même si le recoupement ADS-B ci-dessus a
            // échoué/rien trouvé : les deux sont indépendants, et la règle de verdict la plus
            // prioritaire (ADS-B, voir VerdictCalculator) l'emporte de toute façon si les deux
            // correspondent en même temps.
            var candidates = CelestialPositionCalculator.visiblePositions(at: session.timestamp, latitude: captureLocation.lat, longitude: captureLocation.lon)

            // Recoupement satellites connus (ISS, objets les plus brillants visibles à l'œil nu —
            // voir SatelliteLookupService, pivot du 2026-09-12) : ajoutés directement à la même liste
            // de candidats que les astres ci-dessus, comparés par la MÊME logique de correspondance
            // directionnelle déjà en place — aucune nouvelle règle de verdict nécessaire. Soumis à la
            // même limite de fraîcheur que le recoupement ADS-B (voir maxUsefulLookupAgeHours
            // ci-dessus) : la propagation orbitale simplifiée utilisée ici (voir l'avertissement en
            // tête de SatelliteLookupService.swift) perd en précision à mesure que les éléments
            // orbitaux vieillissent.
            if hoursSinceCapture <= maxUsefulLookupAgeHours {
                let satelliteSemaphore = DispatchSemaphore(value: 0)
                var satelliteResult: Result<[CelestialPositionCalculator.BodyPosition], SatelliteLookupService.LookupError> = .failure(.networkUnavailable)
                SatelliteLookupService.fetchVisibleSatellitePositions(at: session.timestamp, observerLatitude: captureLocation.lat, observerLongitude: captureLocation.lon) { result in
                    satelliteResult = result
                    satelliteSemaphore.signal()
                }
                _ = satelliteSemaphore.wait(timeout: .now() + 8)
                if case .success(let satellitePositions) = satelliteResult {
                    candidates.append(contentsOf: satellitePositions)
                }
            }
            // Tolérance volontairement large (12°) : cumul de l'imprécision de la boussole ARKit (peut
            // dériver de plusieurs degrés, surtout près d'interférences magnétiques) et de la précision
            // des formules orbitales à basse précision utilisées pour les astres (~1°) — mieux vaut
            // manquer une vraie correspondance que d'en affirmer une fausse à tort. Réutilisée telle
            // quelle pour les satellites (voir ci-dessus) bien que leur propagation simplifiée soit
            // moins précise que les formules planétaires — voir l'avertissement de précision en tête
            // de SatelliteLookupService.swift, qui recommande une validation sur appareil réel.
            let matchToleranceDegrees = 12.0
            if let closest = candidates.min(by: {
                AngularGeometry.angularSeparationDegrees(az1: observed.azimuthDegrees, el1: observed.elevationDegrees, az2: $0.azimuthDegrees, el2: $0.elevationDegrees)
                < AngularGeometry.angularSeparationDegrees(az1: observed.azimuthDegrees, el1: observed.elevationDegrees, az2: $1.azimuthDegrees, el2: $1.elevationDegrees)
            }) {
                let separation = AngularGeometry.angularSeparationDegrees(az1: observed.azimuthDegrees, el1: observed.elevationDegrees, az2: closest.azimuthDegrees, el2: closest.elevationDegrees)
                if separation <= matchToleranceDegrees {
                    session.matchedCelestialBody = closest.name
                    session.celestialMatchSeparationDegrees = separation
                }
            }
        }

        // Distance/altitude par triangulation ne sont plus calculées (voir la dépréciation de
        // DistanceEstimator ci-dessus) — champs conservés pour l'affichage (voir ResultsView), mais
        // toujours vides désormais : le recoupement ADS-B ci-dessus identifie un objet réel plutôt
        // que de deviner sa taille pour en déduire une distance.
        session.estimatedDistanceMeters = nil
        session.estimatedAltitudeMeters = nil
        session.distanceConfidence = 0
        session.distanceMethod = "Non calculée (voir recoupement ADS-B/astres ci-dessus, plus fiable qu'une estimation par taille supposée)"
        session.distanceCrossCheckAgrees = nil

        report(3, "Calcul de la trajectoire…")
        // Étape 4 : trajectoire réelle (angulaire, corrigée du mouvement de la caméra) — voir
        // TrajectoryCalculator.swift. Sans distance fiable (triangulation retirée, voir ci-dessus),
        // la force G retombe sur son repli déjà existant (0, confiance 0) plutôt que sur une valeur
        // dérivée d'une distance devinée.
        let traj = trajectoryCalculator.computeTrajectory(detections: detections, frames: frames, estimatedDistanceMeters: nil)
        session.trajectory = traj.points2D
        session.isLinear = traj.isLinear
        session.linearityR2 = traj.linearityR2
        session.estimatedGForce = traj.estimatedGForce
        session.gForceConfidence = traj.gForceConfidence
        session.hasImpossibleGForce = traj.exceedsHumanTolerance
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
        // Étape 6 : vitesse (voir SpeedCalculator.swift). `distanceMeters` toujours `nil` désormais
        // (triangulation retirée, voir ci-dessus) — retombe sur le repli déjà existant de
        // SpeedCalculator ("Vitesse non calculable"), pas une nouvelle dégradation.
        let speed = speedCalculator.estimateSpeed(trajectory: traj, distanceMeters: nil)
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
struct Detection: Timestamped {
    var boundingBox: CGRect
    var timestamp: TimeInterval
}

extension AnalysisSession {
    static func == (lhs: AnalysisSession, rhs: AnalysisSession) -> Bool {
        lhs.id == rhs.id
    }
}
