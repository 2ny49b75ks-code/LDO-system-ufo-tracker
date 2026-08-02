// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI
import ARKit

/// Écran d'ouverture de l'application LDO.
/// Affiche le viseur caméra + LiDAR et un bouton en forme de soucoupe volante
/// qui déclenche automatiquement l'enregistrement HD + capture de profondeur LiDAR maximale.
struct ContentView: View {
    @StateObject private var capture = CaptureManager()
    @State private var showResults = false
    @State private var lastSession: AnalysisSession?

    var body: some View {
        ZStack {
            CameraPreviewView(session: capture.session)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Image("Logo")
                        .resizable()
                        .frame(width: 40, height: 40)
                    Text("LDO — Détecteur d'OVNI")
                        .foregroundColor(.green)
                        .font(.headline)
                    Spacer()
                    // Indicateur LiDAR actif
                    Label(capture.lidarActive ? "LiDAR actif" : "LiDAR indisponible",
                          systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
