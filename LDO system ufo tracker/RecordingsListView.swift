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
                            poses: recordingStore.poses(for: session)
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.headline)
                            Text(session.posesFileName != nil ? "Analyser (pose ARKit disponible)" : "Analyser")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        recordingStore.delete(recordingStore.sessions[index])
                    }
                }
            }
            .navigationTitle("Mes enregistrements")
            .toolbar {
                EditButton()
            }
        }
        .fullScreenCover(item: $analysisTarget) { target in
            AnalysisFlowView(videoURL: target.videoURL, poses: target.poses) {
                // « Nouvelle capture » : referme le flux d'analyse ET cette liste, pour revenir
                // directement à l'écran caméra prêt à filmer.
                analysisTarget = nil
                isPresented = false
            }
        }
    }
}
