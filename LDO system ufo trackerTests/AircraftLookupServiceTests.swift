// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import XCTest
@testable import LDO_system_ufo_tracker

/// Vérifie `AircraftLookupService` (recoupement ADS-B, pivot du 2026-09-12) : analyse de la réponse
/// OpenSky, correspondance directionnelle, et gestion réseau — le tout SANS appel réseau réel (voir
/// `MockURLProtocol` en bas de fichier), pour ne jamais consommer le quota anonyme d'OpenSky en CI.
final class AircraftLookupServiceTests: XCTestCase {

    // MARK: - Analyse de la réponse OpenSky (schéma vérifié : tableau positionnel à 18 champs)

    func testParseStatesExtractsValidCandidate() {
        let json = """
        {"time": 1700000000, "states": [
            ["abc123", "AFR123  ", "France", 1700000000, 1700000000, 5.0, 45.0, 1000.0, false, 250.0, 90.0, 0.0, null, 10500.0, "1000", false, 0, 0]
        ]}
        """.data(using: .utf8)!
        let candidates = AircraftLookupService.parseStates(from: json)
        XCTAssertEqual(candidates?.count, 1)
        XCTAssertEqual(candidates?.first?.icao24, "abc123")
        XCTAssertEqual(candidates?.first?.callsign, "AFR123")
        XCTAssertEqual(candidates?.first?.latitude, 45.0)
        XCTAssertEqual(candidates?.first?.longitude, 5.0)
        XCTAssertEqual(candidates?.first?.altitudeMeters, 10500.0)
        XCTAssertFalse(candidates?.first?.onGround ?? true)
        XCTAssertEqual(candidates?.first?.groundSpeedMS, 250.0)
    }

    func testParseStatesSkipsMalformedRowsWithoutFailingTheWholeResponse() {
        let json = """
        {"time": 1700000000, "states": [
            ["tooshort"],
            ["abc123", null, "France", null, 1700000000, 5.0, 45.0, 1000.0, false, 250.0, 90.0, 0.0, null, 10500.0, "1000", false, 0, 0]
        ]}
        """.data(using: .utf8)!
        let candidates = AircraftLookupService.parseStates(from: json)
        XCTAssertEqual(candidates?.count, 1, "La ligne trop courte doit être ignorée sans faire échouer l'analyse des autres")
        XCTAssertNil(candidates?.first?.callsign, "Un indicatif manquant doit devenir nil, pas planter")
    }

    func testParseStatesFallsBackToBaroAltitudeWhenGeoAltitudeMissing() {
        let json = """
        {"time": 1700000000, "states": [
            ["abc123", "AFR123", "France", 1700000000, 1700000000, 5.0, 45.0, 999.0, false, 250.0, 90.0, 0.0, null, null, "1000", false, 0, 0]
        ]}
        """.data(using: .utf8)!
        let candidates = AircraftLookupService.parseStates(from: json)
        XCTAssertEqual(candidates?.first?.altitudeMeters, 999.0)
    }

    func testParseStatesReturnsEmptyArrayWhenNoStatesKey() {
        let json = "{}".data(using: .utf8)!
        XCTAssertEqual(AircraftLookupService.parseStates(from: json), [])
    }

    // MARK: - Correspondance directionnelle

