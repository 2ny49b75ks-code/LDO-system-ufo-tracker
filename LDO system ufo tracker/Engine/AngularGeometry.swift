// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation

/// Géométrie angulaire partagée entre les deux recoupements par correspondance directionnelle :
/// astres connus (voir `CelestialPositionCalculator`) et aéronefs réels via ADS-B (voir
/// `AircraftLookupService`) — extraite d'`AnalysisEngine` (pivot du 2026-09-12) pour éviter de
/// dupliquer la même formule d'écart angulaire à deux endroits.
enum AngularGeometry {

    /// Distance angulaire (degrés) entre deux directions données en azimut/élévation — via leurs
    /// vecteurs unitaires, pas une simple différence de coordonnées (fausse près du zénith où
    /// l'azimut perd sa signification).
    static func angularSeparationDegrees(az1: Double, el1: Double, az2: Double, el2: Double) -> Double {
        let az1Rad = az1 * .pi / 180, el1Rad = el1 * .pi / 180
        let az2Rad = az2 * .pi / 180, el2Rad = el2 * .pi / 180
        let x1 = cos(el1Rad) * sin(az1Rad), y1 = cos(el1Rad) * cos(az1Rad), z1 = sin(el1Rad)
        let x2 = cos(el2Rad) * sin(az2Rad), y2 = cos(el2Rad) * cos(az2Rad), z2 = sin(el2Rad)
        let dot = max(-1, min(1, x1 * x2 + y1 * y2 + z1 * z2))
        return acos(dot) * 180 / .pi
    }

    /// Cap grand-cercle (degrés, 0° = nord, 90° = est) de `from` vers `to` — formule orthodromique
    /// standard, précise même sur les distances de 50-150 km typiques d'un aéronef à altitude de
    /// croisière (contrairement à une simple loxodromie plane).
    static func greatCircleBearingDegrees(from: CLCoordinate, to: CLCoordinate) -> Double {
        let lat1 = from.lat * .pi / 180, lat2 = to.lat * .pi / 180
        let deltaLon = (to.lon - from.lon) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let bearing = atan2(y, x) * 180 / .pi
        return bearing < 0 ? bearing + 360 : bearing
    }

    /// Distance grand-cercle (mètres) entre deux coordonnées GPS — formule de haversine.
    static func greatCircleDistanceMeters(from: CLCoordinate, to: CLCoordinate) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let lat1 = from.lat * .pi / 180, lat2 = to.lat * .pi / 180
        let deltaLat = (to.lat - from.lat) * .pi / 180
        let deltaLon = (to.lon - from.lon) * .pi / 180
        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        let c = 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
        return earthRadiusMeters * c
    }

    /// Angle d'élévation (degrés) depuis l'observateur vers un objet à `groundDistanceMeters` de
    /// distance horizontale et `heightDeltaMeters` au-dessus de l'observateur (altitude de
    /// l'observateur approximée à 0 — voir `AircraftLookupService`, `LocationProvider` ne lit
    /// jamais `CLLocation.altitude` aujourd'hui, correction jugée disproportionnée pour l'erreur
    /// qu'elle introduirait). Approximation plan tangent : l'erreur due à la courbure terrestre
    /// reste négligeable à ces distances (~0.2° à 50 km, ~0.7° à 150 km pour une altitude de
    /// croisière typique), bien en-deçà de la tolérance de correspondance utilisée.
    static func elevationDegrees(groundDistanceMeters: Double, heightDeltaMeters: Double) -> Double {
        guard groundDistanceMeters > 0 else { return heightDeltaMeters > 0 ? 90 : -90 }
        return atan2(heightDeltaMeters, groundDistanceMeters) * 180 / .pi
    }
}
