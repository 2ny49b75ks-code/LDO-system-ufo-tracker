// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Vision

/// Étape 3 : classification de la forme + isolement de la zone lumineuse.
///
/// IMPORTANT — honnêteté sur la méthode : il n'existe aucun modèle CoreML public entraîné à
/// reconnaître un "OVNI" (par définition, on n'a pas de base de données d'OVNI confirmés).
/// Ce module utilise donc des **heuristiques de mouvement et de forme** pour distinguer les
/// causes les plus fréquentes d'observations d'OVNI (insecte proche caméra, oiseau, drone,
/// avion/satellite lointain) d'un objet réellement non identifié. Un vrai modèle CoreML entraîné
/// sur des vidéos annotées (avions, drones, oiseaux, insectes) améliorerait nettement la précision
/// et peut remplacer `heuristicClassify` sans changer le reste du pipeline.
final class ShapeClassifier {

    private let ciContext = CIContext()

    func classifyShape(detections: [Detection], frames: [CapturedFrame], mode: CaptureMode) -> ShapeResult {
        guard detections.count >= 3 else {
            return ShapeResult(label: "Données insuffisantes", confidence: 0, luminousRegion: nil)
        }

        // 0. Détection d'une main humaine (Vision, sur l'appareil, aucun modèle personnalisé requis) :
        // une main agitée devant la caméra produit un signal de mouvement (oscillation, déplacement)
        // qui ressemble à s'y méprendre à un oiseau ou un insecte pour les heuristiques ci-dessous —
        // ce test prioritaire l'identifie explicitement plutôt que de la confondre avec un animal.
        if detectHand(in: frames, detections: detections) {
            let midDetection = detections[safe: detections.count / 2]
            let luminous = midDetection.flatMap { isolateLuminousRegion(for: $0, frames: frames) }
            return ShapeResult(label: "Main détectée", confidence: 0.9, luminousRegion: luminous)
        }

        // 1. Signal de mouvement : amplitude et régularité des oscillations de position.
        let motion = motionSignature(detections)

        // 2. Signal de forme : régularité de la taille apparente (un objet qui s'éloigne/rapproche
        //    change de taille progressivement ; un objet à distance constante a une taille stable).
        let sizeVariability = sizeSignature(detections)

        // 2bis. Signal de silhouette : rapport largeur/hauteur moyen de la boîte de détection — un
        //    avion, même lointain et minuscule à l'écran, a une envergure d'ailes qui le rend
        //    nettement plus large que haut ; un point lumineux ou un oiseau replié n'a pas cette
        //    asymétrie. Voir `heuristicClassify`.
        let aspectRatio = aspectRatioSignature(detections)

        // 2ter. Signal de rectitude du chemin global : déplacement net (début -> fin) divisé par la
        //    longueur totale du chemin parcouru — proche de 1 pour une trajectoire qui ne revient
        //    jamais sur elle-même, plus bas pour un chemin qui serpente. Ajouté 2026-08-09 (signalé
        //    par Jean-David sur un avion réel classé à tort « oiseau ») : contrairement au taux
        //    d'oscillation (`motion.oscillationRate`), qui compte les inversions de direction
        //    IMAGE PAR IMAGE et se fait donc facilement polluer par le tremblement de la main en
        //    suivant l'avion au zoom, la rectitude du chemin GLOBAL reste fiable même en présence de
        //    ce bruit local — un avion reste net-linéaire d'un bout à l'autre du clip malgré un léger
        //    zigzag image par image, ce qu'un oiseau (qui « vole rarement en ligne droite », selon la
        //    règle explicite de Jean-David) ne produit pas.
        let (straightness, totalDisplacement) = pathStraightnessAndDisplacement(detections)

        // 3. Isolement de la zone lumineuse sur l'image médiane (la plus représentative).
        let midDetection = detections[safe: detections.count / 2]
        let luminous = midDetection.flatMap { isolateLuminousRegion(for: $0, frames: frames) }

        // 4. Classification heuristique combinant ces signaux.
        let (label, confidence) = heuristicClassify(motion: motion, sizeVariability: sizeVariability, aspectRatio: aspectRatio, straightness: straightness, totalDisplacement: totalDisplacement, mode: mode)

        return ShapeResult(label: label, confidence: confidence, luminousRegion: luminous)
    }

