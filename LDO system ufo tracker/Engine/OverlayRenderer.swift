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

        // Logo LDO en bas à droite, seulement si le verdict penche vers un phénomène non identifié.
        if session.verdictConfidencePercent >= 60 {
            drawLogoPlaceholder(context: context, width: width, height: height)
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

        let composition = AVMutableVideoComposition()
        // Le compositeur personnalisé ci-dessous pivote lui-même chaque image (voir `startRequest`),
        // donc la taille de rendu est directement la taille portrait (dimensions inversées).
        let naturalSize = videoTrack.naturalSize
        composition.renderSize = CGSize(width: naturalSize.height, height: naturalSize.width)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.customVideoCompositorClass = VideoOverlayCompositor.self

        let instruction = OverlayVideoCompositionInstruction(
            sourceTrackID: videoTrack.trackID,
            timeRange: CMTimeRange(start: .zero, duration: asset.duration),
            session: session
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

            // Même correction d'orientation que `CGImage.from(pixelBuffer:)` : le buffer source est
            // le paysage natif ARKit non transformé (les compositeurs personnalisés reçoivent les
            // images brutes, sans le `preferredTransform` de la piste).
            let sourceImage = CIImage(cvPixelBuffer: sourceBuffer).oriented(.right)
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
    /// pas dépendre du chargement d'un asset image dans ce module utilitaire.
    private static func drawLogoPlaceholder(context: CGContext, width: Int, height: Int) {
        let radius = CGFloat(width) * 0.035
        let center = CGPoint(x: CGFloat(width) - radius - CGFloat(width) * 0.03, y: radius + CGFloat(height) * 0.03)

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

    init(sourceTrackID: CMPersistentTrackID, timeRange: CMTimeRange, session: AnalysisSession) {
        self.sourceTrackID = sourceTrackID
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = [NSNumber(value: sourceTrackID)]
        self.session = session
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
