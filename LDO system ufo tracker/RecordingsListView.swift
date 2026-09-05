// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI

/// Liste des vidéos enregistrées via l'onglet LIVE (stockées localement, voir `RecordingStore`).
/// L'enregistrement ne déclenche plus l'analyse automatiquement : on choisit ici quelle vidéo
/// analyser, et le calcul se lance à la demande.
struct RecordingsListView: View {
    /// Contrôlée par `LiveTabView` : permet de refermer cette liste (en plus du flux d'analyse
    /// plein écran) en un seul geste quand l'utilisateur appuie sur « Nouvelle capture », pour
    /// revenir directement à l'écran caméra plutôt que de laisser la liste ouverte en arrière-plan.
    @Binding var isPresented: Bool
    @EnvironmentObject var recordingStore: RecordingStore
    @State private var analysisTarget: AnalysisTarget?

    var body: some View {
        NavigationView {
            List {
                if recordingStore.sessions.isEmpty {
                    Text("Aucun enregistrement pour l'instant. Filmez avec le bouton soucoupe, puis retrouvez la vidéo ici pour l'analyser.")
                        .foregroundColor(.secondary)
                        .font(.footnote)
                }
                ForEach(recordingStore.sessions) { session in
                    Button {
                        analysisTarget = AnalysisTarget(
                            videoURL: recordingStore.videoURL(for: session),
                            poses: recordingStore.poses(for: session),
                            initialMode: session.mode,
                            captureLocation: session.captureCoordinate
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.headline)
                                Label(session.mode.label, systemImage: session.mode.systemImage)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(session.posesFileName != nil ? "Analyser (pose ARKit disponible)" : "Analyser")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    // BUG CORRIGÉ (revue de code du 2026-08-27) : indexer `recordingStore.sessions`
                    // avec l'`IndexSet` d'origine PENDANT qu'on le vide un à un décale les index
                    // restants à chaque suppression — supprimer un ensemble comme {3,4} sur 5 éléments
                    // plantait (« Index out of range ») ou supprimait le mauvais enregistrement. On
                    // résout d'abord tous les enregistrements visés, avant toute suppression.
                    let sessionsToDelete = indexSet.map { recordingStore.sessions[$0] }
                    for session in sessionsToDelete {
                        recordingStore.delete(session)
                    }
                }
            }
            .navigationTitle("Mes enregistrements")
            .toolbar {
                EditButton()
            }
        }
        .fullScreenCover(item: $analysisTarget) { target in
            AnalysisFlowView(videoURL: target.videoURL, poses: target.poses, initialMode: target.initialMode, captureLocation: target.captureLocation) {
                // « Nouvelle capture » : referme le flux d'analyse ET cette liste, pour revenir
                // directement à l'écran caméra prêt à filmer.
                analysisTarget = nil
                isPresented = false
            }
        }
    }
}
