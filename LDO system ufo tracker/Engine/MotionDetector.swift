// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

/// Détecteur de mouvement (étape 2 du pipeline LDO).
///
/// Principe en 3 passes, image par image :
///  1. Différence absolue entre deux images consécutives (Core Image) → isole ce qui a changé.
///  2. Seuillage + nettoyage du bruit → masque binaire des zones en mouvement.
///  3. Détection des contours du masque (Vision) → boîtes englobantes candidates.
///  4. Suivi (tracking) de chaque candidat sur les images suivantes avec VNTrackObjectRequest,
///     pour obtenir une trajectoire continue par objet plutôt que des détections isolées.
final class MotionDetector {

    private let ciContext = CIContext()
    private let sequenceHandler = VNSequenceRequestHandler()

    /// Surface minimale (en proportion de l'image, 0 à 1) pour qu'une zone en mouvement
    /// soit considérée comme un objet plausible et non du bruit vidéo (grain, compression, insectes sur l'objectif très proches).
    private let minimumBlobArea: CGFloat = 0.0006   // ≈ un carré de 25x25 px sur une image 1024x1024
    private let maximumBlobArea: CGFloat = 0.35     // évite de suivre un nuage entier ou un changement d'exposition global

    /// Détecte les objets en mouvement sur l'ensemble de la séquence capturée.
    /// Retourne, pour chaque objet suivi, la liste chronologique de ses détections (utilisée
    /// ensuite pour calculer forme, trajectoire, vitesse, forces G).
    func detectMovingObjects(in frames: [CapturedFrame]) -> [TrackedObject] {
        guard frames.count >= 2 else { return [] }

        var trackedObjects: [TrackedObject] = []
        var activeTrackers: [ActiveTracker] = []

        for i in 1..<frames.count {
            let previous = frames[i - 1]
            let current = frames[i]

            // 1 & 2. Masque binaire des zones en mouvement entre deux images consécutives.
            guard let motionMask = motionMask(previous: previous.image, current: current.image) else {
                continue
            }

            // 3. Contours du masque → boîtes englobantes candidates (repère normalisé Vision : 0..1, origine en bas-gauche).
            let candidateBoxes = detectContourBoundingBoxes(in: motionMask)
                .filter { $0.width * $0.height >= minimumBlobArea && $0.width * $0.height <= maximumBlobArea }

            if activeTrackers.isEmpty {
                // Aucun suivi en cours : on initialise un tracker par candidat détecté.
                for box in candidateBoxes {
                    let observation = VNDetectedObjectObservation(boundingBox: box)
                    activeTrackers.append(ActiveTracker(
                        id: UUID(),
                        lastObservation: observation,
                        detections: [Detection(boundingBox: box, timestamp: current.timestamp)]
                    ))
                }
            } else {
                // Des trackers existent : on les fait progresser sur l'image courante,
                // puis on rattache les nouveaux candidats non suivis (nouvel objet entré dans le champ).
                updateTrackers(&activeTrackers, on: current.image, timestamp: current.timestamp)
                attachUnmatchedCandidates(candidateBoxes, to: &activeTrackers, timestamp: current.timestamp)
            }
        }

        // Clôture : on ne garde que les trackers ayant au moins 3 détections successives
        // (un objet réel en mouvement laisse une trace continue ; un artefact ponctuel est écarté).
        for tracker in activeTrackers where tracker.detections.count >= 3 {
            trackedObjects.append(TrackedObject(id: tracker.id, detections: tracker.detections))
        }

        return trackedObjects
    }

    // MARK: - 1 & 2. Masque de mouvement

    private func motionMask(previous: CGImage, current: CGImage) -> CIImage? {
        let ciPrevious = CIImage(cgImage: previous)
        let ciCurrent = CIImage(cgImage: current)

        // Différence absolue pixel par pixel entre les deux images.
        let diffFilter = CIFilter.differenceBlendMode()
        diffFilter.inputImage = ciCurrent
        diffFilter.backgroundImage = ciPrevious
        guard let diff = diffFilter.outputImage else { return nil }

        // Conversion en niveaux de gris (luminance) pour simplifier le seuillage.
        let grayFilter = CIFilter.colorControls()
        grayFilter.inputImage = diff
        grayFilter.saturation = 0
        grayFilter.contrast = 3.0   // amplifie l'écart pour séparer le bruit du vrai mouvement
        guard let gray = grayFilter.outputImage else { return nil }

        // Seuillage : tout pixel sous le seuil devient noir (immobile), au-dessus devient blanc (mouvement).
        // CIColorClamp + gamma agressif approxime un seuillage dur.
        let gammaFilter = CIFilter.gammaAdjust()
        gammaFilter.inputImage = gray
        gammaFilter.power = 6.0
        guard let thresholded = gammaFilter.outputImage else { return nil }

        return thresholded.clampedToExtent().cropped(to: ciCurrent.extent)
    }

    // MARK: - 3. Contours du masque

    private func detectContourBoundingBoxes(in mask: CIImage) -> [CGRect] {
        guard let cgMask = ciContext.createCGImage(mask, from: mask.extent) else { return [] }

        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.0
        request.detectsDarkOnLight = false   // on cherche les zones CLAIRES (mouvement) sur fond sombre
        request.maximumImageDimension = 512  // suffisant pour des boîtes englobantes, plus rapide

        let handler = VNImageRequestHandler(cgImage: cgMask, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let results = request.results as? [VNContoursObservation], let observation = results.first else {
            return []
        }

        return observation.topLevelContours.map { $0.normalizedPath.boundingBox }
    }

    // MARK: - 4. Suivi (tracking) d'objet dans le temps

    private func updateTrackers(_ trackers: inout [ActiveTracker], on image: CGImage, timestamp: TimeInterval) {
        var stillActive: [ActiveTracker] = []

        for var tracker in trackers {
            let request = VNTrackObjectRequest(detectedObjectObservation: tracker.lastObservation)
            request.trackingLevel = .accurate

            do {
                try sequenceHandler.perform([request], on: image)
            } catch {
                continue // objet perdu : le tracker s'arrête ici
            }

            guard let result = request.results?.first as? VNDetectedObjectObservation,
                  result.confidence > 0.35 else {
                continue // confiance trop faible : probablement sorti du champ ou occulté
            }

            tracker.lastObservation = result
            tracker.detections.append(Detection(boundingBox: result.boundingBox, timestamp: timestamp))
            stillActive.append(tracker)
        }

        trackers = stillActive
    }

    private func attachUnmatchedCandidates(
        _ candidates: [CGRect],
        to trackers: inout [ActiveTracker],
        timestamp: TimeInterval
    ) {
        for box in candidates {
            let overlapsExisting = trackers.contains { tracker in
                tracker.lastObservation.boundingBox.intersection(box).width > 0 &&
                tracker.lastObservation.boundingBox.intersection(box).height > 0
            }
            guard !overlapsExisting else { continue }

            let observation = VNDetectedObjectObservation(boundingBox: box)
            trackers.append(ActiveTracker(
                id: UUID(),
                lastObservation: observation,
                detections: [Detection(boundingBox: box, timestamp: timestamp)]
            ))
        }
    }
}

// MARK: - Types

/// Objet suivi sur toute la durée de la vidéo : sert de base à l'analyse de forme,
/// trajectoire, vitesse et forces G dans AnalysisEngine.
struct TrackedObject {
    let id: UUID
    let detections: [Detection]   // chronologique
}

private struct ActiveTracker {
    let id: UUID
    var lastObservation: VNDetectedObjectObservation
    var detections: [Detection]
}
