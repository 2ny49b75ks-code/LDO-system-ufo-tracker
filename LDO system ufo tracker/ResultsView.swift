// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI
import MapKit
import CoreLocation
import UIKit

/// Page annexe claire présentée après l'analyse : toutes les informations demandées (points 1 à 9)
/// plus le verdict final et le pourcentage de possibilité.
struct ResultsView: View {
    let session: AnalysisSession
    /// Remet l'app à zéro pour la prochaine capture — voir la demande de réinitialisation
    /// automatique une fois le cycle capture + photos + analyse terminé.
    var onFinished: () -> Void = {}

    var body: some View {
        NavigationView {
            ScrollView {
                resultsContent
            }
            .navigationTitle("Analyse LDO")
        }
    }

    /// Contenu complet des résultats (photos, mesures, cartes, verdict) — factorisé hors de `body`
    /// pour être réutilisé tel quel par la capture d'écran complète sauvegardée dans Photos à la
    /// suite des 3 photos recadrées (voir `ResultsScreenshotRenderer`), demande explicite de
    /// Jean-David : « fais capture d'écran et sauvegarde dans la bibliothèque toute l'analyse ».
    var resultsContent: some View {
        VStack(alignment: .leading, spacing: 16) {

                    if !session.photosWithOverlays.isEmpty {
                        let labels = ["Plan large", "Zoom maximum sur la cible", "Zoom ×2"]
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(Array(session.photosWithOverlays.enumerated()), id: \.offset) { index, cg in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Image(decorative: cg, scale: 1)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 260)
                                            .cornerRadius(12)
                                        Text(index < labels.count ? labels[index] : "Photo \(index + 1)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    if !session.photosSavedToLibrary {
                        Text("⚠️ La sauvegarde dans Photos a échoué — vérifiez la permission photothèque de LDO dans Réglages.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    Group {
                        resultRow("Forme détectée", session.shapeDescription +
                                  " (\(Int(session.shapeConfidence * 100))% de confiance)")
                        resultRow("Direction", session.isLinear ? "Trajectoire rectiligne continue (R²: \(String(format: "%.2f", session.linearityR2)))" : "Trajectoire asymétrique / changements brusques (R²: \(String(format: "%.2f", session.linearityR2)))")
                        resultRow("Accélération angulaire max.", "\(Int(session.maxAngularAccelerationDegPerS2))°/s² (mesure indépendante de la distance)")
                        if session.hasImpossibleGForce {
                            resultRow("Force G estimée", "⚠️ \(String(format: "%.1f", session.estimatedGForce)) G — dépasse la tolérance humaine (~9G) — confiance : \(Int(session.gForceConfidence * 100))%")
                        } else if session.gForceConfidence > 0 {
                            resultRow("Force G estimée", "\(String(format: "%.1f", session.estimatedGForce)) G — confiance : \(Int(session.gForceConfidence * 100))%")
                        } else {
                            resultRow("Force G estimée", "Non calculable (distance à l'objet trop incertaine)")
                        }
                        resultRow("Illumination", "\(session.illuminationPattern) — couleur : \(session.illuminationColor)")
                        resultRow("Vitesse", "Moyenne : \(Int(session.estimatedSpeedKmh)) km/h — Max : \(Int(session.maxSpeedKmh)) km/h" +
                                  (session.speedConfidence > 0 ? " (confiance : \(Int(session.speedConfidence * 100))%)" : ""))
                        resultRow("Comparaison", session.speedComparisonLabel)
                        if session.speedDefiesPhysics {
                            resultRow("Accélération", "⚠️ \(Int(session.maxLinearAccelerationMS2)) m/s² soutenus — dépasse la performance des aéronefs connus")
                        }
                        resultRow("Distance estimée", distanceText())
                        if let matchedBody = session.matchedCelestialBody {
                            resultRow("Correspondance astronomique", "Direction compatible avec \(matchedBody)" +
                                      (session.celestialMatchSeparationDegrees.map { " (écart : \(String(format: "%.1f", $0))°, approximatif)" } ?? ""))
                        }
                        resultRow("Son", session.soundClassification)
                        resultRow("Date et heure", session.timestamp.formatted())
                    }

                    // Carte en vue aérienne avec le tracé de la trajectoire
                    if !session.trajectoryOnMap.isEmpty {
                        Text("Trajectoire (vue aérienne)")
                            .font(.headline)
                        TrajectoryMapView(coordinates: session.trajectoryOnMap)
                            .frame(height: 220)
                            .cornerRadius(12)
                    }

                    // Position de la capture : carte + coordonnées GPS de l'appareil au moment de
                    // l'enregistrement (voir LocationProvider). Indisponible pour une vidéo importée
                    // de la bibliothèque ou si la permission de localisation n'a pas été accordée.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Position de la capture")
                            .font(.headline)
                        if let coordinate = session.captureLocation {
                            CaptureLocationMapView(coordinate: coordinate)
                                .frame(height: 220)
                                .cornerRadius(12)
                            Text(String(format: "Latitude : %.5f — Longitude : %.5f", coordinate.lat, coordinate.lon))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if CLLocationManager().authorizationStatus == .denied {
                            Text("Position GPS refusée pour LDO.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                Text("Ouvrir Réglages")
                                    .font(.caption.bold())
                            }
                        } else {
                            Text("Position GPS non disponible (vidéo importée depuis la bibliothèque, ou position non obtenue à temps lors de l'enregistrement).")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Verdict")
                            .font(.title3.bold())
                        HStack {
                            Text(session.verdictLabel)
                                .font(.headline)
                                .foregroundColor(session.verdictConfidencePercent >= 60 ? .green : .primary)
                            Spacer()
                            Text("\(session.verdictConfidencePercent)% de possibilité")
                                .font(.subheadline.bold())
                        }
                        ForEach(session.verdictFactors, id: \.self) { factor in
                            Text("• \(factor)")
                                .font(.caption)
                        }
                        Text("Cette analyse est une aide à l'interprétation, pas une certification scientifique.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(12)

                    Button {
                        onFinished()
                    } label: {
                        Text("Nouvelle capture")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .padding(.top, 4)
                }
                .padding()
                // Logo LDO en haut à droite de la page de résultats — demande explicite de
                // Jean-David (2026-08-09), même filigrane de marque que sur les 3 photos et la
                // vidéo exportée (voir OverlayRenderer). Placé en overlay plutôt que dans le flux du
                // VStack pour rester fixe en haut, superposé au contenu qui défile en-dessous.
                .overlay(alignment: .topTrailing) {
                    Image("Logo")
                        .resizable()
                        .frame(width: 36, height: 36)
                        .padding(12)
                }
    }

    private func distanceText() -> String {
        guard let d = session.estimatedDistanceMeters else { return "Non déterminable (données insuffisantes)" }
        let alt = session.estimatedAltitudeMeters.map { " — Altitude estimée : \(Int($0)) m" } ?? ""
        return "\(Int(d)) m (confiance : \(Int(session.distanceConfidence * 100))% — \(session.distanceMethod))\(alt)"
    }

    private func resultRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.body)
        }
    }
}

/// Carte affichant un repère à la position GPS de l'appareil au moment de l'enregistrement — API
/// SwiftUI Map moderne, plus simple que `TrajectoryMapView` ci-dessous puisqu'il n'y a ici qu'un
/// seul point à afficher (pas de tracé nécessitant un `MKMapViewDelegate`).
struct CaptureLocationMapView: View {
    let coordinate: CLCoordinate

    private var coordinate2D: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.lat, longitude: coordinate.lon)
    }

    /// Étendue à l'échelle du pays (plutôt qu'un simple quartier/ville) — suffisant pour situer
    /// l'observation dans son contexte géographique large, tel que demandé.
    private static let countryScaleSpan = MKCoordinateSpan(latitudeDelta: 20, longitudeDelta: 20)

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: coordinate2D,
            span: Self.countryScaleSpan
        ))) {
            Annotation("Lieu de capture", coordinate: coordinate2D) {
                ZStack {
                    Circle()
                        .stroke(Color.ldoSignal, lineWidth: 3)
                        .frame(width: 26, height: 26)
                    Circle()
                        .fill(Color.ldoSignal)
                        .frame(width: 9, height: 9)
                }
                .shadow(color: Color.ldoSignal.opacity(0.6), radius: 4)
            }
        }
    }
}

