// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI
import ARKit
import SceneKit

/// Affiche en plein écran le flux caméra + AR d'une `ARSession` déjà démarrée ailleurs
/// (voir `CaptureManager.configureARTracking()`), sans créer ni gérer sa propre session.
///
/// Utilise `ARSCNView` plutôt que `ARView` (RealityKit) car le reste du pipeline LDO
/// (voir `ShapeClassifier.buildApproximate3DSilhouette`) prévoit un usage ultérieur de
/// RealityKit séparément — on garde donc ici la vue la plus légère possible, uniquement
/// pour l'aperçu caméra.
struct CameraPreviewView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        // Ne PAS appeler view.session.run(...) ici : la session est démarrée et configurée
        // par CaptureManager — cette vue ne fait qu'afficher la session existante, pour éviter
        // de la redémarrer avec une config par défaut.
        view.session = session
        view.automaticallyUpdatesLighting = true
        // Pas de visualisation de debug AR par défaut : LDO affiche son propre overlay
        // (trajectoire rouge, incrustations) via OverlayRenderer.
        view.debugOptions = []
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // Rien à mettre à jour dynamiquement : CaptureManager pilote la session directement.
    }
}
