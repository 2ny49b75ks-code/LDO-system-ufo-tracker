// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import XCTest
@testable import LDO_system_ufo_tracker

/// Vérifie la géométrie angulaire partagée (voir `AngularGeometry`, extraite lors du pivot du
/// 2026-09-12) contre des valeurs de référence calculées à la main — utilisée à la fois par le
/// recoupement astral existant et le nouveau recoupement ADS-B (voir `AircraftLookupService`).
final class AngularGeometryTests: XCTestCase {

    func testAngularSeparationOfIdenticalDirectionsIsZero() {
        let separation = AngularGeometry.angularSeparationDegrees(az1: 45, el1: 30, az2: 45, el2: 30)
        XCTAssertEqual(separation, 0, accuracy: 0.001)
    }

    func testAngularSeparationOfOppositeDirectionsIsMax() {
        let separation = AngularGeometry.angularSeparationDegrees(az1: 0, el1: 0, az2: 180, el2: 0)
        XCTAssertEqual(separation, 180, accuracy: 0.001)
    }

    func testAngularSeparationOfPerpendicularDirectionsIs90() {
        let separation = AngularGeometry.angularSeparationDegrees(az1: 0, el1: 0, az2: 90, el2: 0)
        XCTAssertEqual(separation, 90, accuracy: 0.001)
    }

    func testGreatCircleBearingDueNorth() {
        let from = CLCoordinate(lat: 45.0, lon: -73.0)
        let to = CLCoordinate(lat: 46.0, lon: -73.0)
        XCTAssertEqual(AngularGeometry.greatCircleBearingDegrees(from: from, to: to), 0, accuracy: 1.0)
    }

    func testGreatCircleBearingDueSouth() {
        let from = CLCoordinate(lat: 45.0, lon: -73.0)
        let to = CLCoordinate(lat: 44.0, lon: -73.0)
        XCTAssertEqual(AngularGeometry.greatCircleBearingDegrees(from: from, to: to), 180, accuracy: 1.0)
    }

    func testGreatCircleBearingDueEastAtEquator() {
        let from = CLCoordinate(lat: 0.0, lon: 0.0)
        let to = CLCoordinate(lat: 0.0, lon: 1.0)
        XCTAssertEqual(AngularGeometry.greatCircleBearingDegrees(from: from, to: to), 90, accuracy: 1.0)
    }

    func testGreatCircleDistanceOneDegreeLatitudeIsRoughly111Km() {
        let from = CLCoordinate(lat: 45.0, lon: -73.0)
        let to = CLCoordinate(lat: 46.0, lon: -73.0)
        XCTAssertEqual(AngularGeometry.greatCircleDistanceMeters(from: from, to: to), 111_195, accuracy: 1_000)
    }

    func testGreatCircleDistanceOfIdenticalPointsIsZero() {
        let point = CLCoordinate(lat: 45.5, lon: -73.5)
        XCTAssertEqual(AngularGeometry.greatCircleDistanceMeters(from: point, to: point), 0, accuracy: 0.01)
    }

    func testElevationDegreesForEqualHeightAndDistanceIs45() {
        let elevation = AngularGeometry.elevationDegrees(groundDistanceMeters: 1000, heightDeltaMeters: 1000)
        XCTAssertEqual(elevation, 45, accuracy: 0.01)
    }

    func testElevationDegreesIsZeroAtSameAltitude() {
        let elevation = AngularGeometry.elevationDegrees(groundDistanceMeters: 5000, heightDeltaMeters: 0)
        XCTAssertEqual(elevation, 0, accuracy: 0.01)
    }
}
