// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation

/// Recoupement avec le réseau ADS-B public (OpenSky Network, https://opensky-network.org, gratuit,
/// sans clé) pour identifier si un avion RÉEL, actuellement en vol et signalé par transpondeur, se
/// trouvait dans l'axe visé au moment de la captation — voir le plan de pivot du 2026-09-12.
///
/// Remplace l'ancienne triangulation par taille réelle supposée (voir la note de dépréciation en
/// tête de `DistanceEstimator.swift`) par une identification géométrique contre un objet réel
/// plutôt qu'une physique devinée à partir de pixels : direction observée (boussole ARKit, voir
/// `TrajectoryCalculator.observedAzimuthElevation`) comparée au cap/élévation réels de chaque avion
/// en vol dans la zone, plutôt qu'à une distance déduite d'une taille supposée.
///
/// LIMITE IMPORTANTE, assumée délibérément plutôt que cachée : l'accès anonyme d'OpenSky ne couvre
/// que le trafic EN TEMPS RÉEL (pas de relecture historique arbitraire pour un compte anonyme) — un
/// appel n'a de sens que pour une vidéo analysée peu après sa captation (voir
/// `AnalysisEngine.maxUsefulLookupAgeHours`, qui saute l'appel au-delà de ce délai plutôt que de
/// gaspiller une requête pour un résultat qui ne pourrait de toute façon rien prouver).
enum AircraftLookupService {

    /// Un avion en vol tel que rapporté par OpenSky à l'instant de la requête.
    struct AircraftCandidate: Equatable {
        let icao24: String
        let callsign: String?
        let latitude: Double
        let longitude: Double
        let altitudeMeters: Double?
        let onGround: Bool
    }

    enum LookupError: Error, Equatable {
        case networkUnavailable
        case httpError(Int)
        case decodingFailed
    }

    /// Rayon de recherche (km) autour de la position de captation. Un avion de ligne à altitude de
    /// croisière reste visible bien au-delà de l'horizon d'un objet plus bas, sans pour autant
    /// justifier une boîte si large qu'elle gaspille inutilement le quota quotidien anonyme
    /// d'OpenSky (400 crédits/jour, le coût croît avec la surface interrogée) — valeur raisonnée,
    /// non validée empiriquement (voir le plan de pivot).
    static let defaultSearchRadiusKm: Double = 100

    /// Tolérance angulaire par défaut pour accepter une correspondance — plus stricte que celle du
    /// recoupement astral (12°, voir `AnalysisEngine`) car la position ADS-B d'un avion est bien
    /// plus certaine qu'une position orbitale approximative ; l'imprécision de la boussole du
    /// téléphone reste la source d'erreur dominante ici. À ajuster après le test terrain décrit
    /// dans le plan de pivot (vérification de la convention azimut nord/est).
    static let defaultToleranceDegrees: Double = 10.0

