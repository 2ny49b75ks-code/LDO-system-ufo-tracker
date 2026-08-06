// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation

/// Choix explicite de l'utilisateur plutôt qu'une détection automatique de scène sombre/claire :
/// plus fiable, et lui donne le contrôle plutôt qu'un seuil de luminosité qui peut se tromper
/// (ex. une pièce éclairée normalement peut avoir une luminosité moyenne proche d'un ciel nocturne
/// avec un point lumineux, selon l'exposition de la caméra).
///
/// Détermine la stratégie de détection de l'objet (voir `AnalysisEngine`) :
/// - `.night` : détection par seuil de luminosité en priorité (trouve directement le point le plus
///   brillant) — adapté à un objet lumineux sur ciel sombre, le cas d'usage principal de LDO.
/// - `.day` : détection par différence de mouvement uniquement — sur une scène normalement éclairée,
///   la luminosité seule ne permet pas d'isoler un objet précis (tout ressort à peu près aussi clair).
enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case night
    case day

    var id: String { rawValue }

    var label: String {
        switch self {
        case .night: return "Nuit"
        case .day: return "Jour"
        }
    }

    var systemImage: String {
        switch self {
        case .night: return "moon.stars.fill"
        case .day: return "sun.max.fill"
        }
    }
}
