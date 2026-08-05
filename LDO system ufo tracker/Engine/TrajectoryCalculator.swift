// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import simd
import CoreGraphics

/// Calcule la trajectoire réelle (dans le ciel, pas seulement à l'écran) d'un objet suivi,
/// et estime les forces G subies lors des changements de direction (étape 4 du pipeline LDO).
///
/// MÉTHODE — pourquoi on ne peut pas juste "suivre les pixels" :
/// Un déplacement rapide de pixels à l'écran peut venir soit d'un objet qui bouge vite,
/// soit d'un mouvement de caméra (la personne qui filme bouge son bras). On corrige donc
/// systématiquement la position de l'objet par la pose réelle de la caméra (ARKit) pour obtenir
/// sa **direction angulaire réelle dans le ciel**, indépendante des tremblements de la main.
///
/// La conversion en forces G "physiques" (m/s²) exige en plus une distance à l'objet.
/// Cette distance étant une estimation faible (triangulation angulaire, voir étape 8), le résultat
/// en G est toujours accompagné d'un indice de confiance — jamais présenté comme une mesure certaine.
final class TrajectoryCalculator {

    private let humanToleranceG: Double = 9.0   // tolérance soutenue maximale d'un être humain sans combinaison G
    private let smoothingWindow = 3             // lissage anti-bruit avant dérivation (vitesse/accélération)

    func computeTrajectory(
        detections: [Detection],
        frames: [CapturedFrame],
        estimatedDistanceMeters: Double?
    ) -> TrajectoryResult {
        guard detections.count >= 3 else {
            return TrajectoryResult.insufficientData(points2D: detections.map { center($0.boundingBox) })
        }

        // 1. Pour chaque détection, retrouver la pose caméra la plus proche en temps
        //    et convertir la position 2D (pixels/normalisé) en direction 3D réelle dans le ciel.
        let angularSamples: [AngularSample] = detections.compactMap { detection in
            guard let frame = nearestFrame(to: detection.timestamp, in: frames),
                  let direction = rayDirection(for: detection.boundingBox, frame: frame)
            else { return nil }
            return AngularSample(direction: direction, timestamp: detection.timestamp)
        }
        guard angularSamples.count >= 3 else {
            return TrajectoryResult.insufficientData(points2D: detections.map { center($0.boundingBox) })
        }

        // 2. Lissage léger (moyenne glissante) pour ne pas confondre le bruit de détection
        //    pixel par pixel avec un véritable changement de trajectoire.
        let smoothed = smooth(angularSamples, window: smoothingWindow)

        // 3. Test de linéarité : régression sur les directions angulaires successives.
        //    R² proche de 1 => trajectoire rectiligne continue ; sinon => asymétrique.
        let (isLinear, r2) = linearityTest(smoothed)

        // 4. Vitesse angulaire et accélération angulaire (toujours calculables, sans distance).
        let angularVelocities = angularVelocity(smoothed)          // degrés/seconde
        let angularAcceleration = derivative(angularVelocities)     // degrés/seconde²
        let maxAngularAcceleration = angularAcceleration.map { abs($0.value) }.max() ?? 0

        // 5. Détection des changements de direction brusques (virages) par courbure locale.
        let curvatureEvents = detectSharpTurns(smoothed, distanceMeters: estimatedDistanceMeters)

        // 6. Estimation des forces G.
        //    - Si une distance est disponible : accélération latérale réelle ≈ distance × accélération angulaire (rad/s²)
        //      (valide pour un mouvement perpendiculaire à la ligne de visée, cas le plus fréquent en observation).
        //    - Sinon : on NE PRÉTEND PAS connaître de valeur en G ; on ne signale qu'un comportement
        //      angulaire "extrême" à titre qualitatif, avec confiance nulle sur la valeur en G elle-même.
        let gResult = estimateGForce(
            maxAngularAccelerationDegPerS2: maxAngularAcceleration,
            distanceMeters: estimatedDistanceMeters
        )

        // 7. Points 2D (pixels) pour le tracé rouge sur la vidéo/les photos.
        let points2D = detections.map { center($0.boundingBox) }

        return TrajectoryResult(
            points2D: points2D,
            isLinear: isLinear,
            linearityR2: r2,
            maxAngularAccelerationDegPerS2: maxAngularAcceleration,
            angularVelocitiesDegPerS: angularVelocities,
            estimatedGForce: gResult.value,
            gForceConfidence: gResult.confidence,
            exceedsHumanTolerance: gResult.value > humanToleranceG && gResult.confidence > 0.3,
            curvatureEvents: curvatureEvents
        )
    }

    // MARK: - 1. Conversion pixel -> rayon 3D réel