extension Color {
    /// Vert signature LDO (#39FF14), utilisé partout dans l'app et le site web.
    static let ldoSignal = Color(red: Double(0x39) / 255, green: Double(0xFF) / 255, blue: Double(0x14) / 255)
}

/// Vue MapKit affichant la trajectoire (vue aérienne) sous forme de polyligne rouge.
///
/// NOTE IMPORTANTE : un `MKMapViewDelegate` est requis pour que MapKit sache *comment* dessiner
/// l'overlay ajouté (`addOverlay`). Sans lui, la polyligne existe dans les données de la carte
/// mais reste invisible à l'écran — c'était le bug dans la version précédente de ce fichier.
struct TrajectoryMapView: UIViewRepresentable {
    let coordinates: [CLCoordinate]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator

        let coords = coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let polyline = MKPolyline(coordinates: coords, count: coords.count)
        map.addOverlay(polyline)

        if !coords.isEmpty {
            // Ajuste la carte pour montrer toute la trajectoire, pas seulement son premier point,
            // avec une marge confortable autour.
            let polylineRect = polyline.boundingMapRect
            let padded = polylineRect.insetBy(dx: -polylineRect.size.width * 0.25,
                                               dy: -polylineRect.size.height * 0.25)
            map.setVisibleMapRect(padded, animated: false)
        }
        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Recalcule l'overlay si les coordonnées changent (ex. re-render après une nouvelle analyse).
        uiView.removeOverlays(uiView.overlays)
        let coords = coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        guard !coords.isEmpty else { return }
        let polyline = MKPolyline(coordinates: coords, count: coords.count)
        uiView.addOverlay(polyline)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = .systemRed
            renderer.lineWidth = 4
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
    }
}