    /// Isole la zone lumineuse pour une détection donnée (réutilisé par IlluminationAnalyzer pour
    /// échantillonner l'évolution de la luminosité/couleur sur plusieurs images de la séquence).
    func isolateLuminousRegion(for detection: Detection, frames: [CapturedFrame]) -> LuminousRegion? {
        guard let frame = frames.min(by: { abs($0.timestamp - detection.timestamp) < abs($1.timestamp - detection.timestamp) })
        else { return nil }

        let ciImage = CIImage(cgImage: frame.image)
        let cropRect = pixelRect(for: detection.boundingBox, imageSize: CGSize(width: frame.image.width, height: frame.image.height))
        // Une boîte de détection quasi nulle (suivi Vision dégradé) produit un recadrage d'étendue
        // vide, dont le rendu Core Image plante sur du matériel réel (moteur Metal) — le simulateur
        // (rendu logiciel) ne le révèle jamais. On écarte ces détections dégénérées en amont.
        guard cropRect.width >= 2, cropRect.height >= 2, cropRect.intersects(ciImage.extent) else { return nil }
        let cropped = ciImage.cropped(to: cropRect)

        // Seuillage de luminosité : ne garde que les pixels significativement plus clairs que la
        // moyenne locale, ce qui isole la source lumineuse propre de l'objet du reste du cadrage.
        let controls = CIFilter.colorControls()
        controls.inputImage = cropped
        controls.brightness = -0.3
        controls.contrast = 4.0
        guard let isolated = controls.outputImage else { return nil }

        guard let averages = try? averageLuminance(of: isolated) else { return nil }
        let irregularity = contourIrregularity(of: isolated)

        return LuminousRegion(
            boundingBoxInImage: cropRect,
            averageBrightness: averages.brightness,
            averageColor: averages.color,
            contourIrregularity: irregularity
        )
    }

    /// Irrégularité du contour de la tache lumineuse isolée (0 = tache ronde et nette proche d'un
    /// point source ; proche de 1 = contour amorphe/irrégulier — bords qui débordent, forme non
    /// circulaire). Facteur additionnel PONDÉRÉ pour le verdict (voir `VerdictCalculator`), pas une
    /// règle absolue : une tache floue/irrégulière peut aussi bien être un objet réel dont le contour
    /// est net mais mal focalisé qu'un artefact optique, d'où un poids modéré plutôt qu'un plancher.
    ///
    /// Méthode : seuille l'image isolée (déjà contrastée par `isolateLuminousRegion` ci-dessus) et
    /// mesure le taux de remplissage de pixels "clairs" dans sa boîte englobante — une source
    /// ponctuelle nette remplit une forme proche d'un disque (~78,5% d'une boîte carrée) ; un
    /// contour très irrégulier remplit soit beaucoup moins (bords dentelés, trous), soit très
    /// différemment de ce ratio.
    private func contourIrregularity(of image: CIImage) -> Double {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return 0 }

