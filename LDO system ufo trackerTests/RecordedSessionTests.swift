// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import XCTest
@testable import LDO_system_ufo_tracker

/// Vérifie que l'ajout de `captureStartedAt` (pivot du 2026-09-12) reste rétrocompatible avec un
/// ancien `index.json` déjà présent sur l'appareil d'un utilisateur — même principe déjà établi pour
/// `mode`/`latitude`/`hintPointX` (voir `RecordedSession.init(from:)`).
final class RecordedSessionTests: XCTestCase {

    func testDecodingLegacyJSONWithoutCaptureStartedAtFallsBackToNil() throws {
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "videoFileName": "video.mov",
            "posesFileName": null,
            "createdAt": 700000000.0,
            "mode": "night"
        }
        """.data(using: .utf8)!
        let session = try JSONDecoder().decode(RecordedSession.self, from: legacyJSON)
        XCTAssertNil(session.captureStartedAt)
    }

    func testEncodeDecodeRoundTripPreservesCaptureStartedAt() throws {
        let original = RecordedSession(
            id: UUID(), videoFileName: "video.mov", posesFileName: nil,
            createdAt: Date(), mode: .day,
            captureStartedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecordedSession.self, from: data)
        XCTAssertEqual(decoded.captureStartedAt, original.captureStartedAt)
    }

    func testEncodeDecodeRoundTripPreservesNilCaptureStartedAt() throws {
        let original = RecordedSession(
            id: UUID(), videoFileName: "video.mov", posesFileName: nil,
            createdAt: Date(), mode: .night, captureStartedAt: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecordedSession.self, from: data)
        XCTAssertNil(decoded.captureStartedAt)
    }
}
