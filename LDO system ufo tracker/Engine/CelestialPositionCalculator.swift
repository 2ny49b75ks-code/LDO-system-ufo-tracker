// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation

/// Position approximative (azimut/élévation) des astres les plus souvent confondus avec un OVNI —
/// Soleil, Lune, Vénus, Jupiter — calculée à partir de formules orbitales à basse précision
/// (éléments kepleriens standard, référence J2000), ~1° de précision. Largement suffisant pour un
/// contrôle de plausibilité (« cet objet stationnaire est-il dans la même direction que Vénus ? »),
/// PAS pour une éphéméride de précision astronomique.
///
/// Ajouté 2026-08-09, demande explicite de Jean-David : distinguer un vrai OVNI stationnaire d'une
/// étoile/planète brillante (Vénus est la cause n°1 de signalements d'OVNI dans le monde) — voir
/// VerdictCalculator pour comment ce résultat pondère le score.
enum CelestialPositionCalculator {

    struct BodyPosition {
        let name: String
        let azimuthDegrees: Double     // 0° = nord, 90° = est (mesuré vers l'est)
        let elevationDegrees: Double   // 0° = horizon, 90° = zénith
    }

    /// Étoiles fixes standard les plus brillantes (coordonnées J2000, catalogue Hipparcos/Yale Bright
    /// Star, valeurs publiées) — ajoutées 2026-08-09 (demande explicite de Jean-David) en complément
    /// du Soleil/Lune/Vénus/Jupiter : une étoile brillante scintillant près de l'horizon (surtout
    /// Sirius, la plus brillante du ciel nocturne) est une source très fréquente de signalements
    /// d'OVNI, au même titre que Vénus. Contrairement aux planètes, une étoile fixe n'a pas besoin de
    /// calcul orbital : ses coordonnées équatoriales (ascension droite/déclinaison) sont essentiellement
    /// constantes, seule sa position azimut/élévation change avec l'heure (rotation de la Terre) —
    /// voir `equatorialToAltAz`. Polaris (l'étoile polaire, quasi immobile au pôle céleste nord) sert
    /// aussi de repère de calibration pratique : sur appareil réel, filmer Polaris et vérifier que
    /// l'azimut calculé correspond au nord d'une boussole valide la convention -Z=nord utilisée dans
    /// `TrajectoryCalculator.observedAzimuthElevation`.
    private static let brightStars: [(name: String, raDegrees: Double, decDegrees: Double)] = [
        ("Sirius", 101.287, -16.716),
        ("Canopus", 95.988, -52.696),
        ("Arcturus", 213.915, 19.182),
        ("Véga", 279.234, 38.784),
        ("Capella", 79.172, 45.998),
        ("Rigel", 78.634, -8.202),
        ("Procyon", 114.825, 5.225),
        ("Bételgeuse", 88.793, 7.407),
        ("Altaïr", 297.696, 8.868),
        ("Étoile polaire", 37.955, 89.264)
    ]