        let sampleSize = 24
        var bitmap = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        ciContext.render(
            image, toBitmap: &bitmap, rowBytes: sampleSize * 4,
            bounds: CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: extent.height),
            format: .RGBA8, colorSpace: nil
        )

        var brightPixels = 0
        for i in stride(from: 0, to: bitmap.count, by: 4) {
            let luminance = 0.299 * Double(bitmap[i]) + 0.587 * Double(bitmap[i + 1]) + 0.114 * Double(bitmap[i + 2])
            if luminance > 128 { brightPixels += 1 }
        }
        let fillRatio = Double(brightPixels) / Double(sampleSize * sampleSize)

        // Taux de remplissage idéal d'un disque net dans sa boîte englobante carrée : π/4.
        let idealCircularFillRatio = Double.pi / 4
        return min(abs(fillRatio - idealCircularFillRatio) / idealCircularFillRatio, 1.0)
    }

    /// Génère une approximation 3D très simplifiée : extrusion de la silhouette lumineuse 2D en un
    /// volume mince. Ce n'est PAS une reconstruction 3D véritable (celle-ci demanderait plusieurs
    /// points de vue simultanés ou un scan LiDAR rapproché) — seulement une aide visuelle pour la
    /// page de résultats, clairement présentée comme une approximation.
    func buildApproximate3DSilhouette(luminousRegion: LuminousRegion?) -> URL? {
        guard luminousRegion != nil else { return nil }
        // Implémentation réelle : RealityKit — ProceduralMesh généré à partir du masque de silhouette
        // (isolateLuminousRegion), extrudé sur une faible épaisseur, exporté en .usdz via
        // Entity.write(to:). Omis ici (dépend du runtime RealityKit, non disponible hors iOS).
        return nil
    }

    /// Échantillonne quelques images (jusqu'à 5) autour des détections et cherche une main humaine
    /// confiante via `VNDetectHumanHandPoseRequest` — API Vision native, aucun modèle CoreML
    /// personnalisé nécessaire. Une seule image concluante suffit : la main n'a pas besoin d'être
    /// visible sur toute la séquence pour être la véritable explication de l'observation.
    private func detectHand(in frames: [CapturedFrame], detections: [Detection]) -> Bool {
        let sampleTimestamps = Set(detections.prefix(5).map { $0.timestamp })
        let samples = frames.filter { sampleTimestamps.contains($0.timestamp) }
        let framesToCheck = samples.isEmpty ? Array(frames.prefix(5)) : samples

        for frame in framesToCheck {
            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 1
            let handler = VNImageRequestHandler(cgImage: frame.image, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let observation = request.results?.first
            else { continue }
            if observation.confidence > 0.6 {
                return true
            }
        }
        return false
    }

    // MARK: - Signaux

    private func motionSignature(_ detections: [Detection]) -> MotionSignature {
        let centers = detections.map { CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY) }
        var directionChanges = 0
        var totalDisplacement: CGFloat = 0

        if centers.count > 2 {
            for i in 2..<centers.count {
                let v1 = CGVector(dx: centers[i-1].x - centers[i-2].x, dy: centers[i-1].y - centers[i-2].y)
                let v2 = CGVector(dx: centers[i].x - centers[i-1].x, dy: centers[i].y - centers[i-1].y)
                let dot = v1.dx * v2.dx + v1.dy * v2.dy
                if dot < 0 { directionChanges += 1 } // inversion de direction = battement/oscillation
                totalDisplacement += hypot(v2.dx, v2.dy)
            }
        }

        let oscillationRate = Double(directionChanges) / Double(max(centers.count - 2, 1))
        return MotionSignature(oscillationRate: oscillationRate, averageDisplacementPerFrame: Double(totalDisplacement) / Double(max(centers.count, 1)))
    }

    private func sizeSignature(_ detections: [Detection]) -> Double {
        let areas = detections.map { $0.boundingBox.width * $0.boundingBox.height }
        guard let mean = areas.isEmpty ? nil : areas.reduce(0, +) / CGFloat(areas.count), mean > 0 else { return 0 }
        let variance = areas.reduce(0) { $0 + pow($1 - mean, 2) } / CGFloat(areas.count)
        return Double(sqrt(variance) / mean) // coefficient de variation : 0 = taille parfaitement stable
    }

    /// Rapport largeur/hauteur moyen de la boîte de détection sur toute la séquence.
    private func aspectRatioSignature(_ detections: [Detection]) -> Double {
        let ratios = detections.compactMap { d -> Double? in
            guard d.boundingBox.height > 0 else { return nil }
            return Double(d.boundingBox.width / d.boundingBox.height)
        }
        guard !ratios.isEmpty else { return 1 }
        return ratios.reduce(0, +) / Double(ratios.count)
    }

    /// Rectitude du chemin global (voir commentaire au point d'appel) : 1.0 = chemin parfaitement
    /// rectiligne du premier au dernier point détecté, plus bas pour un chemin qui serpente ou
    /// revient sur lui-même. `totalDisplacement` (déplacement net, même unité normalisée 0...1 que
    /// les boîtes de détection) sert de garde-fou : un objet quasi immobile qui tremblote sur place
    /// peut avoir un chemin « droit » par pur hasard sur un déplacement négligeable, ce qui ne doit
    /// pas suffire à conclure à un avion.
    private func pathStraightnessAndDisplacement(_ detections: [Detection]) -> (straightness: Double, totalDisplacement: Double) {
        let centers = detections.map { CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY) }
        guard let first = centers.first, let last = centers.last, centers.count >= 2 else { return (1, 0) }

        var pathLength: CGFloat = 0
        for i in 1..<centers.count {
            pathLength += hypot(centers[i].x - centers[i-1].x, centers[i].y - centers[i-1].y)
        }
        let netDisplacement = hypot(last.x - first.x, last.y - first.y)
        guard pathLength > 0 else { return (1, 0) }
        return (Double(netDisplacement / pathLength), Double(netDisplacement))
    }

    private func heuristicClassify(motion: MotionSignature, sizeVariability: Double, aspectRatio: Double, straightness: Double, totalDisplacement: Double, mode: CaptureMode) -> (String, Double) {
        // En Mode Nuit, la détection ne porte que sur une source lumineuse isolée (voir
        // MotionDetector.detectByLuminosity) — un oiseau ou un insecte en vol de nuit ne produit pas
        // de lumière propre, donc ces deux explications sont exclues d'office (règle explicite de
        // Jean-David) : seule une trajectoire de type avion/satellite peut expliquer l'objet, sinon
        // il reste non identifié.
        if mode == .day {
            // Oscillation très fréquente + déplacement irrégulier de faible amplitude à l'écran =>
            // signature typique d'un insecte volant tout près de l'objectif (cause très fréquente de
            // faux signalements d'OVNI).
            if motion.oscillationRate > 0.5 && motion.averageDisplacementPerFrame < 0.05 {
                return ("Probable insecte proche de l'objectif", 0.55)
            }
        }

        // Trajectoire globale continue sur un déplacement réel à l'écran => avion, drone ou
        // satellite. Vérifié EN PRIORITÉ, avant le signal d'oscillation ci-dessous — règle explicite
        // de Jean-David (« un avion a une trajectoire continue, un oiseau vole rarement en ligne
        // droite »), corrige un bug réel (2026-08-09) où un avion filmé en zoomant à la main était
        // classé « oiseau » : le tremblement de la main en le suivant faisait apparaître assez
        // d'inversions de direction IMAGE PAR IMAGE pour tomber dans la fourchette d'oscillation d'un
        // battement d'aile, alors que le chemin global restait net-linéaire (mêmes causes que le bug
        // de zigzag déjà corrigé dans TrajectoryCalculator, mais ici sur la classification de forme).
        if straightness > 0.85 && totalDisplacement > 0.05 {
            return ("Probable avion ou satellite (trajectoire continue)", 0.55)
        }

        if mode == .day {
            // Oscillation modérée et régulière, SUR UN CHEMIN QUI SERPENTE (le chemin global n'est
            // pas resté net-linéaire, sinon la règle de trajectoire continue ci-dessus aurait déjà
            // conclu à un avion) => battements d'ailes, évoque un oiseau.
            if motion.oscillationRate > 0.2 && motion.oscillationRate <= 0.5 {
                return ("Probable oiseau (mouvement oscillant régulier)", 0.45)
            }
        }
        // Déplacement très linéaire, taille stable => avion ou satellite à distance constante.
        if motion.oscillationRate < 0.1 && sizeVariability < 0.15 {
            return ("Probable avion ou satellite (trajectoire stable)", 0.4)
        }
        // Silhouette au moins aussi large que haute (envergure des ailes) + mouvement peu oscillant
        // => avion, même si la taille apparente varie plus que le seuil strict ci-dessus (normal en
        // filmant à main levée en zoomant sur un avion lointain — l'objet reste minuscule à l'écran,
        // sujet à la mise au point/l'exposition qui fait varier légèrement sa taille apparente d'une
        // image à l'autre sans que ce soit un vrai changement de distance). Signal indépendant de la
        // stabilité de taille : un avion garde son envergure caractéristique quelle que soit la
        // fluctuation de taille détectée. Ajouté 2026-08-08 suite à un avion réel non reconnu (tombait
        // dans "non identifiée" malgré une trajectoire quasi parfaitement rectiligne, R² 0.97).
        // Seuil recalibré à 0,7 (2026-08-09, à partir de données réelles) : le rapport envergure/
        // longueur d'un avion de ligne se situe typiquement entre 0,7 et 1,1 (Boeing 737 : ~0,9 ;
        // A350/787 : ~0,9-1,0) — l'ancien seuil de 1,4 exigeait à tort une silhouette bien plus large
        // que haute, alors qu'un avion vu sous la plupart des angles (léger virage, montée) produit une
        // silhouette proche du carré, pas une forme franchement "large".
        if motion.oscillationRate < 0.15 && aspectRatio >= 0.7 {
            return ("Probable avion ou satellite (silhouette compatible avec un avion)", 0.45)
        }
        // Aucun signal net dominant => on ne force pas une conclusion.
        return ("Forme non identifiée avec certitude", 0.15)
    }

    // MARK: - Isolement de la zone lumineuse (voir la méthode publique isolateLuminousRegion ci-dessus)

    private func averageLuminance(of image: CIImage) throws -> (brightness: Double, color: (r: Double, g: Double, b: Double)) {
        let extentVector = CIVector(x: image.extent.origin.x, y: image.extent.origin.y, z: image.extent.size.width, w: image.extent.size.height)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: extentVector]),
              let outputImage = filter.outputImage else {
            return (0, (0, 0, 0))
        }
        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(outputImage, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let r = Double(bitmap[0]) / 255, g = Double(bitmap[1]) / 255, b = Double(bitmap[2]) / 255
        let brightness = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return (brightness, (r, g, b))
    }

    private func pixelRect(for normalizedBox: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: normalizedBox.origin.x * imageSize.width,
            y: (1 - normalizedBox.origin.y - normalizedBox.height) * imageSize.height,
            width: normalizedBox.width * imageSize.width,
            height: normalizedBox.height * imageSize.height
        )
    }
}

private struct MotionSignature {
    let oscillationRate: Double
    let averageDisplacementPerFrame: Double
}

struct LuminousRegion {
    let boundingBoxInImage: CGRect
    let averageBrightness: Double     // 0 (noir) à 1 (blanc pur)
    let averageColor: (r: Double, g: Double, b: Double)
    /// 0 = tache ronde et nette (point source) ; proche de 1 = contour amorphe/irrégulier.
    /// Voir `ShapeClassifier.contourIrregularity`. Facteur pondéré additionnel pour le verdict.
    let contourIrregularity: Double
}

struct ShapeResult {
    let label: String
    let confidence: Double
    let luminousRegion: LuminousRegion?
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