    /// Convertit une boîte englobante (repère Vision, normalisé, origine bas-gauche) en une direction
    /// unitaire dans l'espace réel, en tenant compte de la focale (intrinsics) et de l'orientation
    /// de la caméra au moment exact de la détection (cameraTransform). Retourne `nil` si cette image
    /// n'a pas de pose ARKit associée (vidéo importée depuis la bibliothèque) : dans ce cas, la
    /// trajectoire ne peut être calculée que sur les points 2D à l'écran (voir `points2D`), pas en
    /// direction réelle dans le ciel.
    private func rayDirection(for box: CGRect, frame: CapturedFrame) -> SIMD3<Double>? {
        guard let intrinsics = frame.intrinsics, let cameraTransform = frame.cameraTransform else { return nil }

        let imageWidth = Double(frame.image.width)
        let imageHeight = Double(frame.image.height)

        let centerNorm = CGPoint(x: box.midX, y: box.midY)
        let pixelX = Double(centerNorm.x) * imageWidth
        let pixelY = (1.0 - Double(centerNorm.y)) * imageHeight   // Vision (bas-gauche) -> image (haut-gauche)

        let fx = Double(intrinsics.columns.0.x)
        let fy = Double(intrinsics.columns.1.y)
        let cx = Double(intrinsics.columns.2.x)
        let cy = Double(intrinsics.columns.2.y)

        // Direction dans le repère caméra (axe Z vers l'avant).
        let cameraSpace = SIMD3<Double>((pixelX - cx) / fx, (pixelY - cy) / fy, 1.0)
        let normalizedCameraSpace = simd_normalize(cameraSpace)

        // Rotation caméra -> monde, extraite de la pose ARKit à cet instant.
        let rotation = simd_double3x3(
            SIMD3<Double>(Double(cameraTransform.columns.0.x), Double(cameraTransform.columns.0.y), Double(cameraTransform.columns.0.z)),
            SIMD3<Double>(Double(cameraTransform.columns.1.x), Double(cameraTransform.columns.1.y), Double(cameraTransform.columns.1.z)),
            SIMD3<Double>(Double(cameraTransform.columns.2.x), Double(cameraTransform.columns.2.y), Double(cameraTransform.columns.2.z))
        )
        return simd_normalize(rotation * normalizedCameraSpace)
    }

