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
    /// Zoom au début du geste de pincement en cours, pour calculer le zoom cumulé sans à-coup
    /// (voir le `MagnificationGesture` ci-dessous).
    @State private var zoomAtGestureStart: CGFloat = 1.0
    /// Réticule de ciblage — voir `TargetReticleOverlay`. `targetCenter`/`targetRadius` sont en points,
    /// repère local de l'écran (origine haut-gauche) ; convertis en repère Vision normalisé et
    /// transmis à `capture` (voir `CaptureManager.targetHintPoint`/`targetHintRadius`) pour être
    /// persistés avec l'enregistrement et utilisés par défaut à l'analyse — demande explicite de
    /// Jean-David (2026-09-11) : « toucher la cible à l'écran... en mode capture et en mode analyse ».
    @State private var targetCenter: CGPoint?
    @State private var targetRadius: CGFloat = 60

    var body: some View {
        ZStack {
            CameraPreviewView(session: capture.session, zoomFactor: capture.zoomFactor)
                .ignoresSafeArea()
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let candidate = zoomAtGestureStart * value
                            capture.zoomFactor = min(max(candidate, CaptureManager.minZoomFactor), CaptureManager.maxZoomFactor)
                        }
                        .onEnded { _ in
                            zoomAtGestureStart = capture.zoomFactor
                        }
                )

            // Cadre mauve autour du viseur — demande explicite de Jean-David (2026-08-25, ajustée
            // 2026-08-07) : toujours visible dans la section capture (avant ET pendant
            // l'enregistrement), pas seulement pendant, et à la couleur mauve exacte de la marque LDO
            // (--nebula-light du site web) plutôt que le mauve système générique. `allowsHitTesting
            // (false)` : purement visuel, ne doit jamais intercepter les gestes de zoom/toucher sur le
            // viseur en-dessous.
            RoundedRectangle(cornerRadius: 0)
                .stroke(Color.ldoNebulaLight, lineWidth: 12)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Réticule de ciblage — voir `TargetReticleOverlay` et le commentaire sur `targetCenter`
            // ci-dessus. Toujours actif (avant ET pendant l'enregistrement, comme le cadre mauve),
            // jamais lié au bouton d'enregistrement : toucher l'écran ici ne fait JAMAIS démarrer un
            // enregistrement, seul le bouton soucoupe le fait (voir plus bas).
            GeometryReader { geo in
                TargetReticleOverlay(center: $targetCenter, radius: $targetRadius, containerSize: geo.size)
                    .onChange(of: targetCenter) {
                        capture.targetHintPoint = TargetReticleOverlay.visionHintPoint(center: targetCenter, containerSize: geo.size)
                        capture.targetHintRadius = TargetReticleOverlay.visionHintRadius(radius: targetRadius, containerSize: geo.size)
                    }
                    .onChange(of: targetRadius) {
                        capture.targetHintRadius = TargetReticleOverlay.visionHintRadius(radius: targetRadius, containerSize: geo.size)
                    }
            }
            .ignoresSafeArea()

            VStack {
                AppTopBar(selectedTab: $selectedTab, trackingActive: capture.trackingActive)

                if capture.zoomFactor > CaptureManager.minZoomFactor {
                    Text(String(format: "%.1f×", capture.zoomFactor))
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5))
                        .clipShape(Capsule())
                        .padding(.top, 8)
                }

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
            // Demande la position GPS dès maintenant plutôt qu'au moment d'appuyer sur enregistrer —
            // voir CaptureManager.warmUpLocation() : lui laisse le temps de se fixer avant qu'un
            // enregistrement court se termine.
            capture.warmUpLocation()
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
