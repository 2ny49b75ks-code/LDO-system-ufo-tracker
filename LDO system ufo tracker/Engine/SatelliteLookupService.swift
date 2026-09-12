// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation

/// Recoupement avec les éphémérides publiques de CelesTrak (celestrak.org, gratuit, sans clé) pour
/// identifier si un satellite connu (ISS, ou l'un des ~100 objets les plus brillants visibles à
/// l'œil nu — voir `visualGroupURL`) se trouvait dans l'axe visé au moment de la captation — voir le
/// plan de pivot du 2026-09-12. Vénus mise à part, l'ISS et les « trains » Starlink fraîchement
/// lancés comptent parmi les causes les plus fréquentes de signalements d'OVNI dans le monde.
///
/// AVERTISSEMENT DE PRÉCISION — À LIRE AVANT DE FAIRE CONFIANCE À CE MODULE :
/// Contrairement au recoupement ADS-B (`AircraftLookupService`, vérifié de bout en bout contre une
/// vraie réponse réseau lors du développement), la propagation orbitale ci-dessous N'A PAS été
/// validée contre une référence externe de confiance (ex. un passage réel de l'ISS confirmé par
/// Heavens-Above ou l'app « Spot the Station » de la NASA). C'est une simplification DÉLIBÉRÉE d'un
/// propagateur SGP4 complet : mouvement képlérien à deux corps + dérive séculaire J2 (nœud ascendant
/// et argument du périgée seulement — PAS de traînée atmosphérique, PAS des harmoniques zonales
/// d'ordre supérieur). Cette simplification introduit une erreur qui croît avec l'âge des éléments
/// orbitaux utilisés (voir `epoch` sur `TLE`) — c'est pourquoi l'appel est soumis à la même limite de
/// fraîcheur que le recoupement ADS-B (voir `AnalysisEngine.maxUsefulLookupAgeHours`). Les tests
/// unitaires (voir `SatelliteLookupServiceTests`) vérifient des propriétés géométriques invariantes
/// (retour à la position de départ après une période orbitale complète, sens de la dérive du nœud
/// ascendant pour une orbite prograde, rayon borné pour une orbite quasi circulaire) plutôt que des
/// chiffres de référence mémorisés dont l'exactitude ne pourrait pas être garantie ici. **Une
/// validation sur un passage réel de l'ISS, sur appareil, reste nécessaire avant de faire pleinement
/// confiance à ce module** — exactement le même principe de prudence déjà appliqué à la convention
/// d'azimut de `TrajectoryCalculator.observedAzimuthElevation`.
enum SatelliteLookupService {

    /// Liste CelesTrak des ~100 objets orbitaux les plus brillants visibles à l'œil nu, activement
    /// tenue à jour par CelesTrak pour cet usage précis (observation amateur) — inclut l'ISS et les
    /// lancements Starlink récents pendant leur brève phase de « train » très brillant. Volontairement
    /// PAS la liste complète de la constellation Starlink (des milliers d'objets, presque tous non
    /// visibles à l'œil nu une fois en orbite opérationnelle) — hors de la portée de ce recoupement.
    private static let visualGroupURL = URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=visual&FORMAT=tle")!

    enum LookupError: Error {
        case networkUnavailable
        case httpError(Int)
        case decodingFailed
    }

    /// Éléments orbitaux à deux lignes (TLE), champs nécessaires à la propagation simplifiée
    /// ci-dessous uniquement (dérivées du mouvement moyen et terme de traînée BSTAR ignorés — voir
    /// l'avertissement en tête de fichier).
    struct TLE {
        let name: String
        let epoch: Date
        let inclinationDegrees: Double
        let raanDegrees: Double
        let eccentricity: Double
        let argPerigeeDegrees: Double
        let meanAnomalyDegrees: Double
        let meanMotionRevPerDay: Double
    }

    // MARK: - Réseau