    func testClosestMatchFindsAircraftAlongObservedBearing() {
        let observer = CLCoordinate(lat: 45.0, lon: -73.0)
        // Avion droit au nord (~50 km), altitude de croisière -> élévation faible mais non nulle.
        let candidate = AircraftLookupService.AircraftCandidate(
            icao24: "abc123", callsign: "AFR123", latitude: 45.45, longitude: -73.0, altitudeMeters: 10000, onGround: false, groundSpeedMS: nil
        )
        let match = AircraftLookupService.closestMatch(
            candidates: [candidate], observerLocation: observer,
            observedAzimuthDegrees: 0, observedElevationDegrees: 12, toleranceDegrees: 10
        )
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.candidate.icao24, "abc123")
    }

    func testClosestMatchReturnsNilWhenNoAircraftWithinTolerance() {
        let observer = CLCoordinate(lat: 45.0, lon: -73.0)
        let candidate = AircraftLookupService.AircraftCandidate(
            icao24: "abc123", callsign: nil, latitude: 45.45, longitude: -73.0, altitudeMeters: 10000, onGround: false, groundSpeedMS: nil
        )
        // Direction observée à l'opposé (sud) : aucune correspondance possible dans la tolérance.
        let match = AircraftLookupService.closestMatch(
            candidates: [candidate], observerLocation: observer,
            observedAzimuthDegrees: 180, observedElevationDegrees: 12, toleranceDegrees: 10
        )
        XCTAssertNil(match)
    }

    func testClosestMatchIgnoresAircraftOnGround() {
        let observer = CLCoordinate(lat: 45.0, lon: -73.0)
        let onGround = AircraftLookupService.AircraftCandidate(
            icao24: "abc123", callsign: nil, latitude: 45.001, longitude: -73.0, altitudeMeters: 0, onGround: true, groundSpeedMS: nil
        )
        let match = AircraftLookupService.closestMatch(
            candidates: [onGround], observerLocation: observer,
            observedAzimuthDegrees: 0, observedElevationDegrees: 5, toleranceDegrees: 10
        )
        XCTAssertNil(match, "Un aéronef au sol ne doit jamais être proposé comme correspondance")
    }

    func testClosestMatchPicksTheClosestAmongMultipleCandidates() {
        let observer = CLCoordinate(lat: 45.0, lon: -73.0)
        let far = AircraftLookupService.AircraftCandidate(
            icao24: "far", callsign: nil, latitude: 45.45, longitude: -72.5, altitudeMeters: 10000, onGround: false, groundSpeedMS: nil
        )
        let near = AircraftLookupService.AircraftCandidate(
            icao24: "near", callsign: nil, latitude: 45.45, longitude: -73.0, altitudeMeters: 10000, onGround: false, groundSpeedMS: nil
        )
        let match = AircraftLookupService.closestMatch(
            candidates: [far, near], observerLocation: observer,
            observedAzimuthDegrees: 0, observedElevationDegrees: 12, toleranceDegrees: 10
        )
        XCTAssertEqual(match?.candidate.icao24, "near")
    }

    // MARK: - Réseau : succès, échec HTTP, erreur de transport — via URLProtocol simulé

    func testFetchAircraftStatesSucceedsWithMockedResponse() {
        let json = """
        {"time": 1700000000, "states": [
            ["abc123", "AFR123", "France", 1700000000, 1700000000, -73.0, 45.45, 1000.0, false, 250.0, 90.0, 0.0, null, 10000.0, "1000", false, 0, 0]
        ]}
        """.data(using: .utf8)!
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let expectation = expectation(description: "network success")
        AircraftLookupService.fetchAircraftStates(around: CLCoordinate(lat: 45, lon: -73), urlSession: mockedSession()) { result in
            switch result {
            case .success(let candidates): XCTAssertEqual(candidates.count, 1)
            case .failure: XCTFail("Attendu un succès")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testFetchAircraftStatesReturnsHTTPErrorOnServerFailure() {
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        let expectation = expectation(description: "network failure")
        AircraftLookupService.fetchAircraftStates(around: CLCoordinate(lat: 45, lon: -73), urlSession: mockedSession()) { result in
            if case .failure(.httpError(let code)) = result {
                XCTAssertEqual(code, 503)
            } else {
                XCTFail("Attendu une erreur HTTP 503")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testFetchAircraftStatesReturnsNetworkUnavailableOnTransportError() {
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        let expectation = expectation(description: "network unavailable")
        AircraftLookupService.fetchAircraftStates(around: CLCoordinate(lat: 45, lon: -73), urlSession: mockedSession()) { result in
            guard case .failure(.networkUnavailable) = result else {
                XCTFail("Attendu networkUnavailable")
                expectation.fulfill()
                return
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    private func mockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// URLProtocol simulé — évite tout appel réseau réel pendant les tests, y compris le CI, pour ne
/// jamais consommer le quota quotidien anonyme d'OpenSky (voir `AircraftLookupService`).
final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