    static func fetchAircraftStates(
        around center: CLCoordinate,
        radiusKm: Double = defaultSearchRadiusKm,
        urlSession: URLSession = .shared,
        completion: @escaping (Result<[AircraftCandidate], LookupError>) -> Void
    ) {
        guard let url = boundingBoxURL(center: center, radiusKm: radiusKm) else {
            completion(.failure(.decodingFailed))
            return
        }
        let task = urlSession.dataTask(with: url) { data, response, error in
            if error != nil {
                completion(.failure(.networkUnavailable))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.failure(.httpError(http.statusCode)))
                return
            }
            guard let data, let candidates = parseStates(from: data) else {
                completion(.failure(.decodingFailed))
                return
            }
            completion(.success(candidates))
        }
        task.resume()
    }

    private static func boundingBoxURL(center: CLCoordinate, radiusKm: Double) -> URL? {
        let latDelta = radiusKm / 111.0
        // Correction de la longitude par le cosinus de la latitude (les degrés de longitude se
        // resserrent en s'éloignant de l'équateur) ; plancher à 0.01 pour éviter une division qui
        // exploserait près des pôles (non pertinent pour cette app, mais évite un crash théorique).
        let lonDelta = radiusKm / (111.0 * max(cos(center.lat * .pi / 180), 0.01))
        var components = URLComponents(string: "https://opensky-network.org/api/states/all")
        components?.queryItems = [
            URLQueryItem(name: "lamin", value: String(center.lat - latDelta)),
            URLQueryItem(name: "lamax", value: String(center.lat + latDelta)),
            URLQueryItem(name: "lomin", value: String(center.lon - lonDelta)),
            URLQueryItem(name: "lomax", value: String(center.lon + lonDelta)),
        ]
        return components?.url
    }

    /// Analyse la réponse `/states/all` d'OpenSky — schéma vérifié auprès de la documentation
    /// publiée par OpenSky (pas seulement supposé) : chaque état est un TABLEAU POSITIONNEL
    /// hétérogène (pas un objet JSON à clés), avec au moins les champs suivants dans cet ordre :
    /// icao24(0), callsign(1), origin_country(2), time_position(3), last_contact(4), longitude(5),
    /// latitude(6), baro_altitude(7), on_ground(8), velocity(9), true_track(10), vertical_rate(11),
    /// sensors(12), geo_altitude(13), squawk(14), spi(15), position_source(16), category(17).
    /// `internal` (pas `private`) pour rester testable directement (voir `AircraftLookupServiceTests`).
    static func parseStates(from data: Data) -> [AircraftCandidate]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let states = json["states"] as? [[Any?]]
        else { return [] }
        return states.compactMap { row -> AircraftCandidate? in
            // Au moins 17 champs nécessaires (jusqu'à geo_altitude inclus) ; une ligne plus courte
            // est ignorée plutôt que de faire échouer l'analyse de toute la réponse.
            guard row.count >= 17,
                  let icao24 = row[0] as? String,
                  let longitude = row[5] as? Double,
                  let latitude = row[6] as? Double,
                  let onGround = row[8] as? Bool
            else { return nil }
            let rawCallsign = (row[1] as? String)?.trimmingCharacters(in: .whitespaces)
            // `geo_altitude` (13) préférée à `baro_altitude` (7, sensible à la pression
            // atmosphérique locale) ; repli sur baro_altitude si geo_altitude est absente.
            let altitude = (row[13] as? Double) ?? (row[7] as? Double)
            return AircraftCandidate(
                icao24: icao24,
                callsign: (rawCallsign?.isEmpty ?? true) ? nil : rawCallsign,
                latitude: latitude,
                longitude: longitude,
                altitudeMeters: altitude,
                onGround: onGround
            )
        }
    }

    /// Parmi les avions EN VOL de `candidates` (les avions au sol sont exclus — jamais la source
    /// d'un phénomène observé dans le ciel), retient celui dont le cap/élévation réels depuis
    /// `observerLocation` sont les plus proches de la direction `observedAzimuthDegrees`/
    /// `observedElevationDegrees` réellement filmée — même principe de correspondance que
    /// `CelestialPositionCalculator`, mais contre un objet réel et non une position orbitale calculée.
    static func closestMatch(
        candidates: [AircraftCandidate],
        observerLocation: CLCoordinate,
        observedAzimuthDegrees: Double,
        observedElevationDegrees: Double,
        toleranceDegrees: Double = defaultToleranceDegrees
    ) -> (candidate: AircraftCandidate, separationDegrees: Double, distanceKm: Double)? {
        let inFlight = candidates.filter { !$0.onGround }
        guard !inFlight.isEmpty else { return nil }

        let scored: [(AircraftCandidate, Double, Double)] = inFlight.map { candidate in
            let aircraftLocation = CLCoordinate(lat: candidate.latitude, lon: candidate.longitude)
            let bearing = AngularGeometry.greatCircleBearingDegrees(from: observerLocation, to: aircraftLocation)
            let groundDistanceMeters = AngularGeometry.greatCircleDistanceMeters(from: observerLocation, to: aircraftLocation)
            let elevation = AngularGeometry.elevationDegrees(
                groundDistanceMeters: groundDistanceMeters,
                heightDeltaMeters: candidate.altitudeMeters ?? 0
            )
            let separation = AngularGeometry.angularSeparationDegrees(
                az1: observedAzimuthDegrees, el1: observedElevationDegrees, az2: bearing, el2: elevation
            )
            return (candidate, separation, groundDistanceMeters / 1000)
        }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 <= toleranceDegrees else { return nil }
        return (best.0, best.1, best.2)
    }
}

/// Statut du recoupement ADS-B pour une session analysée — affiché à l'utilisateur (voir
/// `ResultsView`) pour distinguer honnêtement « aucun avion à proximité » d'un simple problème
/// réseau ou d'une vidéo trop ancienne pour que la vérification en temps réel ait un sens, plutôt
/// que de laisser un silence ambigu (principe de transparence déjà établi, voir `VerdictCalculator`).
enum AircraftLookupStatus: Equatable {
    case notAttempted
    case skippedStaleCapture(hoursElapsed: Double)
    case networkUnavailable
    case queriedNoAircraftNearby
    case queriedNoBearingMatch(nearbyCount: Int)
    case matched
}
