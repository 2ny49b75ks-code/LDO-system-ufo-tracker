// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import CoreGraphics
import CoreText
import AVFoundation

/// Étape 9 : incruste sur les photos et la vidéo :
/// - la trajectoire de l'objet, en rouge
/// - la date et l'heure du signalement, en rouge, en bas de l'image
/// - la vitesse maximale obtenue, en rouge, en bas de l'image
/// - le logo LDO (soucoupe verte fluo) en bas à droite, UNIQUEMENT si le verdict penche vers "OVNI"
enum OverlayRenderer {

    /// Dessine les incrustations sur une image fixe (les 3 photos optimales).
    static func draw(on image: CGImage, session: AnalysisSession) -> CGImage {
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

        if session.trajectory.count >= 2 {
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

    /// Compositeur vidéo : structure à implémenter avec AVVideoCompositing pour appliquer les mêmes
    /// incrustations image par image sur la vidéo complète (pas seulement les 3 photos). Le principe
    /// est identique à `draw(on:session:)` mais exécuté dans `startRequest(_:)` pour chaque CVPixelBuffer
    /// de la composition, avec interpolation de la position de trajectoire selon le temps de chaque image.
    final class VideoOverlayCompositor: NSObject, AVVideoCompositing {
        var sourcePixelBufferAttributes: [String: Any]? = [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA]
        var requiredPixelBufferAttributesForRenderContext: [String: Any] = [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA]

        func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

        func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
            // Pour chaque image de la vidéo : récupérer le CVPixelBuffer source, le convertir en
            // CGImage, appliquer `draw(on:session:)` avec les points de trajectoire interpolés au
            // temps `asyncVideoCompositionRequest.compositionTime`, reconvertir en CVPixelBuffer,
            // puis appeler `finish(withComposedVideoFrame:)`. Omis ici : dépend du runtime AVFoundation.
            asyncVideoCompositionRequest.finish(with: NSError(domain: "LDO", code: -1))
        }
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

private extension DateFormatter {
    static let overlayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd  HH:mm:ss"
        formatter.locale = Locale(identifier: "fr_CA")
        return formatter
    }()
}
