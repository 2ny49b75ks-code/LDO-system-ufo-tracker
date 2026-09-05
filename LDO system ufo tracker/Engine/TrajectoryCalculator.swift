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
        estimatedDistanceMeters: Double?,
        distanceConfidence: Double = 0
    ) -> TrajectoryResult {
        guard detections.count >= 3 else {
            return TrajectoryResult.insufficientData(points2D: detections.map { center($0.boundingBox) })
        }

        // 1. Pour chaque détection, retrouver la pose caméra la plus proche en temps
        //    et convertir la position 2D (pixels/normalisé) en direction 3D réelle dans le ciel.
        let angularSamples: [AngularSample] = detections.compactMap { detection in
            guard let frame = frames.nearest(to: detection.timestamp),
                  let direction = rayDirection(for: detection.boundingBox, frame: frame)
            else { return nil }
            return AngularSample(direction: direction, timestamp: detection.timestamp)
        }
        guard angularSamples.count >= 3 else {
            return TrajectoryResult.insufficientData(points2D: detections.map { center($0.boundingBox) })
        }

        // 2. Lissage léger (moyenne glissante), utilisé UNIQUEMENT pour le test de linéarité global
        //    (forme d'ensemble de la trajectoire) — surtout pas pour la vitesse ou les virages : une
        //    trajectoire non linéaire (virages brusques, cas typique d'une observation d'OVNI) atteint
        //    précisément ses vitesses/accélérations de pointe PENDANT ces changements de direction, et
        //    une moyenne glissante sur les directions écraserait justement ces pics vers des valeurs
        //    plus basses et plus "lisses" que le déplacement réel.
        let smoothed = smooth(angularSamples, window: smoothingWindow)

        // 3. Test de linéarité : régression sur les directions angulaires successives.
        //    R² proche de 1 => trajectoire rectiligne continue ; sinon => asymétrique.
        let (isLinear, r2) = linearityTest(smoothed)

        // 4. Vitesse angulaire calculée sur les échantillons BRUTS (non lissés), pour préserver les
        //    pics réels de vitesse pendant un virage rapide.
        let angularVelocities = angularVelocity(angularSamples)     // degrés/seconde

        // 5. Détection des changements de direction brusques (virages) par courbure locale — SUR LES
        //    ÉCHANTILLONS LISSÉS (contrairement à la vitesse ci-dessus). Calculé ici (avant
        //    l'estimation des forces G ci-dessous) pour pouvoir ancrer le G final sur un vrai virage
        //    plutôt que sur le bruit image par image.
        //    BUG corrigé (2026-08-26, avion réel minuscule/lointain fourni par Jean-David, tout juste
        //    au-dessus du seuil de détection) : sur les échantillons BRUTS, un objet aussi marginal
        //    produisait un centre qui gigote assez d'une image à l'autre pour franchir le seuil de
        //    30°/3 points de `detectSharpTurns` par pur bruit de seuillage — un avion en vol parfaitement
        //    stable ressortait à ~32 G « impossibles ». Le lissage (même fenêtre que le test de
        //    linéarité) absorbe ce bruit tout en laissant passer un VRAI virage brusque, dont
        //    l'amplitude reste largement au-dessus du seuil même après une moyenne glissante sur 3
        //    points — contrairement au bruit de gigotement, dont l'amplitude est du même ordre que la
        //    fenêtre de lissage elle-même.
        let curvatureEvents = detectSharpTurns(smoothed, distanceMeters: estimatedDistanceMeters, distanceConfidence: distanceConfidence)

        // 6. Estimation des forces G — ANCRÉE SUR LES VIRAGES RÉELLEMENT DÉTECTÉS (`curvatureEvents`
        //    ci-dessus, seuil >30° sur une fenêtre de 3 échantillons), PAS sur le pic brut de la double
        //    dérivée image par image (`maxAngularAcceleration`, voir `robustPeak`).
        //    BUG corrigé (2026-08-25, signalé par Jean-David sur un avion de ligne réel, vitesse
        //    mesurée cohérente à 539 km/h) : un avion volant en ligne droite affichait ~78,5 G. Cause :
        //    la double dérivée image par image reste bruitée même après corroboration par paire (le
        //    filtre `robustPeak` ne suffit pas — des échantillons consécutifs d'une dérivée seconde
        //    partagent un terme commun, donc le bruit s'y corrèle). Multiplié par une distance estimée
        //    de plusieurs kilomètres, un bruit angulaire infime devient des centaines de m/s² fictifs.
        //    Un virage confirmé par `detectSharpTurns` (>30° sur 3 points, un vrai signal géométrique,
        //    pas une simple dérivée seconde) est une mesure bien plus robuste. Sans virage confirmé, le
        //    vol est essentiellement stable : on retombe sur 1 G (charge de vol en palier), la valeur
        //    physiquement correcte — pas sur un chiffre dérivé du bruit de suivi.
        let gResult: (value: Double, confidence: Double)
        if let strongestTurn = curvatureEvents.max(by: { $0.estimatedGForce < $1.estimatedGForce }) {
            gResult = (strongestTurn.estimatedGForce, strongestTurn.gForceConfidence)
        } else if let distance = estimatedDistanceMeters, distance > 0 {
            gResult = (1.0, distanceConfidence)   // aucun virage brusque confirmé : vol en palier, charge ≈ 1 G.
        } else {
            gResult = (0, 0)       // pas de distance fiable : on ne prétend aucune valeur en G.
        }

        // 7. Points 2D (pixels) pour le tracé rouge sur la vidéo/les photos.
        let points2D = detections.map { center($0.boundingBox) }

        // 8. Motif en zigzag gauche-droite : un avion, un drone ou un satellite suit une trajectoire
        //    linéaire ou une courbe continue dans UNE seule direction ; des changements de sens
        //    répétés (gauche-droite-gauche...) ne correspondent à aucun comportement de vol connu.
        //    BUG corrigé (2026-08-08, signalé par Jean-David sur un avion réel filmé en zoomant à la
        //    main) : ceci tournait auparavant sur `points2D`, la position brute À L'ÉCRAN — non
        //    corrigée du mouvement de caméra, contrairement au test de linéarité ci-dessus. Un simple
        //    tremblement de main en suivant l'avion au zoom suffisait à produire de faux "changements
        //    de direction" (zigzag=vrai) alors que la trajectoire réelle dans le ciel était une ligne
        //    quasi parfaite (R² 0.97) — les deux résultats se contredisaient dans l'écran de résultats.
        //    Utilise maintenant la même projection angulaire réelle (corrigée de la pose caméra) que
        //    la linéarité — et, comme `curvatureEvents` ci-dessus (bug du 2026-08-26), sur les
        //    échantillons LISSÉS plutôt que bruts : un objet minuscule/lointain proche du seuil de
        //    détection produit assez de gigotement de centre pour ressortir comme un faux zigzag à
        //    répétition, alors qu'un vrai zigzag brusque reste largement au-dessus du seuil même après
        //    un lissage sur 3 points.
        let zigzag = detectZigzagPattern(smoothed)

        return TrajectoryResult(
            points2D: points2D,
            isLinear: isLinear,
            linearityR2: r2,
            angularVelocitiesDegPerS: angularVelocities,
            estimatedGForce: gResult.value,
            gForceConfidence: gResult.confidence,
            exceedsHumanTolerance: gResult.value > humanToleranceG && gResult.confidence > 0.3,
            curvatureEvents: curvatureEvents,
            isZigzagPattern: zigzag.isZigzag,
            directionReversalCount: zigzag.reversalCount
        )
    }

    // MARK: - 1. Conversion pixel -> rayon 3D réel

    /// Convertit une boîte englobante (repère Vision, normalisé, origine bas-gauche) en une direction
    /// unitaire, en tenant compte de la focale (intrinsics) et, quand elle est disponible, de
    /// l'orientation de la caméra au moment exact de la détection (cameraTransform).
    ///
    /// BUG CORRIGÉ (2026-08-26, vidéo réelle fournie par Jean-David, importée depuis la bibliothèque) :
    /// cette fonction retournait `nil` dès que `cameraTransform` OU `intrinsics` manquait — CE QUI EST
    /// TOUJOURS LE CAS pour une vidéo importée (jamais filmée par LDO, aucune métadonnée de pose
    /// ARKit) — bloquant purement et simplement TOUT calcul de trajectoire/vitesse/G pour ce cas
    /// d'usage pourtant courant (« analyser une vidéo que j'ai déjà »), pas seulement pour un
    /// enregistrement LIVE ré-analysé. Fallbacks ajoutés :
    ///  - `intrinsics` manquantes : focale estimée par un champ de vision horizontal typique de
    ///    caméra arrière de smartphone (~60°), même hypothèse que `DistanceEstimator`.
    ///  - `cameraTransform` manquant : la direction en repère CAMÉRA (avant rotation vers le monde)
    ///    est utilisée directement, ce qui revient à supposer que la caméra ne bouge pas pendant le
    ///    court extrait analysé. Approximation raisonnable pour un plan tenu relativement immobile
    ///    (cas courant d'une observation où on lève le téléphone sans bouger) — mais elle NE corrige
    ///    PAS un panoramique/tremblement de main comme le ferait la vraie pose ARKit : un mouvement de
    ///    caméra non corrigé se traduirait alors par une vitesse angulaire faussée. Ce n'est pas
    ///    dissimulé : la confiance finale sur la distance (voir `DistanceEstimator`, toujours ≤ 0.3)
    ///    plafonne déjà la confiance affichée sur la vitesse/les forces G qui en dérivent, quelle que
    ///    soit la précision de CETTE étape-ci.
    private func rayDirection(for box: CGRect, frame: CapturedFrame) -> SIMD3<Double>? {
        let imageWidth = Double(frame.image.width)
        let imageHeight = Double(frame.image.height)

        let centerNorm = CGPoint(x: box.midX, y: box.midY)
        let pixelX = Double(centerNorm.x) * imageWidth
        let pixelY = (1.0 - Double(centerNorm.y)) * imageHeight   // Vision (bas-gauche) -> image (haut-gauche)

        let fx: Double, fy: Double, cx: Double, cy: Double
        if let intrinsics = frame.intrinsics {
            fx = Double(intrinsics.columns.0.x)
            fy = Double(intrinsics.columns.1.y)
            cx = Double(intrinsics.columns.2.x)
            cy = Double(intrinsics.columns.2.y)
        } else {
            let assumedHorizontalFOVRadians = 60.0 * Double.pi / 180
            fx = imageWidth / (2 * tan(assumedHorizontalFOVRadians / 2))
            fy = fx
            cx = imageWidth / 2
            cy = imageHeight / 2
        }

        // Direction dans le repère caméra LOCAL D'ARKIT : X à droite, Y VERS LE HAUT, l'avant de la
        // caméra pointe vers -Z (convention ARKit standard, confirmée par Apple et déjà utilisée
        // correctement dans `DistanceEstimator.altitudeFromDistance`, qui calcule sa propre direction
        // « avant » via `-cameraTransform.columns.2`).
        //
        // BUG CORRIGÉ (revue de code du 2026-08-27) : ce calcul utilisait auparavant `pixelY` tel
        // quel (repère image, Y VERS LE BAS) et Z=+1 comme « avant » — une convention vision par
        // ordinateur cohérente EN ELLE-MÊME, mais INCOMPATIBLE avec la matrice de rotation d'ARKit
        // utilisée juste en dessous (`rotation * normalizedCameraSpace`), qui suppose Y vers le haut
        // et -Z vers l'avant. Résultat : une direction inversée par rapport à celle réellement visée
        // par la caméra dès que `cameraTransform` est disponible (tout enregistrement LIVE) — corrompt
        // silencieusement la correspondance astronomique (Vénus/Soleil/étoiles) et toute compensation
        // du mouvement de caméra pendant un panoramique. Y inversé (image Y-bas -> caméra Y-haut) et
        // Z=-1 (avant réel d'ARKit) pour retrouver la convention réellement utilisée par la rotation.
        let cameraSpace = SIMD3<Double>((pixelX - cx) / fx, -(pixelY - cy) / fy, -1.0)
        let normalizedCameraSpace = simd_normalize(cameraSpace)

        guard let cameraTransform = frame.cameraTransform else {
            // Pas de pose ARKit : repère caméra utilisé tel quel (suppose une caméra immobile — voir
            // le commentaire ci-dessus).
            return normalizedCameraSpace
        }

        // Rotation caméra -> monde, extraite de la pose ARKit à cet instant.
        let rotation = simd_double3x3(
            SIMD3<Double>(Double(cameraTransform.columns.0.x), Double(cameraTransform.columns.0.y), Double(cameraTransform.columns.0.z)),
            SIMD3<Double>(Double(cameraTransform.columns.1.x), Double(cameraTransform.columns.1.y), Double(cameraTransform.columns.1.z)),
            SIMD3<Double>(Double(cameraTransform.columns.2.x), Double(cameraTransform.columns.2.y), Double(cameraTransform.columns.2.z))
        )
        return simd_normalize(rotation * normalizedCameraSpace)
    }

    /// Azimut/élévation réels (degrés) d'un échantillon représentatif de la séquence — utilisé pour
    /// comparer la direction observée de l'objet à la position calculée d'un astre connu (voir
    /// `CelestialPositionCalculator`/`VerdictCalculator`). Repose sur la boussole d'ARKit
    /// (`.gravityAndHeading`, voir `CaptureManager.configureARTracking`) : sans elle (vidéo importée
    /// de la bibliothèque, ou pose ARKit absente), ce résultat n'a pas de sens et retourne `nil`.
    ///
    /// CONVENTION NON VÉRIFIÉE SUR APPAREIL (2026-08-09) : la documentation Apple pour
    /// `.gravityAndHeading` confirme que l'axe Z est aligné sur la boussole, mais ne précise pas
    /// explicitement si -Z ou +Z pointe vers le nord vrai (un fil de discussion sur les forums Apple
    /// développeurs documente même des cas où le cap ARKit ne correspond pas exactement au cap
    /// physique réel de l'appareil). Convention choisie ici : -Z = nord, +X = est — la plus commune
    /// dans les implémentations publiques ARKit+boussole trouvées. À VÉRIFIER sur appareil réel avec
    /// une boussole avant de faire confiance aux résultats — si les directions sortent inversées ou
    /// décalées de 180°, inverser le signe de `direction.z` ci-dessous suffit à corriger.
    func observedAzimuthElevation(detections: [Detection], frames: [CapturedFrame]) -> (azimuthDegrees: Double, elevationDegrees: Double)? {
        guard !detections.isEmpty else { return nil }
        let midDetection = detections[detections.count / 2]
        guard let frame = frames.nearest(to: midDetection.timestamp),
              let direction = rayDirection(for: midDetection.boundingBox, frame: frame)
        else { return nil }

        let azimuthDeg = atan2(direction.x, -direction.z) * 180 / .pi
        let normalizedAzimuth = azimuthDeg < 0 ? azimuthDeg + 360 : azimuthDeg
        let elevationDeg = asin(max(-1, min(1, direction.y))) * 180 / .pi
        return (normalizedAzimuth, elevationDeg)
    }

    // MARK: - 2. Lissage

    private func smooth(_ samples: [AngularSample], window: Int) -> [AngularSample] {
        centeredMovingAverage(samples, window: window) { i, slice in
            let avgDir = simd_normalize(slice.reduce(SIMD3<Double>(0, 0, 0)) { $0 + $1.direction } / Double(slice.count))
            return AngularSample(direction: avgDir, timestamp: samples[i].timestamp)
        }
    }

    // MARK: - 3. Linéarité

    /// Ajuste les directions successives à une trajectoire angulaire rectiligne et retourne le R²
    /// (1.0 = parfaitement rectiligne, proche de 0 = trajectoire très irrégulière).
    private func linearityTest(_ samples: [AngularSample]) -> (isLinear: Bool, r2: Double) {
        guard samples.count >= 3 else { return (true, 1.0) }

        let start = samples.first!.direction
        let end = samples.last!.direction
        // BUG CORRIGÉ (revue de code du 2026-08-27) : l'égalité EXACTE `== SIMD3(0,0,0)` ne détectait
        // que le cas bit-à-bit identique, pas un déplacement net minuscule mais non nul — précisément
        // le cas d'un objet quasi stationnaire/oscillant (un des scénarios que LDO doit distinguer
        // avec soin). `simd_normalize` sur ce vecteur minuscule amplifie alors le bruit de détection en
        // un axe de référence essentiellement arbitraire, rendant le R² de linéarité affiché instable
        // pour ce cas précis. Seuil `< epsilon` plutôt qu'une égalité exacte.
        let displacementMagnitude = simd_length(end - start)
        let axis = simd_normalize(displacementMagnitude < 1e-4 ? SIMD3<Double>(1,0,0) : end - start)

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
        // Seuil assoupli de 0.97 à 0.85 (2026-08-25, signalé par Jean-David sur un avion de ligne
        // réel filmé à main levée, R² = 0.91) : 0.97 exigeait une trajectoire quasiment parfaite,
        // plus stricte que ce qu'un suivi à main levée peut produire même pour un vol parfaitement
        // droit — le moindre tremblement de main faisait basculer un avion en vol rectiligne vers
        // "trajectoire asymétrique / changements brusques", contredisant le reste de l'analyse
        // (vitesse cohérente avec un avion de ligne, aucun virage brusque réellement détecté).
        return (r2 > 0.85, r2)
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

    private func angleBetween(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let dot = max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b))))
        return acos(dot)
    }

    // MARK: - 5. Virages brusques

    private func detectSharpTurns(_ samples: [AngularSample], distanceMeters: Double?, distanceConfidence: Double) -> [CurvatureEvent] {
        guard samples.count >= 3 else { return [] }

        let strideCount = robustStrideCount(forTimestamps: samples.map { $0.timestamp })
        guard samples.count > 2 * strideCount else { return [] }

        var events: [CurvatureEvent] = []
        for i in strideCount..<(samples.count - strideCount) {
            let v1 = samples[i].direction - samples[i - strideCount].direction
            let v2 = samples[i + strideCount].direction - samples[i].direction
            guard simd_length(v1) > 0.0001, simd_length(v2) > 0.0001 else { continue }
            let turnAngleRad = angleBetween(v1, v2)
            let turnAngleDeg = turnAngleRad * 180 / .pi

            // Un virage "brusque" : plus de 30° de changement de direction entre deux segments,
            // mesurés sur la base élargie ci-dessus (pas un simple pas d'une image à l'autre).
            guard turnAngleDeg > 30 else { continue }

            let dt1 = samples[i].timestamp - samples[i - strideCount].timestamp
            let dt2 = samples[i + strideCount].timestamp - samples[i].timestamp
            let dt = dt1 + dt2
            guard dt1 > 0, dt2 > 0 else { continue }

            // Vitesse angulaire de la LIGNE DE VISÉE (rad/s, pas le taux de virage ci-dessous) sur
            // chaque moitié de fenêtre — sert à reconstituer une vitesse tangentielle réelle dans
            // `estimateGForce` (voir son commentaire). `simd_length(v1)`/`v2` est la longueur de corde
            // entre deux directions UNITAIRES, une bonne approximation de l'angle en radians balayé
            // sur ce court intervalle pour un petit angle.
            let lineOfSightAngularVelocityRadPerS = (simd_length(v1) / dt1 + simd_length(v2) / dt2) / 2
            let turnRateRadPerS = turnAngleRad / dt   // taux de changement de cap, PAS une accélération.

            let gEstimate = estimateGForce(
                lineOfSightAngularVelocityRadPerS: lineOfSightAngularVelocityRadPerS,
                turnRateRadPerS: turnRateRadPerS,
                distanceMeters: distanceMeters,
                distanceConfidence: distanceConfidence
            )

            events.append(CurvatureEvent(
                timestamp: samples[i].timestamp,
                turnAngleDegrees: turnAngleDeg,
                estimatedGForce: gEstimate.value,
                gForceConfidence: gEstimate.confidence
            ))
        }
        return events
    }

    // MARK: - 6. Estimation des forces G

    /// BUG CORRIGÉ (revue de code du 2026-08-27) : l'ancienne formule recevait le TAUX DE VIRAGE
    /// (`turnAngleDeg / dt`, une vitesse angulaire, deg/s) directement dans un paramètre nommé
    /// « accélération angulaire » (deg/s²) et le multipliait par la distance comme si c'était rad/s² —
    /// un mélange d'unités qui calculait en réalité une VITESSE (distance × rad/s = m/s), affichée à
    /// tort comme une accélération (m/s²). Pouvait reproduire le même genre de G fantaisistes que les
    /// bugs déjà corrigés (78,5 G, 13 600 G), via une cause différente, jusqu'ici non détectée.
    ///
    /// Formule corrigée : accélération latérale (m/s²) = distance (m) × vitesse angulaire de la ligne
    /// de visée (rad/s) × taux de virage (rad/s). Dérivation : pour un déplacement perpendiculaire à
    /// la ligne de visée, la vitesse réelle tangentielle v ≈ distance × vitesse_angulaire_ligne_de_visée
    /// (même relation que celle utilisée par `SpeedCalculator` pour estimer la vitesse à partir de la
    /// distance) ; l'accélération centripète pendant un virage est alors a = v × taux_de_virage —
    /// dimensionnellement [m]×[rad/s]×[rad/s] = [m/s²], contrairement à l'ancienne formule.
    private func estimateGForce(
        lineOfSightAngularVelocityRadPerS: Double,
        turnRateRadPerS: Double,
        distanceMeters: Double?,
        distanceConfidence: Double
    ) -> (value: Double, confidence: Double) {
        guard let distance = distanceMeters, distance > 0 else {
            // Sans distance fiable, on ne calcule PAS de valeur en G : la convertir sans distance
            // donnerait un chiffre pseudo-précis mais physiquement arbitraire.
            return (0, 0)
        }
        let lateralAcceleration = distance * lineOfSightAngularVelocityRadPerS * turnRateRadPerS
        let lateralG = lateralAcceleration / 9.81

        // Charge totale en G (facteur de charge, « load factor » en aéronautique) — PAS seulement la
        // composante latérale du virage. En vol rectiligne stable, un aéronef supporte déjà 1 G (la
        // portance équilibre la gravité) ; seul un VIRAGE l'augmente au-delà de 1. Formule standard :
        // n = √(1 + (a_latérale / g)²) — vaut exactement 1 G en ligne droite (a_latérale = 0) et croît
        // avec la sévérité du virage. Calibrage corrigé (2026-08-09, signalé par Jean-David) :
        // l'ancienne formule affichait directement a_latérale/g comme « la » force G — proche de 0 G
        // en vol rectiligne au lieu du 1 G physiquement attendu — et, combinée au bruit de détection
        // non filtré (voir `robustPeak`), pouvait produire des pics physiquement absurdes (427,9 G)
        // sur un avion volant pourtant presque parfaitement droit.
        let totalG = (lateralG * lateralG + 1).squareRoot()

        // Confiance : directement liée à la confiance RÉELLE de l'estimation de distance (fournie par
        // l'étape 8, `DistanceEstimator`). BUG CORRIGÉ (revue de code du 2026-08-27) : ce commentaire
        // était déjà présent mais faux dans les faits — la confiance était codée en dur à 0,35 sans
        // jamais lire la vraie valeur, rendant le seuil `confidence > 0.3` de `exceedsHumanTolerance`
        // incapable de distinguer une distance bien recoupée d'une distance que le recoupement
        // vitesse/taille avait lui-même signalée comme peu fiable.
        return (totalG, distanceConfidence)
    }

    private func center(_ box: CGRect) -> CGPoint {
        CGPoint(x: box.midX, y: box.midY)
    }

    /// Projette chaque direction 3D réelle (corrigée de la pose caméra) en un point 2D
    /// (azimut, élévation, en radians) — sert d'équivalent à `points2D` mais dans le repère du ciel
    /// plutôt qu'à l'écran, pour que `detectZigzagPattern` ne confonde plus un tremblement de main
    /// avec un vrai changement de direction de l'objet (voir le commentaire au point d'appel).
    private func angularScreenProjection(_ samples: [AngularSample]) -> [CGPoint] {
        samples.map { sample in
            let d = sample.direction
            let azimuth = atan2(d.x, d.z)
            let elevation = asin(max(-1, min(1, d.y)))
            return CGPoint(x: azimuth, y: elevation)
        }
    }

    // MARK: - 8. Motif en zigzag

    /// Détecte une alternance de sens de virage (gauche-droite-gauche...) sur la trajectoire écran —
    /// le signal caractéristique décrit pour une observation d'OVNI, distinct d'une simple trajectoire
    /// irrégulière (déjà couverte par le R² de linéarité) : ici on regarde spécifiquement si les
    /// virages successifs CHANGENT DE SENS, plutôt que de courber continuellement dans une seule
    /// direction (ce que ferait un avion, un drone ou un satellite en virage).
    private func detectZigzagPattern(_ samples: [AngularSample]) -> (isZigzag: Bool, reversalCount: Int) {
        let points = angularScreenProjection(samples)
        guard points.count >= 4 else { return (false, 0) }

        // Seuil minimal pour qu'un changement de direction compte comme un vrai "virage" et non
        // du bruit de détection pixel par pixel.
        let minTurnDegrees: Double = 12

        // Base de comparaison élargie (~0.25s), PAS un simple pas d'une image à l'autre — même bug
        // et même correctif que `detectSharpTurns` ci-dessus (voir son commentaire pour le détail
        // complet). BUG corrigé (2026-08-25, découvert par un test de bout en bout via une vraie
        // vidéo synthétique passée dans le vrai pipeline Vision de l'app, PAS seulement un harnais
        // numérique) : un objet se déplaçant en ligne parfaitement droite dans cette vidéo de test
        // (avion de ligne simulé) déclenchait encore un "zigzag" à 2 changements de direction — le
        // bruit de suivi réel produit par le détecteur Vision d'image en image suffisait à franchir
        // le seuil de 12° d'une comparaison trop rapprochée, malgré une trajectoire globale mesurée
        // à R² = 0.97 (quasi rectiligne).
        let strideCount = robustStrideCount(forTimestamps: samples.map { $0.timestamp })
        guard points.count > 2 * strideCount else { return (false, 0) }

        var signs: [Int] = []
        for i in stride(from: strideCount, to: points.count - strideCount, by: 1) {
            let v1 = CGVector(dx: points[i].x - points[i - strideCount].x, dy: points[i].y - points[i - strideCount].y)
            let v2 = CGVector(dx: points[i + strideCount].x - points[i].x, dy: points[i + strideCount].y - points[i].y)
            let len1 = (v1.dx * v1.dx + v1.dy * v1.dy).squareRoot()
            let len2 = (v2.dx * v2.dx + v2.dy * v2.dy).squareRoot()
            guard len1 > 0.0001, len2 > 0.0001 else { continue }

            let cross = v1.dx * v2.dy - v1.dy * v2.dx
            let dot = v1.dx * v2.dx + v1.dy * v2.dy
            let turnDegrees = atan2(cross, dot) * 180 / .pi
            guard abs(turnDegrees) >= minTurnDegrees else { continue }

            signs.append(turnDegrees > 0 ? 1 : -1)
        }
        guard signs.count >= 3 else { return (false, 0) }

        var reversals = 0
        for i in 1..<signs.count where signs[i] != signs[i - 1] {
            reversals += 1
        }

        // Au moins 2 changements de sens successifs (gauche-droite-gauche) : motif zigzag typique.
        return (reversals >= 2, reversals)
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
    let gForceConfidence: Double
}

struct TrajectoryResult {
    var points2D: [CGPoint]
    var isLinear: Bool = true
    var linearityR2: Double = 1.0
    var angularVelocitiesDegPerS: [TimedValue] = []   // série chronologique, réutilisée pour le calcul de vitesse en km/h
    var estimatedGForce: Double = 0
    var gForceConfidence: Double = 0
    var exceedsHumanTolerance: Bool = false
    var curvatureEvents: [CurvatureEvent] = []
    var isZigzagPattern: Bool = false        // alternance gauche-droite typique d'une observation d'OVNI
    var directionReversalCount: Int = 0

    static func insufficientData(points2D: [CGPoint]) -> TrajectoryResult {
        TrajectoryResult(points2D: points2D, isLinear: true, linearityR2: 0, angularVelocitiesDegPerS: [], estimatedGForce: 0, gForceConfidence: 0, exceedsHumanTolerance: false, curvatureEvents: [], isZigzagPattern: false, directionReversalCount: 0)
    }
}
