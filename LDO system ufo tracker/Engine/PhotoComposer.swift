// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Compose les 3 photos demandées à partir de l'image la plus nette parmi celles qui ont une
/// détection associée (voir `FrameQualityScorer`) :
/// 1. Plan large, image complète, sans recadrage.
/// 2. Zoom automatique maximum sur la cible détectée (l'objet remplit l'essentiel du cadre).
/// 3. Zoom fixe × 2 centré sur la cible.
///
/// Le recadrage se fait sur l'image source en pleine résolution (jamais sous-échantillonnée
/// d'abord), PUIS le résultat est agrandi à la taille de l'image d'origine. Un point lumineux
/// distant ne fait parfois que quelques pixels de large : sans cet agrandissement, le recadrage
/// resterait minuscule et illisible à l'écran même si le zoom « fonctionne » techniquement — l'image
/// finale est donc volontairement plus douce (interpolée) en échange d'être réellement visible,
/// conformément à l'ajustement demandé par l'utilisateur.
enum PhotoComposer {
    private static let targetObjectFraction: CGFloat = 0.6   // l'objet doit remplir ~60% du cadre "zoom max"
    private static let maxZoomFactor: CGFloat = 8             // plafond, pour éviter un zoom absurde sur un artefact minuscule
    private static let fixedZoomFactor: CGFloat = 2

    static func composePhotoSet(frames: [CapturedFrame], detections: [Detection]) -> [CGImage] {
        guard let (bestFrame, bestDetection) = bestFrameWithDetection(frames: frames, detections: detections) else {
            // Aucune détection exploitable : seul le plan large a un sens.
            guard let sharpest = frames.max(by: { FrameQualityScorer.score($0.image) < FrameQualityScorer.score($1.image) }) else {
                return []
            }
            return [sharpest.image]
        }

        var photos: [CGImage] = [bestFrame.image]   // 1. Plan large, sans zoom.

        let autoZoom = maxZoomFactor(for: bestDetection.boundingBox, image: bestFrame.image)
        if let zoomedMax = crop(bestFrame.image, centeredOn: bestDetection.boundingBox, zoomFactor: autoZoom) {
            photos.append(enhance(zoomedMax) ?? zoomedMax)   // 2. Zoom automatique maximum sur la cible, rehaussé.
        }
        if let zoomed2x = crop(bestFrame.image, centeredOn: bestDetection.boundingBox, zoomFactor: fixedZoomFactor) {
            photos.append(zoomed2x)    // 3. Zoom fixe × 2.
        }

        return photos
    }

    /// Associe chaque détection à l'image capturée la plus proche en temps, puis retient la paire
    /// dont l'image est la plus nette — c'est la meilleure prise pour recadrer/zoomer sur la cible.
    private static func bestFrameWithDetection(frames: [CapturedFrame], detections: [Detection]) -> (CapturedFrame, Detection)? {
        guard !detections.isEmpty, !frames.isEmpty else { return nil }
        let pairs: [(CapturedFrame, Detection)] = detections.compactMap { detection in
            guard let frame = frames.min(by: { abs($0.timestamp - detection.timestamp) < abs($1.timestamp - detection.timestamp) })
            else { return nil }
            return (frame, detection)
        }
        return pairs.max { FrameQualityScorer.score($0.0.image) < FrameQualityScorer.score($1.0.image) }
    }

    /// Facteur de zoom tel que la cible remplisse `targetObjectFraction` du cadre recadré, plafonné
    /// à `maxZoomFactor` et jamais en dessous de 1 (on ne "dézoome" jamais au-delà de l'image d'origine).
    private static func maxZoomFactor(for box: CGRect, image: CGImage) -> CGFloat {
        let objectWidthPixels = box.width * CGFloat(image.width)
        let objectHeightPixels = box.height * CGFloat(image.height)
        let objectSize = max(objectWidthPixels, objectHeightPixels)
        guard objectSize > 0 else { return 1 }

        let desiredCropSize = objectSize / targetObjectFraction
        let maxPossibleCropSize = CGFloat(min(image.width, image.height))
        let factor = maxPossibleCropSize / desiredCropSize
        return min(max(factor, 1), maxZoomFactor)
    }

    /// Recadre `image` autour du centre de `box` (repère Vision, normalisé, origine bas-gauche) à
    /// `zoomFactor` — ex. zoomFactor=2 conserve un quart de la surface (moitié en largeur/hauteur) —
    /// puis agrandit le résultat à la taille de l'image d'origine (voir note en tête de fichier).
    private static func crop(_ image: CGImage, centeredOn box: CGRect, zoomFactor: CGFloat) -> CGImage? {
        guard zoomFactor > 1 else { return image }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let cropWidth = max(1, width / zoomFactor)
        let cropHeight = max(1, height / zoomFactor)

        let centerX = box.midX * width
        let centerY = (1 - box.midY) * height   // Vision (bas-gauche) -> image (haut-gauche)

        let originX = min(max(0, centerX - cropWidth / 2), width - cropWidth)
        let originY = min(max(0, centerY - cropHeight / 2), height - cropHeight)

        let rect = CGRect(x: originX, y: originY, width: cropWidth, height: cropHeight).integral
        guard let cropped = image.cropping(to: rect) else { return nil }
        return upscale(cropped, toWidth: image.width, height: image.height) ?? cropped
    }

    /// Agrandit `image` à `width`×`height` avec la meilleure qualité d'interpolation disponible en
    /// Core Graphics — le résultat est nécessairement plus doux que l'original (aucun détail réel
    /// n'est ajouté), mais reste visible, ce qui est le but recherché ici.
    private static func upscale(_ image: CGImage, toWidth width: Int, height: Int) -> CGImage? {
        guard let colorSpace = image.colorSpace,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: image.bitmapInfo.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Rehausse contraste et saturation de la photo « zoom maximum » — un point lumineux distant,
    /// même une fois agrandi (voir `upscale`), reste souvent terne et peu contrasté par rapport au
    /// fond du ciel une fois recadré numériquement. Ce rehaussement reproduit sur toutes les photos,
    /// automatiquement, ce que l'utilisateur devait auparavant faire manuellement (recadrage +
    /// retouche) pour bien distinguer l'objet.
    private static let enhanceContext = CIContext()

    private static func enhance(_ image: CGImage) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        let filter = CIFilter.colorControls()
        filter.inputImage = ciImage
        filter.contrast = 1.35
        filter.saturation = 1.4
        filter.brightness = 0.05
        guard let output = filter.outputImage else { return nil }
        return enhanceContext.createCGImage(output, from: ciImage.extent)
    }
}