    private func nearestFrame(to timestamp: TimeInterval, in frames: [CapturedFrame]) -> CapturedFrame? {
        frames.min(by: { abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp) })
    }

    // MARK: - 2. Lissage

    private func smooth(_ samples: [AngularSample], window: Int) -> [AngularSample] {
        guard samples.count > window else { return samples }
        var result: [AngularSample] = []
        for i in 0..<samples.count {
            let lo = max(0, i - window / 2)
            let hi = min(samples.count - 1, i + window / 2)
            let slice = samples[lo...hi]
            let avgDir = simd_normalize(slice.reduce(SIMD3<Double>(0,0,0)) { $0 + $1.direction } / Double(slice.count))
            result.append(AngularSample(direction: avgDir, timestamp: samples[i].timestamp))
        }
        return result
    }

    // MARK: - 3. Linéarité

    /// Ajuste les directions successives à une trajectoire angulaire rectiligne et retourne le R²
    /// (1.0 = parfaitement rectiligne, proche de 0 = trajectoire très irrégulière).
    private func linearityTest(_ samples: [AngularSample]) -> (isLinear: Bool, r2: Double) {
        guard samples.count >= 3 else { return (true, 1.0) }

        let start = samples.first!.direction
        let end = samples.last!.direction
        let axis = simd_normalize(end - start == SIMD3<Double>(0,0,0) ? SIMD3<Double>(1,0,0) : end - start)

        // Somme des écarts perpendiculaires à la droite start->end, normalisée par l'étendue totale.
        var totalDeviation = 0.0
        for sample in samples {
            let vector = sample.direction - start
            let projection = simd_dot(vector, axis)
            let perpendicular = vector - projection * axis
            totalDeviation += simd_length(perpendicular)
        }
        let averageDeviation = totalDeviation / Double(max(samples.count, 1))
        let r2 = max(0, 1 - averageDeviation * 50) // mise à l'échelle empirique (angles unitaires, petits écarts)
        return (r2 > 0.97, r2)
    }

    // MARK: - 4. Vitesse et accélération angulaires

    private func angularVelocity(_ samples: [AngularSample]) -> [TimedValue] {
        var result: [TimedValue] = []
        for i in 1..<samples.count {
            let dt = samples[i].timestamp - samples[i-1].timestamp
            guard dt > 0.001 else { continue }
            let angle = angleBetween(samples[i-1].direction, samples[i].direction) // radians
            let degPerSec = (angle * 180 / .pi) / dt
            result.append(TimedValue(timestamp: samples[i].timestamp, value: degPerSec))
        }
        return result
    }

    private func derivative(_ series: [TimedValue]) -> [TimedValue] {
        var result: [TimedValue] = []
        for i in 1..<series.count {
            let dt = series[i].timestamp - series[i-1].timestamp
            guard dt > 0.001 else { continue }
            let d = (series[i].value - series[i-1].value) / dt
            result.append(TimedValue(timestamp: series[i].timestamp, value: d))
        }
        return result
    }

    private func angleBetween(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let dot = max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b))))
        return acos(dot)
    }

    // MARK: - 5. Virages brusques

    private func detectSharpTurns(_ samples: [AngularSample], distanceMeters: Double?) -> [CurvatureEvent] {
        guard samples.count >= 3 else { return [] }
        var events: [CurvatureEvent] = []

        for i in 1..<(samples.count - 1) {
            let v1 = samples[i].direction - samples[i-1].direction
            let v2 = samples[i+1].direction - samples[i].direction
            guard simd_length(v1) > 0.0001, simd_length(v2) > 0.0001 else { continue }
            let turnAngleRad = angleBetween(v1, v2)
            let turnAngleDeg = turnAngleRad * 180 / .pi

            // Un virage "brusque" : plus de 30° de changement de direction entre deux segments courts.
            guard turnAngleDeg > 30 else { continue }

            let dt = samples[i+1].timestamp - samples[i-1].timestamp
            let gEstimate = estimateGForce(
                maxAngularAccelerationDegPerS2: dt > 0 ? turnAngleDeg / dt : 0,
                distanceMeters: distanceMeters
            )

            events.append(CurvatureEvent(
                timestamp: samples[i].timestamp,
                turnAngleDegrees: turnAngleDeg,
                estimatedGForce: gEstimate.value
            ))
        }
        return events
    }

    // MARK: - 6. Estimation des forces G

    private func estimateGForce(
        maxAngularAccelerationDegPerS2: Double,
        distanceMeters: Double?
    ) -> (value: Double, confidence: Double) {
        guard let distance = distanceMeters, distance > 0 else {
            // Sans distance fiable, on ne calcule PAS de valeur en G : la convertir sans distance
            // donnerait un chiffre pseudo-précis mais physiquement arbitraire.
            return (0, 0)
        }
        let angularAccelRadPerS2 = maxAngularAccelerationDegPerS2 * .pi / 180
        // Approximation : accélération latérale (m/s²) ≈ distance (m) × accélération angulaire (rad/s²)
        // valable pour un mouvement perpendiculaire à la ligne de visée — cas le plus courant en observation manuelle.
        let lateralAcceleration = distance * angularAccelRadPerS2
        let g = lateralAcceleration / 9.81

        // Confiance : directement liée à la confiance de l'estimation de distance elle-même
        // (fournie par l'étape 8). Ici on plafonne prudemment car aucune mesure directe de distance
        // n'est disponible pour un objet aérien lointain (distance par triangulation uniquement).
        let confidence = 0.35
        return (g, confidence)
    }

    private func center(_ box: CGRect) -> CGPoint {
        CGPoint(x: box.midX, y: box.midY)
    }
}

// MARK: - Types

struct AngularSample {
    let direction: SIMD3<Double>   // vecteur unitaire, direction réelle dans le ciel
    let timestamp: TimeInterval
}

struct TimedValue {
    let timestamp: TimeInterval
    let value: Double
}

struct CurvatureEvent {
    let timestamp: TimeInterval
    let turnAngleDegrees: Double
    let estimatedGForce: Double
}

struct TrajectoryResult {
    var points2D: [CGPoint]
    var isLinear: Bool = true
    var linearityR2: Double = 1.0
    var maxAngularAccelerationDegPerS2: Double = 0
    var angularVelocitiesDegPerS: [TimedValue] = []   // série chronologique, réutilisée pour le calcul de vitesse en km/h
    var estimatedGForce: Double = 0
    var gForceConfidence: Double = 0
    var exceedsHumanTolerance: Bool = false
    var curvatureEvents: [CurvatureEvent] = []

    static func insufficientData(points2D: [CGPoint]) -> TrajectoryResult {
        TrajectoryResult(points2D: points2D, isLinear: true, linearityR2: 0, maxAngularAccelerationDegPerS2: 0, angularVelocitiesDegPerS: [], estimatedGForce: 0, gForceConfidence: 0, exceedsHumanTolerance: false, curvatureEvents: [])
    }
}
