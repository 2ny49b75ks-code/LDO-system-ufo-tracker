// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI
import MapKit

/// Page annexe claire présentée après l'analyse : toutes les informations demandées (points 1 à 9)
/// plus le verdict final et le pourcentage de possibilité.
struct ResultsView: View {
    let session: AnalysisSession

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    if let cg = session.photosWithOverlays.first {
                        Image(decorative: cg, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(12)
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
                }
                .padding()
            }
            .navigationTitle("Analyse LDO")
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
