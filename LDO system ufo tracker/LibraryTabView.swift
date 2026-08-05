// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Onglet Bibliothèque : importe une vidéo déjà présente dans la photothèque (bouton « + ») et
/// l'analyse avec le même pipeline que l'onglet LIVE. `PhotosPicker` ne demande aucune permission
/// de lecture de la photothèque (accès limité au fichier explicitement choisi par l'utilisateur).
///
/// Sans pose ARKit (cette vidéo n'a jamais été filmée en direct par LDO), la distance/altitude et
/// la trajectoire réelle sont moins précises — voir la dégradation gracieuse déjà prévue dans
/// `TrajectoryCalculator`/`DistanceEstimator` pour les images sans `cameraTransform`/`intrinsics`.
struct LibraryTabView: View {
    @Binding var selectedTab: AppTab
    @State private var pickerItem: PhotosPickerItem?
    @State private var analysisTarget: AnalysisTarget?
    @State private var isImporting = false
    @State private var importErrorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                AppTopBar(selectedTab: $selectedTab)

                Spacer()

                VStack(spacing: 20) {
                    Image(systemName: "film")
                        .font(.system(size: 56))
                        .foregroundColor(.green)

                    Text("Analyser une vidéo de votre bibliothèque")
                        .foregroundColor(.white)
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    Text("Distance et altitude moins précises qu'un enregistrement LIVE (position de la caméra non disponible pour une vidéo déjà filmée).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    if isImporting {
                        ProgressView("Importation…")
                            .tint(.green)
                            .foregroundColor(.white)
                    } else {
                        PhotosPicker(selection: $pickerItem, matching: .videos) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 64))
                                .foregroundColor(.green)
                        }
                    }

                    if let importErrorMessage {
                        Text(importErrorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                }

                Spacer()
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            importErrorMessage = nil
            isImporting = true
            Task {
                await importVideo(newItem)
                isImporting = false
                pickerItem = nil
            }
        }
        .fullScreenCover(item: $analysisTarget) { target in
            AnalysisFlowView(videoURL: target.videoURL, poses: target.poses) {
                // « Nouvelle capture » : referme le flux d'analyse et réinitialise l'état
                // d'importation, prêt pour une prochaine vidéo.
                analysisTarget = nil
                pickerItem = nil
                importErrorMessage = nil
            }
        }
    }

    private func importVideo(_ item: PhotosPickerItem) async {
        do {
            guard let movie = try await item.loadTransferable(type: MovieFile.self) else {
                importErrorMessage = "Impossible de lire cette vidéo."
                return
            }
            analysisTarget = AnalysisTarget(videoURL: movie.url, poses: [])
        } catch {
            importErrorMessage = "Échec de l'importation : \(error.localizedDescription)"
        }
    }
}

/// Copie la vidéo choisie dans un fichier temporaire propre à l'app, sans charger tout son
/// contenu en mémoire (contrairement à un simple `loadTransferable(type: Data.self)`).
private struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}
