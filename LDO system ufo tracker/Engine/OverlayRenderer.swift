// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import CoreGraphics
import CoreText
import CoreImage
import CoreMedia
import AVFoundation

/// Étape 9 : incruste sur les photos et la vidéo :
/// - la trajectoire de l'objet, en rouge
/// - la date et l'heure du signalement, en rouge, en bas de l'image
/// - la vitesse maximale obtenue, en rouge, en bas de l'image
/// - le logo LDO en haut à droite, TOUJOURS (filigrane de marque, voir `draw`)
/// - le logo LDO (soucoupe verte fluo) en bas à droite, UNIQUEMENT si le verdict penche vers "OVNI"
enum OverlayRenderer {

    /// Dessine les incrustations sur une image fixe (les 3 photos optimales).
    ///
    /// `drawTrajectory` : les points de `session.trajectory` sont calculés en coordonnées normalisées
    /// relatives à l'image COMPLÈTE d'origine — corrects seulement quand `image` est cette image
    /// complète (le plan large, voir `PhotoComposer`). Sur un recadrage/zoom (les photos 2 et 3),
    /// ces mêmes coordonnées tombent n'importe où dans le cadre plus petit (des points rouges sans
    /// rapport avec la cible) : on désactive donc ce tracé pour ces photos-là.
    static func draw(on image: CGImage, session: AnalysisSession, drawTrajectory: Bool = true) -> CGImage {
        let width = image.width
        let height = image.height

        guard let colorSpace = image.colorSpace,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: image.bitmapInfo.rawValue
              )
        else { return image }