    /// Calcule la position de chaque astre suivi (Soleil, Lune, Vénus, Jupiter, étoiles fixes
    /// standard), uniquement ceux au-dessus de l'horizon (élévation > 0) — un astre sous l'horizon ne
    /// peut évidemment pas expliquer une observation.
    static func visiblePositions(at date: Date, latitude: Double, longitude: Double) -> [BodyPosition] {
        let d = daysSinceEpoch(date)
        let obliquity = 23.4393 - 3.563E-7 * d

        // Éléments du Soleil — servent aussi à convertir les positions héliocentriques des planètes
        // ci-dessous en positions géocentriques (position géocentrique du Soleil = -position
        // héliocentrique de la Terre).
        let sunW = normalizeDegrees(282.9404 + 4.70935E-5 * d)
        let sunE = 0.016709 - 1.151E-9 * d
        let sunM = normalizeDegrees(356.0470 + 0.9856002585 * d)
        let sunEccAnomaly = eccentricAnomaly(meanAnomalyDegrees: sunM, eccentricity: sunE)
        let (sunXv, sunYv) = orbitalPlanePosition(eccentricAnomalyDegrees: sunEccAnomaly, eccentricity: sunE)
        let sunTrueAnomalyDeg = normalizeDegrees(atan2(sunYv, sunXv) * 180 / .pi)
        let sunDistance = (sunXv * sunXv + sunYv * sunYv).squareRoot()
        let sunEclipticLonRad = (sunTrueAnomalyDeg + sunW) * .pi / 180
        let sunGeoX = sunDistance * cos(sunEclipticLonRad)
        let sunGeoY = sunDistance * sin(sunEclipticLonRad)

        var candidates: [BodyPosition?] = []

        candidates.append(eclipticToAltAz(name: "Soleil", x: sunGeoX, y: sunGeoY, z: 0,
                                           obliquityDegrees: obliquity, date: date, latitude: latitude, longitude: longitude))

        candidates.append(bodyAltAz(name: "Lune", d: d, obliquity: obliquity, date: date, latitude: latitude, longitude: longitude,
                                     N: 125.1228, NRate: -0.0529538083, i: 5.1454, iRate: 0,
                                     w: 318.0634, wRate: 0.1643573223, a: 60.2666, aRate: 0,
                                     e: 0.054900, eRate: 0, M: 115.3654, MRate: 13.0649929509,
                                     geocentric: true, sunGeoX: sunGeoX, sunGeoY: sunGeoY))

        candidates.append(bodyAltAz(name: "Vénus", d: d, obliquity: obliquity, date: date, latitude: latitude, longitude: longitude,
                                     N: 76.6799, NRate: 2.46590E-5, i: 3.3946, iRate: 2.75E-8,
                                     w: 54.8910, wRate: 1.38374E-5, a: 0.723330, aRate: 0,
                                     e: 0.006773, eRate: -1.302E-9, M: 48.0052, MRate: 1.6021302244,
                                     geocentric: false, sunGeoX: sunGeoX, sunGeoY: sunGeoY))

        candidates.append(bodyAltAz(name: "Jupiter", d: d, obliquity: obliquity, date: date, latitude: latitude, longitude: longitude,
                                     N: 100.4542, NRate: 2.76854E-5, i: 1.3030, iRate: -1.557E-7,
                                     w: 273.8777, wRate: 1.64505E-5, a: 5.20256, aRate: 0,
                                     e: 0.048498, eRate: 4.469E-9, M: 19.8950, MRate: 0.0830853001,
                                     geocentric: false, sunGeoX: sunGeoX, sunGeoY: sunGeoY))

        for star in brightStars {
            candidates.append(equatorialToAltAz(name: star.name, raDeg: star.raDegrees, decDeg: star.decDegrees, date: date, latitude: latitude, longitude: longitude))
        }

        return candidates.compactMap { $0 }.filter { $0.elevationDegrees > 0 }
    }

    // MARK: - Position orbitale (éléments kepleriens à basse précision, référence J2000)

    private static func bodyAltAz(
        name: String, d: Double, obliquity: Double, date: Date, latitude: Double, longitude: Double,
        N: Double, NRate: Double, i: Double, iRate: Double, w: Double, wRate: Double,
        a: Double, aRate: Double, e: Double, eRate: Double, M: Double, MRate: Double,
        geocentric: Bool, sunGeoX: Double, sunGeoY: Double
    ) -> BodyPosition? {
        let nDeg = normalizeDegrees(N + NRate * d)
        let iDeg = i + iRate * d
        let wDeg = normalizeDegrees(w + wRate * d)
        let aVal = a + aRate * d
        let eVal = e + eRate * d
        let mDeg = normalizeDegrees(M + MRate * d)

        let eccAnomaly = eccentricAnomaly(meanAnomalyDegrees: mDeg, eccentricity: eVal)
        let (xv, yv) = orbitalPlanePosition(eccentricAnomalyDegrees: eccAnomaly, eccentricity: eVal, semiMajorAxis: aVal)

        // Position dans le plan orbital -> coordonnées écliptiques (rotation par w, i, N).
        let nRad = nDeg * .pi / 180, iRad = iDeg * .pi / 180, wRad = wDeg * .pi / 180
        let xh = (cos(nRad) * cos(wRad) - sin(nRad) * sin(wRad) * cos(iRad)) * xv
               + (-cos(nRad) * sin(wRad) - sin(nRad) * cos(wRad) * cos(iRad)) * yv
        let yh = (sin(nRad) * cos(wRad) + cos(nRad) * sin(wRad) * cos(iRad)) * xv
               + (-sin(nRad) * sin(wRad) + cos(nRad) * cos(wRad) * cos(iRad)) * yv
        let zh = (sin(wRad) * sin(iRad)) * xv + (cos(wRad) * sin(iRad)) * yv

        // Géocentrique : la Lune l'est déjà ; une planète doit être ramenée en ajoutant la position
        // géocentrique du Soleil (= -position héliocentrique de la Terre).
        let geoX = geocentric ? xh : xh + sunGeoX
        let geoY = geocentric ? yh : yh + sunGeoY
        let geoZ = zh

        return eclipticToAltAz(name: name, x: geoX, y: geoY, z: geoZ, obliquityDegrees: obliquity, date: date, latitude: latitude, longitude: longitude)
    }

