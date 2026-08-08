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
    /// soit considérée comme un objet plausible et non du bruit vidéo (grain, compression capteur).
    /// Volontairement petit : un point lumineux distant (le cas typique d'une observation réelle)
    /// peut ne faire que quelques pixels de large — un seuil trop élevé le rejetterait comme "bruit".
    private let minimumBlobArea: CGFloat = 0.00004   // ≈ un carré de 6x6 px sur une image 1024x1024
    private let maximumBlobArea: CGFloat = 0.35      // évite de suivre un nuage entier ou un changement d'exposition global

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

    // MARK: - Détection alternative par luminosité (voir AnalysisEngine)

    /// Détecte l'objet en cherchant directement, image par image, la zone la plus brillante —
    /// plutôt que par différence de mouvement entre deux images consécutives. Bien plus fiable pour
    /// le cas d'usage principal de LDO (un objet lumineux sur un ciel sombre) : ça fonctionne même
    /// si l'appareil est tenu très stable ou si l'objet se déplace lentement à l'écran, deux cas où
    /// la différence de mouvement entre images consécutives est trop faible pour être détectée.
    /// Utilisée en priorité par `AnalysisEngine` ; la détection par mouvement (`detectMovingObjects`)
    /// reste un repli pour les scènes à plus faible contraste (ex. observation de jour).
    ///
    /// NE S'ACTIVE QUE SUR UNE SCÈNE GLOBALEMENT SOMBRE (ciel nocturne) : sans ce garde-fou, sur un
    /// éclairage de pièce normal (jour, intérieur éclairé), n'importe quel objet moyennement clair —
    /// une main, un mur, un vêtement pâle — ressortirait comme « le plus brillant », sans aucun
    /// rapport avec un véritable point lumineux isolé sur fond sombre.
    private let darkSceneThreshold: Double = 90   // luminance moyenne 0-255 ; au-dessus, scène jugée normalement éclairée

    /// `hintPoint` : point que l'utilisateur a touché dans `ClipTrimView` pour désigner l'objet
    /// (repère Vision, normalisé) — sert de point de départ à la continuité de suivi (voir
    /// `brightestBoundingBox`) au lieu de partir sans a priori sur la première image.
    func detectByLuminosity(in frames: [CapturedFrame], hintPoint: CGPoint? = nil) -> [TrackedObject] {
        guard isDarkScene(frames) else { return [] }

        var detections: [Detection] = []
        var previousCenter: CGPoint? = hintPoint
        for frame in frames {
            guard let box = brightestBoundingBox(in: frame.image, previousCenter: previousCenter) else { continue }
            detections.append(Detection(boundingBox: box, timestamp: frame.timestamp))
            previousCenter = CGPoint(x: box.midX, y: box.midY)
        }
        guard detections.count >= 3 else { return [] }
        return [TrackedObject(id: UUID(), detections: detections)]
    }

    /// Détection « mode Jour » : symétrique de `detectByLuminosity`, mais pour un objet qui apparaît
    /// SOMBRE (silhouette à contre-jour) sur un ciel clair de jour, plutôt que lumineux sur fond
    /// sombre. Même principe de seuil adaptatif, inversé.
    ///
    /// NE S'ACTIVE QUE SUR UNE SCÈNE GLOBALEMENT CLAIRE (ciel de jour) — symétrique du garde-fou de
    /// `detectByLuminosity`.
    func detectDarkObjectOnBrightSky(in frames: [CapturedFrame], hintPoint: CGPoint? = nil) -> [TrackedObject] {
        guard isBrightScene(frames) else { return [] }

        var detections: [Detection] = []
        var previousCenter: CGPoint? = hintPoint
        for frame in frames {
            guard let box = darkestBoundingBox(in: frame.image, previousCenter: previousCenter) else { continue }
            detections.append(Detection(boundingBox: box, timestamp: frame.timestamp))
            previousCenter = CGPoint(x: box.midX, y: box.midY)
        }
        guard detections.count >= 3 else { return [] }
        return [TrackedObject(id: UUID(), detections: detections)]
    }

    /// Échantillonne quelques images pour estimer si la scène est globalement sombre.
    private func isDarkScene(_ frames: [CapturedFrame]) -> Bool {
        guard let mean = meanSampledLuminance(frames) else { return false }
        return mean < darkSceneThreshold
    }

    /// Échantillonne quelques images pour estimer si la scène est globalement claire (ciel de jour).
    private func isBrightScene(_ frames: [CapturedFrame]) -> Bool {
        guard let mean = meanSampledLuminance(frames) else { return false }
        return mean >= darkSceneThreshold
    }

    private func meanSampledLuminance(_ frames: [CapturedFrame]) -> Double? {
        guard !frames.isEmpty else { return nil }
        let step = max(1, frames.count / 5)
        let sampledIndices = stride(from: 0, to: frames.count, by: step)
        let averages = sampledIndices.compactMap { averageLuminance(of: frames[$0].image) }
        guard !averages.isEmpty else { return nil }
        return averages.reduce(0, +) / Double(averages.count)
    }

    private func averageLuminance(of image: CGImage) -> Double? {
        let ciImage = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3.0
    }

    /// Seuillage ADAPTATIF (pas un seuil fixe) : calculé à mi-chemin entre la luminosité moyenne et
    /// maximale de CHAQUE image. Un seuil fixe agressif (l'ancienne approche, contraste + gamma^6)
    /// écrase à zéro un point lumineux seulement modérément plus brillant que le ciel environnant —
    /// le cas typique d'une vraie observation (étoile ou point lointain, pas une source aveuglante).
    /// En se calant sur l'écart RÉEL entre le fond et le point le plus clair de l'image, ce seuil
    /// s'ajuste aussi bien à un point très brillant qu'à un point seulement un peu plus clair que
    /// son environnement.
    /// `previousCenter`, quand disponible, favorise le candidat le plus proche de la détection de
    /// l'image précédente plutôt que systématiquement le plus grand blob de l'image courante — un
    /// point lumineux distant scintille légèrement (bruit capteur, seuil adaptatif qui varie d'une
    /// image à l'autre) : sans cette continuité, la détection peut « sauter » d'une image à l'autre
    /// vers un blob de bruit différent, ce qui produit une trajectoire artificiellement saccadée et
    /// donc une vitesse calculée bien plus élevée et bruitée que le déplacement réel (typiquement
    /// lent) de l'objet observé.
    private func brightestBoundingBox(in image: CGImage, previousCenter: CGPoint?) -> CGRect? {
        let ciImage = CIImage(cgImage: image)
        guard let threshold = adaptiveBrightnessThreshold(ciImage) else { return nil }

        guard let thresholdFilter = CIFilter(name: "CIColorThreshold") else { return nil }
        thresholdFilter.setValue(ciImage, forKey: kCIInputImageKey)
        thresholdFilter.setValue(Float(threshold), forKey: "inputThreshold")
        guard let mask = thresholdFilter.outputImage else { return nil }

        let candidates = detectContourBoundingBoxes(in: mask)
            .filter { $0.width * $0.height >= minimumBlobArea && $0.width * $0.height <= maximumBlobArea }
        guard !candidates.isEmpty else { return nil }

        if let previousCenter {
            // Rayon de recherche généreux (20% de la diagonale normalisée — doublé à la demande
            // explicite de Jean-David pour mieux capter l'objet ciblé au toucher, voir aussi
            // `detectDarkObjectOnBrightSky` ci-dessous) : sert à la fois de rayon de recherche autour
            // du point touché à l'écran (premier appel, `previousCenter = hintPoint`) et de rayon de
            // continuité de suivi image à image ensuite — assez large pour suivre un déplacement réel,
            // assez serré pour ignorer un nouveau blob de bruit apparu ailleurs dans le ciel.
            let maxTrackingDistance: CGFloat = 0.2
            let nearby = candidates.filter { candidate in
                let center = CGPoint(x: candidate.midX, y: candidate.midY)
                let dx = center.x - previousCenter.x
                let dy = center.y - previousCenter.y
                return (dx * dx + dy * dy).squareRoot() <= maxTrackingDistance
            }
            if let closest = nearby.min(by: { distanceSquared($0, to: previousCenter) < distanceSquared($1, to: previousCenter) }) {
                return closest
            }
        }

        // Pas de détection précédente (première image) ou rien à proximité (objet réapparu ailleurs) :
        // repli sur le plus grand blob, comme avant.
        return candidates.max { $0.width * $0.height < $1.width * $1.height }
    }

    private func distanceSquared(_ box: CGRect, to point: CGPoint) -> CGFloat {
        let dx = box.midX - point.x
        let dy = box.midY - point.y
        return dx * dx + dy * dy
    }

    private func adaptiveBrightnessThreshold(_ image: CIImage) -> Double? {
        guard let avg = luminanceStat(image, filterName: "CIAreaAverage"),
              let max = luminanceStat(image, filterName: "CIAreaMaximum"),
              max > avg
        else { return nil }
        // À mi-chemin entre le fond et le point le plus clair : capte le point lumineux dominant
        // sans dépendre de sa luminosité absolue.
        return avg + 0.5 * (max - avg)
    }

    /// Luminosité (moyenne ou maximale selon `filterName`), normalisée 0...1 pour `CIColorThreshold`.
    private func luminanceStat(_ image: CIImage, filterName: String) -> Double? {
        guard let filter = CIFilter(name: filterName) else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: image.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let luminance = 0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])
        return luminance / 255.0
    }

    /// Symétrique de `brightestBoundingBox` pour le mode Jour : au lieu de chercher un seuil adaptatif
    /// sur l'image telle quelle, on l'applique sur son NÉGATIF — ainsi la silhouette sombre de l'objet
    /// (la partie la plus foncée du ciel clair) devient la région la plus « brillante » sur l'image
    /// inversée, et on réutilise exactement la même logique de seuillage adaptatif que la nuit.
    private func darkestBoundingBox(in image: CGImage, previousCenter: CGPoint?) -> CGRect? {
        let ciImage = CIImage(cgImage: image)
        guard let inverted = invertedImage(ciImage) else { return nil }
        guard let threshold = adaptiveBrightnessThreshold(inverted) else { return nil }

        guard let thresholdFilter = CIFilter(name: "CIColorThreshold") else { return nil }
        thresholdFilter.setValue(inverted, forKey: kCIInputImageKey)
        thresholdFilter.setValue(Float(threshold), forKey: "inputThreshold")
        guard let mask = thresholdFilter.outputImage else { return nil }

        let candidates = detectContourBoundingBoxes(in: mask)
            .filter { $0.width * $0.height >= minimumBlobArea && $0.width * $0.height <= maximumBlobArea }
        guard !candidates.isEmpty else { return nil }

        // Même continuité de suivi que `brightestBoundingBox` (voir sa documentation) — évite qu'un
        // scintillement de contraste fasse sauter la détection d'une silhouette à une autre.
        if let previousCenter {
            let maxTrackingDistance: CGFloat = 0.2
            let nearby = candidates.filter { candidate in
                let center = CGPoint(x: candidate.midX, y: candidate.midY)
                let dx = center.x - previousCenter.x
                let dy = center.y - previousCenter.y
                return (dx * dx + dy * dy).squareRoot() <= maxTrackingDistance
            }
            if let closest = nearby.min(by: { distanceSquared($0, to: previousCenter) < distanceSquared($1, to: previousCenter) }) {
                return closest
            }
        }

        return candidates.max { $0.width * $0.height < $1.width * $1.height }
    }

    private func invertedImage(_ image: CIImage) -> CIImage? {
        let filter = CIFilter.colorInvert()
        filter.inputImage = image
        return filter.outputImage
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
