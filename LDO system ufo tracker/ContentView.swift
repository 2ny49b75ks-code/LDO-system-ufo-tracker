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
                        .foregroundColor(capture.lidarActive ? .green : .red)
                }
                .padding()
                .background(.black.opacity(0.4))

                Spacer()

                // Bouton en forme de soucoupe volante
                Button(action: { capture.toggleRecording() }) {
                    SaucerButtonShape(isRecording: capture.isRecording)
                        .frame(width: 110, height: 60)
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            // Démarrage automatique : LiDAR à force maximale + résolution vidéo HD
            capture.configureMaximumLidar()
            capture.configureHDVideo()
        }
        .onChange(of: capture.finishedSession) { session in
            guard let session else { return }
            lastSession = session
            showResults = true
        }
        .sheet(isPresented: $showResults) {
            if let lastSession {
                ResultsView(session: lastSession)
            }
        }
    }
}

/// Dessin vectoriel simple d'un bouton "soucoupe volante".
struct SaucerButtonShape: View {
    var isRecording: Bool
    var body: some View {
        ZStack {
            Capsule()
                .fill(isRecording ? Color.red : Color.gray.opacity(0.85))
            Ellipse()
                .fill(Color.white.opacity(0.9))
                .frame(width: 40, height: 24)
                .offset(y: -14)
        }
        .shadow(color: isRecording ? .red : .green, radius: isRecording ? 12 : 4)
        .animation(.easeInOut(duration: 0.3), value: isRecording)
    }
}
