// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI

/// Onglet LIVE : viseur caméra ARKit et bouton en forme de soucoupe volante qui déclenche
/// l'enregistrement HD. L'enregistrement est seulement SAUVEGARDÉ (voir
/// CaptureManager.storeRecording) — l'analyse se fait séparément, en choisissant la vidéo dans
/// « Mes enregistrements ».
struct LiveTabView: View {
    @ObservedObject var capture: CaptureManager
    @Binding var selectedTab: AppTab
    @State private var showRecordings = false

    var body: some View {
        ZStack {
            CameraPreviewView(session: capture.session)
                .ignoresSafeArea()

            VStack {
                AppTopBar(selectedTab: $selectedTab, trackingActive: capture.trackingActive)

                Spacer()

                // Choix Nuit/Jour : détermine la stratégie de détection utilisée à l'analyse (voir
                // CaptureMode) — sauvegardé avec la vidéo, modifiable seulement avant d'enregistrer.
                Picker("Mode", selection: $capture.captureMode) {
                    ForEach(CaptureMode.allCases) { option in
                        Label(option.label, systemImage: option.systemImage).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .padding(8)
                .background(.black.opacity(0.4))
                .clipShape(Capsule())
                .disabled(capture.isRecording)
                .padding(.bottom, 16)

                // Bouton en forme de soucoupe volante
                Button(action: { capture.toggleRecording() }) {
                    SaucerButtonShape(isRecording: capture.isRecording)
                        .frame(width: 110, height: 60)
                }
                .padding(.bottom, 16)

                Button {
                    showRecordings = true
                } label: {
                    Label("Mes enregistrements", systemImage: "film.stack")
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.5))
                        .foregroundColor(.green)
                        .clipShape(Capsule())
                }
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            // Démarrage automatique : suivi ARKit + résolution vidéo HD
            capture.configureARTracking()
            capture.configureHDVideo()
        }
        .sheet(isPresented: $showRecordings) {
            RecordingsListView(isPresented: $showRecordings)
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