    /// Résout l'équation de Kepler (M = E - e·sin(E)) par itération de Newton — 6 itérations,
    /// largement suffisant pour converger à une précision négligeable devant les ~1° de précision
    /// globale de ces formules à basse précision.
    private static func eccentricAnomaly(meanAnomalyDegrees M: Double, eccentricity e: Double) -> Double {
        let mRad = M * .pi / 180
        var E = mRad + e * sin(mRad) * (1.0 + e * cos(mRad))
        for _ in 0..<6 {
            let delta = (E - e * sin(E) - mRad) / (1 - e * cos(E))
            E -= delta
        }
        return E * 180 / .pi
    }

    private static func orbitalPlanePosition(eccentricAnomalyDegrees E: Double, eccentricity e: Double, semiMajorAxis a: Double = 1.0) -> (x: Double, y: Double) {
        let eRad = E * .pi / 180
        let xv = a * (cos(eRad) - e)
        let yv = a * ((1 - e * e).squareRoot() * sin(eRad))
        return (xv, yv)
    }

    // MARK: - Écliptique -> horizontal (azimut/élévation pour l'observateur)

    private static func eclipticToAltAz(name: String, x: Double, y: Double, z: Double, obliquityDegrees: Double, date: Date, latitude: Double, longitude: Double) -> BodyPosition? {
        let oblRad = obliquityDegrees * .pi / 180
        // Écliptique -> équatorial (rotation autour de l'axe X par l'obliquité).
        let xEq = x
        let yEq = y * cos(oblRad) - z * sin(oblRad)
        let zEq = y * sin(oblRad) + z * cos(oblRad)

        let raDeg = normalizeDegrees(atan2(yEq, xEq) * 180 / .pi)
        let decDeg = atan2(zEq, (xEq * xEq + yEq * yEq).squareRoot()) * 180 / .pi

        return equatorialToAltAz(name: name, raDeg: raDeg, decDeg: decDeg, date: date, latitude: latitude, longitude: longitude)
    }

    /// Convertit des coordonnées équatoriales (ascension droite/déclinaison, ex. le catalogue
    /// `brightStars` ci-dessus) en azimut/élévation pour l'observateur — étape commune, réutilisée
    /// aussi bien pour les étoiles fixes (coordonnées déjà équatoriales) que pour le Soleil/Lune/
    /// planètes (via `eclipticToAltAz` ci-dessus, qui convertit d'abord écliptique -> équatorial).
    private static func equatorialToAltAz(name: String, raDeg: Double, decDeg: Double, date: Date, latitude: Double, longitude: Double) -> BodyPosition? {
        let lst = localSiderealTimeDegrees(date: date, longitude: longitude)
        let haRad = normalizeDegrees(lst - raDeg) * .pi / 180
        let decRad = decDeg * .pi / 180
        let latRad = latitude * .pi / 180

        let sinAlt = sin(decRad) * sin(latRad) + cos(decRad) * cos(latRad) * cos(haRad)
        let altRad = asin(max(-1, min(1, sinAlt)))
        guard cos(altRad) > 0.0001 else { return BodyPosition(name: name, azimuthDegrees: 0, elevationDegrees: altRad * 180 / .pi) }
        let cosAz = (sin(decRad) - sin(altRad) * sin(latRad)) / (cos(altRad) * cos(latRad))
        var azRad = acos(max(-1, min(1, cosAz)))
        if sin(haRad) > 0 { azRad = 2 * .pi - azRad }

        return BodyPosition(name: name, azimuthDegrees: azRad * 180 / .pi, elevationDegrees: altRad * 180 / .pi)
    }

    private static func localSiderealTimeDegrees(date: Date, longitude: Double) -> Double {
        let d = daysSinceEpoch(date)
        let sunW = normalizeDegrees(282.9404 + 4.70935E-5 * d)
        let sunM = normalizeDegrees(356.0470 + 0.9856002585 * d)
        let sunMeanLongitude = normalizeDegrees(sunW + sunM)
        let gmst0 = normalizeDegrees(sunMeanLongitude + 180)
        let utcHours = utcHoursOfDay(date)
        return normalizeDegrees(gmst0 + utcHours * 15 + longitude)
    }

    /// Jours écoulés depuis l'époque de référence des formules ci-dessus (1999-12-31 00:00 UTC).
    private static func daysSinceEpoch(_ date: Date) -> Double {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let epoch = utcCalendar.date(from: DateComponents(year: 1999, month: 12, day: 31, hour: 0, minute: 0, second: 0))!
        return date.timeIntervalSince(epoch) / 86400.0
    }

    private static func utcHoursOfDay(_ date: Date) -> Double {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let c = utcCalendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
    }

    private static func normalizeDegrees(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }
}
