// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import CoreImage

/// `CIContext` unique, réutilisé à travers tout le pipeline — remplace 6 instances indépendantes
/// (`CaptureManager`, `OverlayRenderer`, `PhotoComposer`, `ShapeClassifier`, `MotionDetector`, relevé
/// par la revue de code du 2026-08-27), chacune payant séparément le coût d'initialisation d'un
/// contexte Core Image (généralement soutenu par Metal) — documenté par Apple comme volontairement
/// conçu pour être créé une fois et réutilisé, pas recréé à la demande.
enum SharedImageContext {
    static let context = CIContext()
}
