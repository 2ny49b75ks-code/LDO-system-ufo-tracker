// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import CoreLocation

/// Fournit la position GPS de l'appareil au moment de l'enregistrement — utilisée uniquement pour
/// situer la capture sur une carte dans les résultats (voir ResultsView), jamais pour le calcul de
/// distance/trajectoire de l'objet lui-même (qui reste basé sur la triangulation angulaire, voir
/// DistanceEstimator). Permission « quand l'app est utilisée » uniquement, aucun suivi en arrière-plan.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var lastKnownLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// Demande une position ponctuelle (pas de suivi continu) — suffisant pour associer une position
    /// approximative à l'enregistrement qui démarre.
    func captureCurrentLocation() {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastKnownLocation = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Échec silencieux : la position GPS est un enrichissement optionnel des résultats
        // (voir ResultsView, message explicite si indisponible), pas une donnée requise pour l'analyse.
    }
}