        // Image de base.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // CoreGraphics a l'origine en bas à gauche ; nos points de trajectoire sont en repère
        // Vision normalisé (0..1, aussi origine bas-gauche), donc conversion directe en pixels.
        context.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.9))
        context.setLineWidth(max(2, CGFloat(width) * 0.004))
        context.setLineJoin(.round)

        if drawTrajectory, session.trajectory.count >= 2 {
            let path = CGMutablePath()
            let first = pixelPoint(session.trajectory[0], width: width, height: height)
            path.move(to: first)
            for point in session.trajectory.dropFirst() {
                path.addLine(to: pixelPoint(point, width: width, height: height))
            }
            context.addPath(path)
            context.strokePath()

            // Petits repères circulaires à chaque point mesuré.
            for point in session.trajectory {
                let p = pixelPoint(point, width: width, height: height)
                let r = CGFloat(width) * 0.006
                context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.9))
                context.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
        }

        // Texte rouge en bas de l'image : date/heure + vitesse max.
        let dateText = DateFormatter.overlayFormatter.string(from: session.timestamp)
        let speedText = session.maxSpeedKmh > 0 ? String(format: "Vitesse max. : %.0f km/h", session.maxSpeedKmh) : "Vitesse : non calculable"
        drawBottomText(context: context, lines: [dateText, speedText], width: width, height: height)

        // Logo LDO en haut à droite, TOUJOURS visible — image de marque sur les 3 photos et la
        // vidéo exportée, demande explicite de Jean-David (2026-08-09). Distinct du logo
        // conditionnel ci-dessous (en bas à droite, lui uniquement si le verdict penche vers un
        // phénomène non identifié) : celui-ci est un simple filigrane de marque, pas un indicateur.
        let topRightRadius = CGFloat(width) * 0.035
        let topRightCenter = CGPoint(
            x: CGFloat(width) - topRightRadius - CGFloat(width) * 0.03,
            y: CGFloat(height) - topRightRadius - CGFloat(height) * 0.03
        )
        drawLogoPlaceholder(context: context, width: width, height: height, center: topRightCenter)

        // Logo LDO en bas à droite, seulement si le verdict penche vers un phénomène non identifié.
        if session.verdictConfidencePercent >= 60 {
            let bottomRightRadius = CGFloat(width) * 0.035
            let bottomRightCenter = CGPoint(
                x: CGFloat(width) - bottomRightRadius - CGFloat(width) * 0.03,
                y: bottomRightRadius + CGFloat(height) * 0.03
            )
            drawLogoPlaceholder(context: context, width: width, height: height, center: bottomRightCenter)
        }

        return context.makeImage() ?? image
    }

    /// Exporte `sourceURL` en incrustant, image par image, les mêmes éléments que `draw(on:session:)`
    /// (trajectoire complète du clip, date/heure, vitesse, logo conditionnel). La trajectoire affichée
    /// est déjà celle de l'ensemble du clip (pas de position instantanée par image dans `AnalysisSession`),
    /// donc l'incrustation est identique sur toute la durée — cohérent avec le rendu des 3 photos.
    ///
    /// Bridge synchrone autour de l'export asynchrone d'AVFoundation, dans le même esprit que
    /// `SoundClassifier` dans `AnalysisEngine.analyze(...)` : acceptable ici car on est déjà hors
    /// du fil principal (voir `CaptureManager.stopRecordingAndAnalyze`).
    static func exportVideoWithOverlays(sourceURL: URL?, session: AnalysisSession) -> URL? {
        guard let sourceURL else { return nil }
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { return sourceURL }

        // Orientation réelle de la piste source, déduite de son `preferredTransform` — PAS supposée
        // fixe. Bug corrigé (2026-08-09, signalé par Jean-David : plantage de l'app après analyse
        // d'une vidéo importée de la bibliothèque) : le compositeur personnalisé ci-dessous appliquait
        // auparavant une rotation .right CODÉE EN DUR, une hypothèse valable uniquement pour nos
        // propres enregistrements LIVE (ARKit délivre toujours un buffer paysage natif, quelle que
        // soit l'orientation de l'appareil — voir `CGImage.from(pixelBuffer:)`, où cette même hypothèse
        // EST correcte). Une vidéo importée depuis la bibliothèque peut avoir n'importe quel
        // `preferredTransform` selon l'appareil/l'app qui l'a filmée — appliquer la mauvaise rotation
        // produit une image dont les dimensions ne correspondent plus au buffer de sortie attendu par
        // `renderContext`/`ciContext.render(to:)`, provoquant un plantage plutôt qu'une simple image
        // de travers.
        let orientation = Self.cgOrientation(for: videoTrack.preferredTransform)
        let isRotated90 = orientation == .left || orientation == .right

        let composition = AVMutableVideoComposition()
        let naturalSize = videoTrack.naturalSize
        composition.renderSize = isRotated90
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.customVideoCompositorClass = VideoOverlayCompositor.self

        let instruction = OverlayVideoCompositionInstruction(
            sourceTrackID: videoTrack.trackID,
            timeRange: CMTimeRange(start: .zero, duration: asset.duration),
            session: session,
            sourceOrientation: orientation
        )
        composition.instructions = [instruction]

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            return sourceURL
        }
        export.outputURL = outputURL
        export.outputFileType = .mov
        export.videoComposition = composition

        let semaphore = DispatchSemaphore(value: 0)
        export.exportAsynchronously { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 30)

        return export.status == .completed ? outputURL : sourceURL
    }

    /// Compositeur vidéo : applique `draw(on:session:)` image par image sur la vidéo complète (pas
    /// seulement les 3 photos), via `exportVideoWithOverlays(sourceURL:session:)` ci-dessus.
    final class VideoOverlayCompositor: NSObject, AVVideoCompositing {
        var sourcePixelBufferAttributes: [String: Any]? = [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA]
        var requiredPixelBufferAttributesForRenderContext: [String: Any] = [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA]

        private let ciContext = CIContext()
        private var renderContext: AVVideoCompositionRenderContext?

        func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
            renderContext = newRenderContext
        }

        func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
            guard
                let instruction = asyncVideoCompositionRequest.videoCompositionInstruction as? OverlayVideoCompositionInstruction,
                let sourceBuffer = asyncVideoCompositionRequest.sourceFrame(byTrackID: instruction.sourceTrackID),
                let outputBuffer = renderContext?.newPixelBuffer()
            else {
                asyncVideoCompositionRequest.finish(with: NSError(domain: "LDO.VideoOverlayCompositor", code: -1))
                return
            }

            // Les compositeurs personnalisés reçoivent le buffer brut de la piste, SANS que son
            // `preferredTransform` soit appliqué automatiquement — on le fait nous-même ici, avec
            // l'orientation réelle de CETTE piste (calculée dans `exportVideoWithOverlays`), pas une
            // rotation supposée fixe (voir le commentaire à ce point d'appel pour le bug que ça corrige).
            let sourceImage = CIImage(cvPixelBuffer: sourceBuffer).oriented(instruction.sourceOrientation)
            guard let sourceCGImage = ciContext.createCGImage(sourceImage, from: sourceImage.extent) else {
                asyncVideoCompositionRequest.finish(withComposedVideoFrame: sourceBuffer)
                return
            }

            let overlaidImage = OverlayRenderer.draw(on: sourceCGImage, session: instruction.session)
            ciContext.render(CIImage(cgImage: overlaidImage), to: outputBuffer)

            asyncVideoCompositionRequest.finish(withComposedVideoFrame: outputBuffer)
        }

        func cancelAllPendingVideoCompositionRequests() {}
    }

    /// Convertit le `preferredTransform` d'une piste vidéo (rotation pure, cas quasi systématique en
    /// pratique — pas de cisaillement) en l'orientation `CIImage.oriented(_:)` correspondante, pour
    /// afficher le buffer brut de la piste dans le bon sens quelle que soit sa source (ARKit ou
    /// bibliothèque). Voir le commentaire dans `exportVideoWithOverlays` pour le bug que ça corrige.
    private static func cgOrientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let angle = atan2(transform.b, transform.a)
        let tolerance = 0.1
        if abs(angle - .pi / 2) < tolerance { return .right }        // rotation 90° horaire
        if abs(angle + .pi / 2) < tolerance { return .left }         // rotation 90° antihoraire
        if abs(abs(angle) - .pi) < tolerance { return .down }        // rotation 180°
        return .up                                                    // pas de rotation (paysage tel quel)
    }

    // MARK: - Détail du dessin

    private static func pixelPoint(_ normalized: CGPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(x: normalized.x * CGFloat(width), y: normalized.y * CGFloat(height))
    }

    private static func drawBottomText(context: CGContext, lines: [String], width: Int, height: Int) {
        let fontSize = CGFloat(width) * 0.025
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        ]

        var yOffset: CGFloat = CGFloat(height) * 0.03
        for line in lines.reversed() {
            let attributedString = CFAttributedStringCreate(nil, line as CFString, attributes as CFDictionary)!
            let ctLine = CTLineCreateWithAttributedString(attributedString)
            context.textPosition = CGPoint(x: CGFloat(width) * 0.03, y: yOffset)
            CTLineDraw(ctLine, context)
            yOffset += fontSize * 1.3
        }
    }

    /// Version simplifiée du logo (cercle + "LDO" vert fluo) directement en CoreGraphics, pour ne
    /// pas dépendre du chargement d'un asset image dans ce module utilitaire. `center` en repère
    /// CoreGraphics (origine bas-gauche, contrairement à Vision).
    private static func drawLogoPlaceholder(context: CGContext, width: Int, height: Int, center: CGPoint) {
        let radius = CGFloat(width) * 0.035

        context.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.06, alpha: 0.85))
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.setStrokeColor(CGColor(red: 57/255.0, green: 1, blue: 20/255.0, alpha: 1))
        context.setLineWidth(radius * 0.12)
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, radius * 0.7, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 57/255.0, green: 1, blue: 20/255.0, alpha: 1)
        ]
        let attributedString = CFAttributedStringCreate(nil, "LDO" as CFString, attributes as CFDictionary)!
        let ctLine = CTLineCreateWithAttributedString(attributedString)
        let bounds = CTLineGetBoundsWithOptions(ctLine, [])
        context.textPosition = CGPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 3)
        CTLineDraw(ctLine, context)
    }
}

/// Instruction de composition minimale : une seule piste source, la même incrustation sur toute
/// la durée du clip (voir `OverlayRenderer.exportVideoWithOverlays`).
final class OverlayVideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let sourceTrackID: CMPersistentTrackID
    let session: AnalysisSession
    /// Orientation réelle de la piste source (voir `OverlayRenderer.cgOrientation(for:)`), appliquée
    /// image par image dans `VideoOverlayCompositor.startRequest`.
    let sourceOrientation: CGImagePropertyOrientation

    init(sourceTrackID: CMPersistentTrackID, timeRange: CMTimeRange, session: AnalysisSession, sourceOrientation: CGImagePropertyOrientation) {
        self.sourceTrackID = sourceTrackID
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = [NSNumber(value: sourceTrackID)]
        self.session = session
        self.sourceOrientation = sourceOrientation
    }
}

private extension DateFormatter {
    static let overlayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd  HH:mm:ss"
        formatter.locale = Locale(identifier: "fr_CA")
        return formatter
    }()
}
