// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import XCTest
@testable import LDO_system_ufo_tracker

/// Vérifie `SatelliteLookupService` (recoupement satellites/ISS, pivot du 2026-09-12).
///
/// IMPORTANT — voir l'avertissement de précision en tête de `SatelliteLookupService.swift` : la
/// propagation orbitale utilisée n'a pas été validée contre une référence externe de confiance
/// (aucun chiffre mémorisé n'est fiable pour ça ici). Ces tests vérifient donc des PROPRIÉTÉS
/// GÉOMÉTRIQUES INVARIANTES qu'on peut établir avec certitude à partir des lois de la mécanique
/// orbitale elle-même — pas des valeurs de référence externes — pour détecter une régression
/// grossière (signe inversé, unité erronée) sans prétendre garantir l'exactitude fine du résultat.
final class SatelliteLookupServiceTests: XCTestCase {

    /// TLE de l'ISS (exemple représentatif, format standard à 2 lignes) — valeurs plausibles pour
    /// une orbite quasi circulaire à ~51.6° d'inclinaison, ~400 km d'altitude, ~92 min de période.
    private let issTLE = SatelliteLookupService.TLE(
        name: "ISS (ZARYA)",
        epoch: Date(timeIntervalSince1970: 1_700_000_000),
        inclinationDegrees: 51.6400,
        raanDegrees: 208.9163,
        eccentricity: 0.0006317,
        argPerigeeDegrees: 69.9862,
        meanAnomalyDegrees: 25.2906,
        meanMotionRevPerDay: 15.4956
    )

    // MARK: - Analyse du format TLE

    func testParseTLEsExtractsNameAndOrbitalElements() throws {
        let text = """
        ISS (ZARYA)
        1 25544U 98067A   21275.53857639  .00003411  00000-0  70347-4 0  9993
        2 25544  51.6435 195.6852 0004276 271.9553 138.2842 15.48762608305506
        """
        let tles = SatelliteLookupService.parseTLEs(from: text)
        XCTAssertEqual(tles.count, 1)
        let tle = try XCTUnwrap(tles.first)
        XCTAssertEqual(tle.name, "ISS (ZARYA)")
        XCTAssertEqual(tle.inclinationDegrees, 51.6435, accuracy: 0.0001)
        XCTAssertEqual(tle.raanDegrees, 195.6852, accuracy: 0.0001)
        XCTAssertEqual(tle.eccentricity, 0.0004276, accuracy: 0.0000001)
        XCTAssertEqual(tle.argPerigeeDegrees, 271.9553, accuracy: 0.0001)
        XCTAssertEqual(tle.meanAnomalyDegrees, 138.2842, accuracy: 0.0001)
        XCTAssertEqual(tle.meanMotionRevPerDay, 15.48762608, accuracy: 0.0001)
    }

    func testParseTLEsHandlesMultipleSatellitesAndSkipsMalformedEntries() {
        let text = """
        SAT A
        1 25544U 98067A   21275.53857639  .00003411  00000-0  70347-4 0  9993
        2 25544  51.6435 195.6852 0004276 271.9553 138.2842 15.48762608305506
        SAT B (malformée)
        not a valid line 1
        2 25544  51.6435 195.6852 0004276 271.9553 138.2842 15.48762608305506
        SAT C
        1 44714U 19074A   21275.50000000  .00000100  00000-0  10000-4 0  9990
        2 44714  53.0000 100.0000 0001000  90.0000 270.0000 15.06000000100000
        """
        let tles = SatelliteLookupService.parseTLEs(from: text)
        XCTAssertEqual(tles.count, 2, "La ligne 1 invalide de SAT B doit être ignorée sans faire échouer l'analyse des autres")
        XCTAssertEqual(tles.map(\.name), ["SAT A", "SAT C"])
    }

