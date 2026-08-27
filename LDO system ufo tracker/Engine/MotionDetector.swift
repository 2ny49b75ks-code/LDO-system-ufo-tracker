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

    /// Rapport largeur/hauteur (ou hauteur/largeur) maximal accepté pour un candidat plausible.
    /// Un fil électrique, une antenne ou toute autre ligne fine statique traversant une grande partie
    /// du cadre produit une boîte englobante très élancée (très large mais peu épaisse, ou l'inverse)
    /// — une signature géométrique très différente de tout objet volant réel (avion, oiseau, drone),
    /// même minuscule et lointain. Ajouté 2026-08-09 (signalé par Jean-David : le zoom automatique et
    /// le recadrage ×2 ciblaient systématiquement le fil électrique fixe en bas de l'image plutôt que
    /// l'avion réel — le fil, traversant presque toute la largeur du cadre, produit une boîte
    /// englobante dont l'AIRE dépasse celle de l'avion, minuscule à cette distance, et gagnait donc
    /// par défaut le repli « plus grand candidat » ci-dessous).
    private let maximumElongationRatio: CGFloat = 10

    /// Tolérance (fraction du cadre) en deçà de laquelle un bord de boîte englobante est considéré
    /// comme « touchant » le bord de l'image plutôt que d'être simplement proche.
    private let frameEdgeTolerance: CGFloat = 0.01

    /// `true` si `box` a une forme raisonnablement compacte (voir `maximumElongationRatio`) ET ne
    /// touche AUCUN bord du cadre — pas seulement une ligne fine traversant le cadre.
    ///
    /// BUG réel corrigé (2026-08-26, vidéo réelle fournie par Jean-David — avion filmé à travers une
    /// trouée entre des arbres) : sans ce deuxième critère, le détecteur verrouillait sur le feuillage
    /// d'un arbre en bordure d'image plutôt que sur l'avion minuscule au centre du ciel dégagé — le
    /// feuillage, bien plus grand que l'avion à cette distance, gagnait systématiquement le repli
    /// « plus grand candidat plausible » de `brightestBoundingBox`/`darkestBoundingBox`. Un vrai objet
    /// volant isolé dans le ciel (avion, oiseau, drone, OVNI) n'a, sur la quasi-totalité de son
    /// passage dans le cadre, AUCUN bord de sa boîte englobante collé à x=0, y=0, x=1 ou y=1 — alors
    /// qu'un arbre, un toit ou tout autre obstacle statique en bordure de cadre y touche presque
    /// toujours, puisqu'il continue hors champ. Repère fiable et indépendant de l'aire du candidat.
    private func isPlausibleObjectShape(_ box: CGRect) -> Bool {
        let longSide = max(box.width, box.height)
        let shortSide = max(min(box.width, box.height), 0.0001)
        guard (longSide / shortSide) < maximumElongationRatio else { return false }

        let touchesEdge = box.minX <= frameEdgeTolerance
            || box.minY <= frameEdgeTolerance
            || box.maxX >= 1 - frameEdgeTolerance
            || box.maxY >= 1 - frameEdgeTolerance
        return !touchesEdge
    }

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
                .filter { $0.width * $0.height >= minimumBlobArea && $0.width * $0.height <= maximumBlobArea && isPlausibleObjectShape($0) }

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

    /// Détecte une traînée de condensation (blanche/grise, nettement allongée) directement sur
    /// l'IMAGE ENTIÈRE plutôt qu'autour d'un objet déjà suivi — demande explicite de Jean-David
    /// (2026-08-26, deux vidéos réelles d'avions avec traînée nette). BUG corrigé : chercher une
    /// traînée seulement autour de l'avion lui-même (suivi par `detectDarkObjectOnBrightSky`) hérite
    /// de la fragilité de ce suivi sur une cible minuscule/lointaine dans une scène encombrée (arbres,
    /// fil électrique) — le suivi de l'avion « saute » facilement d'une image à l'autre (grand écart
    /// de position, trous dans la séquence), et la recherche de traînée autour d'une position fausse
    /// ne trouve rien. La traînée elle-même est un bien meilleur candidat de suivi : beaucoup plus
    /// grande, plus contrastée et plus stable d'une image à l'autre que le minuscule avion à son
    /// origine — la chercher directement, indépendamment du suivi de l'avion, est plus robuste.
    func detectContrailCandidate(in frames: [CapturedFrame]) -> [TrackedObject] {
        guard isBrightScene(frames) else { return [] }

        // Passe 1 : le MEILLEUR candidat de CHAQUE image, indépendamment (pas de contrainte de
        // continuité ici) — une scène peut contenir plusieurs taches blanches sans rapport (un petit
        // nuage isolé, un reflet fixe) en plus de la vraie traînée.
        var perFrameCandidates: [(timestamp: TimeInterval, box: CGRect)] = []
        for frame in frames {
            guard let box = contrailBoundingBox(in: frame.image) else { continue }
            perFrameCandidates.append((frame.timestamp, box))
        }
        guard perFrameCandidates.count >= 3 else { return [] }

        // Passe 2 : regroupe ces candidats par PROXIMITÉ à travers la séquence — une vraie traînée
        // reste au même endroit (à son propre allongement près) d'une image à l'autre ; un artefact
        // isolé n'apparaît que sporadiquement, pas de façon soutenue au même endroit.
        //
        // BUG corrigé (2026-08-26, vidéo réelle avec traînée fournie par Jean-David) : choisir le
        // meilleur candidat image par image avec continuité en avant seulement (accroche sur le
        // premier candidat rencontré, puis pénalise la distance) est fragile si la toute PREMIÈRE
        // image accroche par hasard sur le mauvais candidat (un artefact fixe plutôt que la vraie
        // traînée) — tout le suivi reste alors verrouillé sur cet artefact. Regrouper D'ABORD sur
        // l'ensemble de la séquence, puis choisir le groupe le plus SOUTENU (le plus de détections),
        // ne dépend pas de l'ordre d'arrivée.
        var clusters: [[(timestamp: TimeInterval, box: CGRect)]] = []
        let clusterDistanceThreshold = 0.12
        for candidate in perFrameCandidates {
            let center = CGPoint(x: candidate.box.midX, y: candidate.box.midY)
            if let index = clusters.indices.min(by: { lhs, rhs in
                clusterDistance(clusters[lhs], to: center) < clusterDistance(clusters[rhs], to: center)
            }), clusterDistance(clusters[index], to: center) < clusterDistanceThreshold {
                clusters[index].append(candidate)
            } else {
                clusters.append([candidate])
            }
        }

        guard let bestCluster = clusters.max(by: { $0.count < $1.count }), bestCluster.count >= 3 else { return [] }

        // BUG corrigé (2026-08-26, vidéo réelle SANS traînée fournie par Jean-David) : un fil
        // électrique, un rebord de toit ou toute autre structure fine et fixe de la scène peut
        // satisfaire les critères de saturation/élongation à CHAQUE image, formant un groupe soutenu
        // qui ressemble à une traînée réelle par sa continuité — mais sa boîte reste alors de taille
        // QUASI IDENTIQUE d'une image à l'autre (ici : bloquée à exactement 1 ligne de la grille sur
        // les 14 détections). Une vraie traînée s'ALLONGE progressivement à mesure qu'elle se forme
        // (×4 environ sur la traînée réelle confirmée). On exige donc une croissance significative de
        // la hauteur de la boîte à travers le groupe pour la retenir comme traînée plutôt qu'un
        // artefact fixe de la scène.
        let heights = bestCluster.map { Double($0.box.height) }
        guard let minHeight = heights.min(), let maxHeight = heights.max(), minHeight > 0,
              maxHeight / minHeight >= 1.8 else { return [] }

        let detections = bestCluster
            .sorted { $0.timestamp < $1.timestamp }
            .map { Detection(boundingBox: $0.box, timestamp: $0.timestamp) }
        return [TrackedObject(id: UUID(), detections: detections)]
    }

    /// Distance entre un point et le dernier centre connu d'un groupe (pas sa moyenne globale) — une
    /// traînée qui s'allonge progressivement dérive lentement, comparer au dernier point reste donc
    /// plus fiable qu'un centroïde figé sur tout l'historique du groupe.
    private func clusterDistance(_ cluster: [(timestamp: TimeInterval, box: CGRect)], to point: CGPoint) -> Double {
        guard let last = cluster.last else { return .infinity }
        return hypot(Double(last.box.midX - point.x), Double(last.box.midY - point.y))
    }

    /// Trouve, sur une image, la plus grande composante connexe de pixels significativement MOINS
    /// saturés que le bleu du ciel environnant (une traînée de condensation, même fine, dilue/éclaircit
    /// le bleu plutôt que de produire un blanc pur — voir la note ci-dessous) et suffisamment allongée
    /// pour être une traînée plutôt qu'un nuage compact. Composantes connexes calculées par
    /// remplissage par diffusion (flood fill) sur une grille sous-échantillonnée.
    ///
    /// BUGS CORRIGÉS (2026-08-26, deux vidéos réelles fournies par Jean-David) :
    ///  1. `ciContext.render(toBitmap:)` NE redimensionne PAS l'image pour remplir un buffer plus
    ///     petit — il rend `bounds` pixel pour pixel. Sans mise à l'échelle explicite au préalable
    ///     (`CIImage.transformed`), le rendu vers une petite grille ne lisait que le coin de l'image
    ///     près de l'origine, jamais une vue d'ensemble — la traînée n'était donc jamais examinée du
    ///     tout, peu importe le seuil de couleur utilisé.
    ///  2. Seuil de saturation ABSOLU (< 0,15) beaucoup trop strict : une vraie traînée de
    ///     condensation, mesurée sur les deux vidéos réelles, reste un bleu ÉCLAIRCI (saturation
    ///     ~0,40-0,50) plutôt qu'un blanc pur — jamais sous ~0,35 même en son point le plus net. Seuil
    ///     désormais ADAPTATIF : relatif à la saturation moyenne du ciel environnant CETTE image (même
    ///     principe que le seuil de luminosité adaptatif de `detectByLuminosity`/`darkestBoundingBox`),
    ///     pas une valeur fixe qui suppose à tort un blanc net.
    private func contrailBoundingBox(in image: CGImage) -> CGRect? {
        let cols = 120
        let rows = max(1, Int((Double(cols) * Double(image.height) / Double(image.width)).rounded()))

        let ciImage = CIImage(cgImage: image)
        let scale = CGAffineTransform(scaleX: Double(cols) / Double(image.width), y: Double(rows) / Double(image.height))
        let scaled = ciImage.transformed(by: scale)

        var bitmap = [UInt8](repeating: 0, count: cols * rows * 4)
        ciContext.render(
            scaled, toBitmap: &bitmap, rowBytes: cols * 4,
            bounds: CGRect(x: 0, y: 0, width: cols, height: rows),
            format: .RGBA8, colorSpace: nil
        )

        // Passe 1 : saturation moyenne des pixels assez lumineux (ciel), sert de référence pour le
        // seuil adaptatif ci-dessous.
        var brightSaturations: [Double] = []
        for i in 0..<(cols * rows) {
            let o = i * 4
            let r = Double(bitmap[o]), g = Double(bitmap[o + 1]), b = Double(bitmap[o + 2])
            let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
            guard maxC / 255.0 > 0.3 else { continue }
            brightSaturations.append(maxC > 0 ? (maxC - minC) / maxC : 0)
        }
        guard !brightSaturations.isEmpty else { return nil }
        let averageSkySaturation = brightSaturations.reduce(0, +) / Double(brightSaturations.count)
        // Sans écart significatif à mesurer (ciel déjà peu saturé — couvert/brumeux), le signal n'a
        // pas de sens : pas de référence "bleu franc" contre laquelle repérer un éclaircissement.
        guard averageSkySaturation > 0.25 else { return nil }
        let saturationThreshold = averageSkySaturation * 0.75

        // Passe 2 : pixels notablement moins saturés que cette moyenne = candidats traînée.
        var isWhite = [Bool](repeating: false, count: cols * rows)
        for i in 0..<(cols * rows) {
            let o = i * 4
            let r = Double(bitmap[o]), g = Double(bitmap[o + 1]), b = Double(bitmap[o + 2])
            let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
            let brightness = maxC / 255.0
            let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
            isWhite[i] = brightness > 0.3 && saturation < saturationThreshold
        }

        // Remplissage par diffusion : regroupe les cellules blanches contiguës (8-connexité) en
        // composantes, retient la plus grande suffisamment allongée.
        var visited = [Bool](repeating: false, count: cols * rows)
        var bestBox: (minCol: Int, maxCol: Int, minRow: Int, maxRow: Int, count: Int)?
        var bestScore = -Double.infinity

        for startIndex in 0..<(cols * rows) where isWhite[startIndex] && !visited[startIndex] {
            var stack = [startIndex]
            visited[startIndex] = true
            var minCol = cols, maxCol = -1, minRow = rows, maxRow = -1, count = 0

            while let index = stack.popLast() {
                let col = index % cols, row = index / cols
                minCol = min(minCol, col); maxCol = max(maxCol, col)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
                count += 1

                for dRow in -1...1 {
                    for dCol in -1...1 {
                        guard dRow != 0 || dCol != 0 else { continue }
                        let neighborCol = col + dCol, neighborRow = row + dRow
                        guard neighborCol >= 0, neighborCol < cols, neighborRow >= 0, neighborRow < rows else { continue }
                        let neighborIndex = neighborRow * cols + neighborCol
                        guard isWhite[neighborIndex], !visited[neighborIndex] else { continue }
                        visited[neighborIndex] = true
                        stack.append(neighborIndex)
                    }
                }
            }

            // Composante trop petite (bruit) ou couvrant presque tout le cadre (ciel couvert, pas
            // une traînée fine) : écartée.
            guard count >= 4, count <= (cols * rows) / 3 else { continue }
            let spanCols = Double(maxCol - minCol + 1), spanRows = Double(maxRow - minRow + 1)
            let elongation = max(spanCols, spanRows) / max(min(spanCols, spanRows), 1)
            guard elongation > 3.0 else { continue }

            // Meilleur candidat de CETTE image, indépendamment des autres images — le regroupement
            // par proximité à travers toute la séquence (voir `detectContrailCandidate`) se charge de
            // distinguer la vraie traînée soutenue d'un éventuel artefact isolé.
            let score = Double(count) * elongation
            if score > bestScore {
                bestScore = score
                bestBox = (minCol, maxCol, minRow, maxRow, count)
            }
        }

        guard let best = bestBox else { return nil }
        // Grille -> repère Vision normalisé (origine bas-gauche) : l'axe des lignes de la grille va
        // du haut vers le bas de l'image, donc on inverse pour Y.
        let x = Double(best.minCol) / Double(cols)
        let width = Double(best.maxCol - best.minCol + 1) / Double(cols)
        let yTop = Double(best.minRow) / Double(rows)
        let height = Double(best.maxRow - best.minRow + 1) / Double(rows)
        let y = 1 - yTop - height
        return CGRect(x: x, y: y, width: width, height: height)
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
            .filter { $0.width * $0.height >= minimumBlobArea && $0.width * $0.height <= maximumBlobArea && isPlausibleObjectShape($0) }
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
            .filter { $0.width * $0.height >= minimumBlobArea && $0.width * $0.height <= maximumBlobArea && isPlausibleObjectShape($0) }
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
