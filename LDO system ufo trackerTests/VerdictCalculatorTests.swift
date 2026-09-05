// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import XCTest
@testable import LDO_system_ufo_tracker

/// Verrouille le comportement des règles de `VerdictCalculator` déjà corrigées lors de la revue de
/// code du 2026-08-27 (voir l'historique du fichier) — le projet n'avait auparavant AUCUNE couverture
/// de test, ce qui a permis à plusieurs de ces bugs de rester inaperçus. Ne couvre pas exhaustivement
/// toutes les règles, seulement celles où un bug réel a déjà été trouvé et corrigé, pour empêcher une
/// régression silencieuse future.
final class VerdictCalculatorTests: XCTestCase {
    private let calculator = VerdictCalculator()

    // MARK: - Règle Mode Nuit : ordre traînée (météorite) vs scintillement+erratique (OVNI)

    /// BUG CORRIGÉ : une vraie météorite (traînée + luminosité irrégulière pendant l'ablation, R² dans
    /// la zone de recoupement 0,3-0,5) devait ressortir comme météorite (≤10%), pas comme OVNI (85%).
    func testMeteorTrailTakesPriorityOverIrregularFlickerRule() {
        var session = AnalysisSession()
        session.linearityR2 = 0.4   // dans la zone de recoupement entre les deux règles
        session.isZigzagTrajectory = false
        session.illuminationPattern = "Variable / scintillante irrégulière (≈ 0.2 Hz)"

        let luminousRegion = LuminousRegion(
            boundingBoxInImage: CGRect(x: 0, y: 0, width: 1, height: 10),   // très allongé -> traînée
            averageBrightness: 0.8,
            averageColor: (r: 1, g: 1, b: 1),
            contourIrregularity: 0.5
        )
        let shape = ShapeResult(label: "Point lumineux", confidence: 0.2, luminousRegion: luminousRegion)

        let verdict = calculator.computeVerdict(session: session, shape: shape, mode: .night)

        XCTAssertLessThanOrEqual(verdict.percent, 10, "Une traînée + trajectoire continue doit être identifiée comme météorite, pas comme OVNI")
    }

    /// Sans forme de traînée, le scintillement irrégulier + trajectoire erratique reste bien traité
    /// comme un signal OVNI (vérifie que la réorganisation des règles n'a pas cassé ce cas).
    func testIrregularFlickerWithoutTrailStillFlagsAsUFO() {
        var session = AnalysisSession()
        session.linearityR2 = 0.2   // trajectoire erratique, hors zone de recoupement
        session.isZigzagTrajectory = false
        session.illuminationPattern = "Variable / scintillante irrégulière (≈ 0.2 Hz)"

        let shape = ShapeResult(label: "Point lumineux", confidence: 0.2, luminousRegion: nil)
        let verdict = calculator.computeVerdict(session: session, shape: shape, mode: .night)

        XCTAssertGreaterThanOrEqual(verdict.percent, 60, "Sans traînée, scintillement irrégulier + trajectoire erratique doit rester un signal OVNI")
    }

    // MARK: - Règle traînée de condensation (Mode Jour) : avion (montée) vs météorite (chute rapide)

    func testAscendingContrailIsIdentifiedAsAirplane() {
        var session = AnalysisSession()
        session.hasContrail = true
        session.isAscending = true

        let shape = ShapeResult(label: "Probable oiseau", confidence: 0.3, luminousRegion: nil)
        let verdict = calculator.computeVerdict(session: session, shape: shape, mode: .day)

        XCTAssertEqual(verdict.percent, 0)
        XCTAssertTrue(verdict.factors.contains { $0.localizedCaseInsensitiveContains("avion") })
    }

    func testDescendingContrailIsIdentifiedAsMeteorite() {
        var session = AnalysisSession()
        session.hasContrail = true
        session.isAscending = false

        let shape = ShapeResult(label: "Probable oiseau", confidence: 0.3, luminousRegion: nil)
        let verdict = calculator.computeVerdict(session: session, shape: shape, mode: .day)

        XCTAssertEqual(verdict.percent, 0)
        XCTAssertTrue(verdict.factors.contains { $0.localizedCaseInsensitiveContains("météorite") })
    }

    // MARK: - Correspondance astronomique : sur-priorité absolue

    func testCelestialMatchAlwaysReturnsZeroPercent() {
        var session = AnalysisSession()
        session.matchedCelestialBody = "Vénus"
        session.celestialMatchSeparationDegrees = 3.5
        // Des signaux par ailleurs très "OVNI" ne doivent PAS l'emporter sur une correspondance astronomique.
        session.illuminationPattern = "Variable / scintillante irrégulière (≈ 0.2 Hz)"
        session.linearityR2 = 0.1
        session.isZigzagTrajectory = true

        let shape = ShapeResult(label: "Forme non identifiée avec certitude", confidence: 0.15, luminousRegion: nil)
        let verdict = calculator.computeVerdict(session: session, shape: shape, mode: .night)

        XCTAssertEqual(verdict.percent, 0)
    }

    // MARK: - Plafond à 90% : jamais 100%

    func testVerdictNeverReachesOneHundredPercent() {
        // Session délibérément construite pour maximiser tous les facteurs "OVNI" possibles.
        var session = AnalysisSession()
        session.linearityR2 = 0.0
        session.isZigzagTrajectory = true
        session.hasImpossibleGForce = true
        session.speedDefiesPhysics = true
        session.illuminationPattern = "Variable / scintillante irrégulière (≈ 0.2 Hz)"

        let shape = ShapeResult(label: "Forme non identifiée avec certitude", confidence: 0.15, luminousRegion: nil)
        let verdict = calculator.computeVerdict(session: session, shape: shape, mode: .night)

        XCTAssertLessThanOrEqual(verdict.percent, 90, "LDO ne prétend jamais à une certitude absolue — le verdict ne doit jamais atteindre 100%")
    }

    // MARK: - Session par défaut (données insuffisantes) : ne doit pas planter

    func testDefaultSessionProducesAVerdictWithoutCrashing() {
        let session = AnalysisSession()
        let shape = ShapeResult(label: "Données insuffisantes", confidence: 0, luminousRegion: nil)
        let verdict = calculator.computeVerdict(session: session, shape: shape, mode: .day)

        XCTAssertFalse(verdict.label.isEmpty)
    }
}
