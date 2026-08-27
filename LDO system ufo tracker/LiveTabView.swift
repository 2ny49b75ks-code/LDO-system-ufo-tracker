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
    /// Même principe que `zoomAtGestureStart` ci-dessus, mais pour le bouton de zoom vertical dédié
    /// sur le bord droit de l'écran (voir `verticalZoomControl`) — geste indépendant du pincement.
    @State private var zoomAtButtonDragStart: CGFloat = 1.0
    /// Hauteur du rail du bouton de zoom vertical — sert à la fois à dessiner le rail et à convertir
    /// le déplacement du doigt en variation de zoom (voir `verticalZoomControl`).
    private let zoomRailHeight: CGFloat = 160

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

            // Bouton de zoom vertical dédié, sur le bord droit de l'écran — demande explicite de
            // Jean-David (2026-08-25) : alternative au pincement, glisser le doigt vers le haut sur ce
            // rail zoome sur la cible, vers le bas dézoome. Coexiste avec le `MagnificationGesture`
            // ci-dessus (les deux modifient le même `capture.zoomFactor`).
            HStack {
                Spacer()
                verticalZoomControl
                    .padding(.trailing, 14)
            }

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

    /// Rail vertical de zoom : glisser vers le haut zoome sur la cible, vers le bas dézoome — la
    /// position du curseur (`thumbOffset`) reflète toujours le niveau de zoom actuel, y compris quand
    /// il change par pincement (les deux gestes partagent `capture.zoomFactor`).
    private var verticalZoomControl: some View {
        let zoomRange = CaptureManager.maxZoomFactor - CaptureManager.minZoomFactor
        let zoomFraction = zoomRange > 0 ? (capture.zoomFactor - CaptureManager.minZoomFactor) / zoomRange : 0
        let thumbOffset = -((zoomFraction - 0.5) * zoomRailHeight)

        // Pas de bornes atteintes -> pas de changement, `step` protège aussi contre un
        // débordement au-delà de min/maxZoomFactor.
        func step(by delta: CGFloat) {
            capture.zoomFactor = min(max(capture.zoomFactor + delta, CaptureManager.minZoomFactor), CaptureManager.maxZoomFactor)
            zoomAtButtonDragStart = capture.zoomFactor
        }

        // BUG CORRIGÉ (2026-08-27, Jean-David : « le bouton zoom est encore non fonctionnel ») : le
        // `DragGesture(minimumDistance: 2)` était attaché à TOUT le contrôle, boutons +/- inclus. Sur
        // un appareil réel, un tapotement du doigt dérive presque toujours de plus de 2pt — le geste
        // de glissement du parent captait donc systématiquement le toucher avant que le tap du bouton
        // ne puisse se déclencher, même si le bouton lui-même était correctement câblé (voir le
        // correctif précédent, insuffisant seul). Le glisser est maintenant limité au SEUL rail
        // (la zone entre les deux boutons), qui reste hors de portée du toucher sur les boutons.
        return VStack(spacing: 10) {
            Button { step(by: 0.5) } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 32, height: 24)
            }

            ZStack(alignment: .center) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 5, height: zoomRailHeight)
                Circle()
                    .fill(Color.ldoSignal)
                    .frame(width: 20, height: 20)
                    .offset(y: thumbOffset)
                    .shadow(color: .black.opacity(0.4), radius: 3)
            }
            .frame(height: zoomRailHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        // Glisser vers le haut (translation négative) augmente le zoom — inverse du
                        // signe de `translation.height` (positif vers le bas en coordonnées SwiftUI).
                        let delta = -value.translation.height / zoomRailHeight * zoomRange
                        let candidate = zoomAtButtonDragStart + delta
                        capture.zoomFactor = min(max(candidate, CaptureManager.minZoomFactor), CaptureManager.maxZoomFactor)
                    }
                    .onEnded { _ in
                        zoomAtButtonDragStart = capture.zoomFactor
                    }
            )

            Button { step(by: -0.5) } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 32, height: 24)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(.black.opacity(0.35))
        .clipShape(Capsule())
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