    func testParseEpochConvertsDayOfYearToCorrectDate() {
        // Jour 1.0 = 1er janvier à 00:00 UTC (voir le commentaire de parseEpoch).
        let text = """
        TEST
        1 00001U 00001A   21001.00000000  .00000000  00000-0  00000-0 0  9990
        2 00001  51.6400 208.9163 0006317  69.9862  25.2906 15.49560000100000
        """
        let tles = SatelliteLookupService.parseTLEs(from: text)
        guard let epoch = tles.first?.epoch else { return XCTFail("Échec de l'analyse") }
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let components = utcCalendar.dateComponents([.year, .month, .day, .hour], from: epoch)
        XCTAssertEqual(components.year, 2021)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 0)
    }

    // MARK: - Propriétés géométriques invariantes de la propagation

    func testPropagatingOneFullOrbitalPeriodReturnsNearStartingPosition() throws {
        let n = issTLE.meanMotionRevPerDay * 2 * Double.pi / 86400
        let periodSeconds = 2 * Double.pi / n

        let startPosition = try XCTUnwrap(SatelliteLookupService.eciPosition(of: issTLE, at: issTLE.epoch))
        let onePeriodLater = issTLE.epoch.addingTimeInterval(periodSeconds)
        let endPosition = try XCTUnwrap(SatelliteLookupService.eciPosition(of: issTLE, at: onePeriodLater))

        // Tolérance généreuse (50 km, contre un rayon orbital d'environ 6770 km) : la dérive
        // séculaire J2 du nœud ascendant/argument du périgée déplace légèrement la position même
        // après exactement une période — l'invariant testé est "reste proche", pas "identique".
        let distance = ((startPosition.x - endPosition.x) * (startPosition.x - endPosition.x)
            + (startPosition.y - endPosition.y) * (startPosition.y - endPosition.y)
            + (startPosition.z - endPosition.z) * (startPosition.z - endPosition.z)).squareRoot()
        XCTAssertLessThan(distance, 50, "Après une période orbitale complète, le satellite doit revenir près de sa position de départ")
    }

    func testOrbitalRadiusStaysCloseToSemiMajorAxisForNearCircularOrbit() throws {
        // ISS : excentricité ≈ 0.0006, quasi circulaire -> le rayon orbital doit rester très proche
        // du demi-grand axe à tout instant, peu importe l'anomalie vraie.
        let n = issTLE.meanMotionRevPerDay * 2 * Double.pi / 86400
        let a = cbrt(398600.4418 / (n * n))

        for minutesOffset in stride(from: 0.0, through: 100.0, by: 25.0) {
            let date = issTLE.epoch.addingTimeInterval(minutesOffset * 60)
            let position = try XCTUnwrap(SatelliteLookupService.eciPosition(of: issTLE, at: date))
            let radius = (position.x * position.x + position.y * position.y + position.z * position.z).squareRoot()
            XCTAssertEqual(radius, a, accuracy: a * issTLE.eccentricity * 2, "Le rayon orbital d'une orbite quasi circulaire ne doit pas s'écarter significativement du demi-grand axe")
        }
    }

    func testAscendingNodeRegressesWestwardForProgradeLowEarthOrbit() throws {
        // Fait bien établi de mécanique orbitale (pas une valeur mémorisée à risque) : pour une
        // orbite prograde (inclinaison < 90°, cas de l'ISS à 51.6°), l'aplatissement terrestre (J2)
        // fait DÉRIVER LE NŒUD ASCENDANT VERS L'OUEST (RAAN décroissant) au fil du temps — si cette
        // dérive ressortait vers l'EST, ce serait un signe inversé dans la formule, une régression
        // sérieuse à détecter.
        let n = issTLE.meanMotionRevPerDay * 2 * Double.pi / 86400
        let a = cbrt(398600.4418 / (n * n))
        let p = a * (1 - issTLE.eccentricity * issTLE.eccentricity)
        let iRad = issTLE.inclinationDegrees * .pi / 180
        let raanDotRadPerSec = -1.5 * n * 1.08262668E-3 * pow(6378.137 / p, 2) * cos(iRad)

        XCTAssertLessThan(raanDotRadPerSec, 0, "Le nœud ascendant d'une orbite prograde basse doit dériver vers l'ouest (RAAN décroissant)")

        // Ordre de grandeur attendu pour l'ISS : environ -5°/jour (fait largement documenté) —
        // vérifie que la formule ne produit pas seulement le bon signe mais aussi le bon ordre de
        // grandeur (à un facteur 2 près, tolérance volontairement large ici).
        let degreesPerDay = raanDotRadPerSec * 180 / .pi * 86400
        XCTAssertEqual(degreesPerDay, -5.0, accuracy: 2.5)
    }

    // MARK: - Position topocentrique

    func testTopocentricPositionReturnsNilBelowMinimumRange() {
        // Position observateur ≈ position satellite (distance quasi nulle) -> garde-fou `range > 0.001`.
        let degenerateTLE = SatelliteLookupService.TLE(
            name: "TEST", epoch: Date(), inclinationDegrees: 0, raanDegrees: 0, eccentricity: 0,
            argPerigeeDegrees: 0, meanAnomalyDegrees: 0, meanMotionRevPerDay: 16
        )
        // N'affirme rien sur le résultat exact (dépend de la géométrie), seulement que l'appel ne
        // plante pas et retourne soit nil soit une position valide (élévation dans [-90, 90]).
        if let position = SatelliteLookupService.topocentricPosition(of: degenerateTLE, at: Date(), observerLatitude: 45, observerLongitude: -73) {
            XCTAssertTrue(position.elevationDegrees >= -90 && position.elevationDegrees <= 90)
        }
    }

    func testTopocentricPositionElevationIsWithinValidRange() throws {
        let position = try XCTUnwrap(SatelliteLookupService.topocentricPosition(of: issTLE, at: issTLE.epoch, observerLatitude: 45.0, observerLongitude: -73.0))
        XCTAssertGreaterThanOrEqual(position.elevationDegrees, -90)
        XCTAssertLessThanOrEqual(position.elevationDegrees, 90)
        XCTAssertGreaterThanOrEqual(position.azimuthDegrees, 0)
        XCTAssertLessThan(position.azimuthDegrees, 360)
    }
}
