// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import Combine
import CoreGraphics

/// Orchestre l'analyse d'une vidéo déjà enregistrée (onglet LIVE, avec pose ARKit) ou importée
/// depuis la bibliothèque (sans pose), avec progression publiée pour l'affichage SwiftUI —
/// contrairement à la capture en direct, cette analyse est déclenchée manuellement par
/// l'utilisateur (voir la demande : « sélectionner sa vidéo et faire analyser »).
@MainActor
final class SessionAnalyzer: ObservableObject {
    @Published private(set) var isAnalyzing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressLabel: String = ""

    /// `clipRange` : extrait de 4 secondes choisi par l'utilisateur (voir `ClipTrimView`) — seul cet
    /// extrait est échantillonné et analysé, jamais la vidéo entière (voir `VideoFrameExtractor`).
    /// La vidéo complète, elle, reste intacte pour la visualisation (`videoURLWithOverlays`).
    /// `mode` : choix Nuit/Jour de l'utilisateur, transmis tel quel à `AnalysisEngine`.
    func analyze(
        videoURL: URL,
        poses: [PersistedFramePose] = [],
        clipRange: ClosedRange<Double>? = nil,
        mode: CaptureMode,
        captureLocation: CLCoordinate? = nil,
        hintPoint: CGPoint? = nil,
        completion: @escaping (AnalysisSession) -> Void
    ) {
        isAnalyzing = true
        progress = 0
        progressLabel = "Préparation de la vidéo…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let frames = VideoFrameExtractor.extractFrames(from: videoURL, poses: poses, timeRange: clipRange)

            var result = AnalysisEngine().analyze(frames: frames, videoURL: videoURL, mode: mode, captureLocation: captureLocation, hintPoint: hintPoint) { fraction, label in
                DispatchQueue.main.async {
                    self?.progress = fraction
                    self?.progressLabel = label
                }
            }

            // Attend explicitement la confirmation de sauvegarde (au lieu d'un simple « fire and
            // forget ») pour pouvoir prévenir l'utilisateur si ça échoue — une permission Photos
            // refusée échouait auparavant en silence (seul un log #if DEBUG, invisible en TestFlight).
            let photoSaveSemaphore = DispatchSemaphore(value: 0)
            // Défaut à `false` (pas `true`) : si le délai de 15s expire avant la confirmation de
            // PhotoLibrarySaver (première demande de permission Photos lente à répondre, par ex.),
            // on veut que ça compte comme un échec visible plutôt qu'un faux succès silencieux.
            var photosSaved = false
            PhotoLibrarySaver.savePhotos(result.photosWithOverlays) { success in
                photosSaved = success
                photoSaveSemaphore.signal()
            }
            _ = photoSaveSemaphore.wait(timeout: .now() + 15)
            result.photosSavedToLibrary = photosSaved

            // Copie aussi le résultat vidéo (avec incrustations) dans Photos — seulement si l'export
            // a réellement produit un nouveau fichier distinct de la vidéo source. Si l'export a
            // échoué, `videoURLWithOverlays` retombe sur `videoURL` lui-même (déjà dans Photos pour
            // un enregistrement LIVE, ou déjà dans la bibliothèque pour un import) : le sauvegarder
            // à nouveau créerait un doublon inutile.
            if let overlaidVideoURL = result.videoURLWithOverlays, overlaidVideoURL != videoURL {
                PhotoLibrarySaver.saveVideo(at: overlaidVideoURL)
            }

            DispatchQueue.main.async {
                // BUG CORRIGÉ (revue de code du 2026-08-27) : `completion`/la capture d'écran
                // ci-dessous s'exécutaient sans condition même si `self` (donc l'écran qui a lancé
                // l'analyse) avait déjà disparu — pipeline de 35s+ (extraction, analyse complète,
                // sémaphores son/Photos) largement le temps qu'un utilisateur quitte l'écran avant la
                // fin. Risquait de rejouer le bug déjà corrigé une fois (rendu MapKit hors-écran en
                // concurrence avec le rendu à l'écran) ou d'invoquer une navigation obsolète.
                guard let self else { return }
                self.isAnalyzing = false
                completion(result)

                // Capture d'écran de l'écran de résultats complet (mesures, cartes, verdict) —
                // sauvegardée dans Photos À LA SUITE des 3 photos ci-dessus, demande explicite de
                // Jean-David. Faite APRÈS `completion(result)` (donc après que ResultsView soit déjà
                // affichée à l'écran), délibérément : un rendu hors-écran d'une DEUXIÈME copie de la
                // même carte MapKit juste avant l'affichage réel s'est avéré interférer avec le
                // rendu de la carte réelle à l'écran (carte manquante signalée par Jean-David sur un
                // build précédent) — les deux rendus ne se chevauchent donc plus dans le temps.
                Task { @MainActor in
                    guard let screenshot = await ResultsScreenshotRenderer.render(session: result) else { return }
                    PhotoLibrarySaver.savePhotos([screenshot])
                }
            }
        }
    }
}