    static func fetchVisibleSatellitePositions(
        at date: Date,
        observerLatitude: Double,
        observerLongitude: Double,
        urlSession: URLSession = .shared,
        completion: @escaping (Result<[CelestialPositionCalculator.BodyPosition], LookupError>) -> Void
    ) {
        let task = urlSession.dataTask(with: visualGroupURL) { data, response, error in
            if error != nil {
                completion(.failure(.networkUnavailable))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.failure(.httpError(http.statusCode)))
                return
            }
            guard let data, let text = String(data: data, encoding: .utf8) else {
                completion(.failure(.decodingFailed))
                return
            }
            let tles = parseTLEs(from: text)
            let positions = tles.compactMap { tle in
                topocentricPosition(of: tle, at: date, observerLatitude: observerLatitude, observerLongitude: observerLongitude)
            }.filter { $0.elevationDegrees > 0 }
            completion(.success(positions))
        }
        task.resume()
    }

    // MARK: - Analyse du format TLE (deux lignes, colonnes fixes standard NORAD)

    /// `internal` (pas `private`) pour rester testable directement (voir `SatelliteLookupServiceTests`).
    /// Format CelesTrak : groupes de 3 lignes (nom, ligne 1, ligne 2) répétés jusqu'à la fin du fichier.
    static func parseTLEs(from text: String) -> [TLE] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        var tles: [TLE] = []
        var i = 0
        while i + 2 < lines.count {
            let name = lines[i]
            let line1 = lines[i + 1]
            let line2 = lines[i + 2]
            i += 3
            guard line1.hasPrefix("1 "), line2.hasPrefix("2 "), let tle = parseTLE(name: name, line1: line1, line2: line2) else { continue }
            tles.append(tle)
        }
        return tles
    }

    private static func parseTLE(name: String, line1: String, line2: String) -> TLE? {
        let line1Tokens = line1.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let line2Tokens = line2.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // Ligne 1 : [numéroLigne, numéroSatellite+classification, désignateurInternational, époque, ...]
        // Ligne 2 : [numéroLigne, numéroSatellite, inclinaison, RAAN, excentricité, argPérigée,
        //            anomalieMoyenne, mouvementMoyen+numéroRévolution+somme_de_contrôle (SANS espace
        //            séparateur dans le format à colonnes fixes original — voir le commentaire ci-dessous)].
        guard line1Tokens.count >= 4, line2Tokens.count >= 8,
              let epoch = parseEpoch(line1Tokens[3]),
              let inclination = Double(line2Tokens[2]),
              let raan = Double(line2Tokens[3]),
              let eccentricityRaw = Double("0." + line2Tokens[4]),
              let argPerigee = Double(line2Tokens[5]),
              let meanAnomaly = Double(line2Tokens[6])
        else { return nil }

        // Le dernier champ de la ligne 2 concatène SANS espace le mouvement moyen (11 caractères,
        // colonnes 53-63 du format original), le numéro de révolution (5 chiffres) et la somme de
        // contrôle (1 chiffre) — on ne peut pas le séparer par un simple découpage sur les espaces
        // comme les champs précédents. Seuls les 11 premiers caractères (mouvement moyen) sont utiles
        // ici ; numéro de révolution et somme de contrôle ne sont pas nécessaires à la propagation.
        let lastToken = line2Tokens[7]
        guard lastToken.count >= 11, let meanMotion = Double(lastToken.prefix(11)) else { return nil }

        return TLE(
            name: name, epoch: epoch, inclinationDegrees: inclination, raanDegrees: raan,
            eccentricity: eccentricityRaw, argPerigeeDegrees: argPerigee,
            meanAnomalyDegrees: meanAnomaly, meanMotionRevPerDay: meanMotion
        )
    }

    /// Époque TLE au format `AADDD.DDDDDDDD` (AA = 2 derniers chiffres de l'année, DDD.DDDDDDDD =
    /// jour de l'année avec fraction — le jour 1.0 correspond au 1er janvier à 00:00 UTC). Convention
    /// standard NORAD : AA < 57 -> 20AA, AA >= 57 -> 19AA (jamais pertinent en pratique aujourd'hui,
    /// mais gardée pour rester fidèle au standard).
    private static func parseEpoch(_ token: String) -> Date? {
        guard token.count >= 5, let dotIndex = token.firstIndex(of: ".") else { return nil }
        let yearDigits = token[token.startIndex..<token.index(token.startIndex, offsetBy: 2)]
        guard let yy = Int(yearDigits) else { return nil }
        let year = yy < 57 ? 2000 + yy : 1900 + yy
        guard let dayOfYearFraction = Double(token[token.index(token.startIndex, offsetBy: 2)..<token.endIndex]) else { return nil }
        _ = dotIndex

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        guard let jan1 = utcCalendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
        // `dayOfYearFraction` compte le 1er janvier comme jour 1.0 (pas jour 0.0) -> soustraire 1 jour.
        return jan1.addingTimeInterval((dayOfYearFraction - 1) * 86400)
    }

    // MARK: - Propagation simplifiée (deux corps + dérive séculaire J2) et position topocentrique

    private static let earthMu = 398600.4418          // km³/s² (paramètre gravitationnel terrestre)
    private static let earthRadiusKm = 6378.137        // km (rayon équatorial, sphère approximée)
    private static let earthJ2 = 1.08262668E-3         // coefficient d'aplatissement J2 (sans unité)

    /// Position ECI (Earth-Centered Inertial, km) d'un satellite à l'instant `date`, par propagation
    /// képlérienne à deux corps avec dérive séculaire J2 du nœud ascendant et de l'argument du
    /// périgée (voir l'avertissement de précision en tête de fichier — PAS un SGP4 complet).
    /// `internal` pour rester testable (voir `SatelliteLookupServiceTests`).
    static func eciPosition(of tle: TLE, at date: Date) -> (x: Double, y: Double, z: Double)? {
        guard tle.meanMotionRevPerDay > 0 else { return nil }

        let tSeconds = date.timeIntervalSince(tle.epoch)
        let n = tle.meanMotionRevPerDay * 2 * Double.pi / 86400   // rad/s
        let a = cbrt(earthMu / (n * n))                            // km, 3e loi de Kepler
        let e = tle.eccentricity
        let p = a * (1 - e * e)
        let iRad = tle.inclinationDegrees * .pi / 180

        // Dérive séculaire J2 (nœud ascendant et argument du périgée) — formules standard de
        // mécanique orbitale (perturbation du premier ordre due à l'aplatissement terrestre),
        // dominante pour une orbite basse comme l'ISS (~5°/jour de régression du nœud) : ignorer
        // cette dérive rendrait une correspondance directionnelle fausse dès quelques heures après
        // l'époque des éléments orbitaux utilisés.
        let raanDotRadPerSec = -1.5 * n * earthJ2 * pow(earthRadiusKm / p, 2) * cos(iRad)
        let argPerigeeDotRadPerSec = 0.75 * n * earthJ2 * pow(earthRadiusKm / p, 2) * (5 * pow(cos(iRad), 2) - 1)

        let raanRad = (tle.raanDegrees * .pi / 180) + raanDotRadPerSec * tSeconds
        let argPerigeeRad = (tle.argPerigeeDegrees * .pi / 180) + argPerigeeDotRadPerSec * tSeconds
        let meanAnomalyRad = normalizeRadians((tle.meanAnomalyDegrees * .pi / 180) + n * tSeconds)

        // Équation de Kepler M = E - e·sin(E), résolue par Newton-Raphson (converge très rapidement
        // pour les faibles excentricités des orbites visées ici, ISS ≈ 0.0006).
        var eccentricAnomaly = meanAnomalyRad
        for _ in 0..<8 {
            let delta = (eccentricAnomaly - e * sin(eccentricAnomaly) - meanAnomalyRad) / (1 - e * cos(eccentricAnomaly))
            eccentricAnomaly -= delta
        }

        let trueAnomaly = 2 * atan2((1 + e).squareRoot() * sin(eccentricAnomaly / 2), (1 - e).squareRoot() * cos(eccentricAnomaly / 2))
        let radius = a * (1 - e * cos(eccentricAnomaly))

        let xPerifocal = radius * cos(trueAnomaly)
        let yPerifocal = radius * sin(trueAnomaly)

        // Périfocal -> ECI : rotation standard par l'argument du périgée, l'inclinaison, et le nœud
        // ascendant (même transformation 3-1-3 que celle déjà utilisée pour les astres ci-dessus,
        // voir CelestialPositionCalculator.bodyAltAz, appliquée ici aux éléments orbitaux TLE).
        let cosRaan = cos(raanRad), sinRaan = sin(raanRad)
        let cosArgP = cos(argPerigeeRad), sinArgP = sin(argPerigeeRad)
        let cosI = cos(iRad), sinI = sin(iRad)

        let x = (cosRaan * cosArgP - sinRaan * sinArgP * cosI) * xPerifocal
              + (-cosRaan * sinArgP - sinRaan * cosArgP * cosI) * yPerifocal
        let y = (sinRaan * cosArgP + cosRaan * sinArgP * cosI) * xPerifocal
              + (-sinRaan * sinArgP + cosRaan * cosArgP * cosI) * yPerifocal
        let z = (sinArgP * sinI) * xPerifocal + (cosArgP * sinI) * yPerifocal

        return (x, y, z)
    }

    /// Position topocentrique (azimut/élévation depuis l'observateur) d'un satellite, en tenant
    /// compte de la PARALLAXE (contrairement à `CelestialPositionCalculator.equatorialToAltAz`,
    /// géocentrique — valide pour le Soleil/Lune/planètes/étoiles, bien trop loin pour que la
    /// position de l'observateur à la surface de la Terre fasse une différence perceptible, mais
    /// PAS pour un satellite à quelques centaines de km d'altitude, où ignorer la parallaxe fausserait
    /// complètement l'élévation calculée). Altitude de l'observateur approximée à 0 (même choix que
    /// `AircraftLookupService`/`AngularGeometry` — `LocationProvider` ne lit jamais l'altitude GPS).
    static func topocentricPosition(of tle: TLE, at date: Date, observerLatitude: Double, observerLongitude: Double) -> CelestialPositionCalculator.BodyPosition? {
        guard let eci = eciPosition(of: tle, at: date) else { return nil }

        // Rotation ECI -> ECEF par le temps sidéral de Greenwich — réutilise le calcul de temps
        // sidéral déjà existant et déjà éprouvé (CelestialPositionCalculator), avec longitude=0,
        // plutôt que de dupliquer une seconde formule de temps sidéral.
        let gmstRad = CelestialPositionCalculator.localSiderealTimeDegrees(date: date, longitude: 0) * .pi / 180
        let xEcef = eci.x * cos(gmstRad) + eci.y * sin(gmstRad)
        let yEcef = -eci.x * sin(gmstRad) + eci.y * cos(gmstRad)
        let zEcef = eci.z

        let latRad = observerLatitude * .pi / 180
        let lonRad = observerLongitude * .pi / 180
        let xObs = earthRadiusKm * cos(latRad) * cos(lonRad)
        let yObs = earthRadiusKm * cos(latRad) * sin(lonRad)
        let zObs = earthRadiusKm * sin(latRad)

        let dx = xEcef - xObs, dy = yEcef - yObs, dz = zEcef - zObs

        // Vecteur observateur -> satellite, exprimé dans le repère topocentrique horizontal standard
        // Sud-Est-Zénith (SEZ, voir Vallado, "Fundamentals of Astrodynamics and Applications").
        let south = sin(latRad) * cos(lonRad) * dx + sin(latRad) * sin(lonRad) * dy - cos(latRad) * dz
        let east = -sin(lonRad) * dx + cos(lonRad) * dy
        let zenith = cos(latRad) * cos(lonRad) * dx + cos(latRad) * sin(lonRad) * dy + sin(latRad) * dz

        let range = (south * south + east * east + zenith * zenith).squareRoot()
        guard range > 0.001 else { return nil }

        let elevationRad = asin(max(-1, min(1, zenith / range)))
        var azimuthRad = atan2(east, -south)
        if azimuthRad < 0 { azimuthRad += 2 * .pi }

        return CelestialPositionCalculator.BodyPosition(
            name: tle.name,
            azimuthDegrees: azimuthRad * 180 / .pi,
            elevationDegrees: elevationRad * 180 / .pi
        )
    }

    private static func normalizeRadians(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        return a
    }
}
