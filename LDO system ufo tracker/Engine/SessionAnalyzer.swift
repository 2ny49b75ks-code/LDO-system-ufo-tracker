// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import Combine

/// Orchestre l'analyse d'une vidéo déjà enregistrée (onglet LIVE, avec pose ARKit) ou importée
/// depuis la bibliothèque (sans pose), avec progression publiée pour l'affichage SwiftUI —
/// contrairement à la capture en direct, cette analyse est déclenchée manuellement par
/// l'utilisateur (voir la demande : « sélectionner sa vidéo et faire analyser »).
@MainActor
final class SessionAnalyzer: ObservableObject {
    @Published private(set) var isAnalyzing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressLabel: String = ""

    func analyze(videoURL: URL, poses: [PersistedFramePose] = [], completion: @escaping (AnalysisSession) -> Void) {
        isAnalyzing = true
        progress = 0
        progressLabel = "Préparation de la vidéo…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let frames = VideoFrameExtractor.extractFrames(from: videoURL, poses: poses)

            let result = AnalysisEngine().analyze(frames: frames, videoURL: videoURL) { fraction, label in
                DispatchQueue.main.async {
                    self?.progress = fraction
                    self?.progressLabel = label
                }
            }

            PhotoLibrarySaver.savePhotos(result.photosWithOverlays)

            DispatchQueue.main.async {
                self?.isAnalyzing = false
                completion(result)
            }
        }
    }
}
