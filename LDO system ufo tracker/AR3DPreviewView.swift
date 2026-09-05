// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI
import QuickLook

/// Affiche un modèle `.usdz` via Quick Look — bouton « Réalité augmentée » (voir l'objet dans le
/// monde réel via la caméra) et bouton de partage (partager/enregistrer dans Fichiers) déjà fournis
/// nativement par Quick Look pour ce type de fichier, sans code supplémentaire à écrire. Demande
/// explicite de Jean-David (2026-08-27) : « bouton voir rendu 3D... en réalité augmentée et le
/// sauvegarder au besoin » + « partager le rendu 3D ».
struct AR3DPreviewView: UIViewControllerRepresentable {
    let modelURL: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(modelURL: modelURL)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let modelURL: URL
        init(modelURL: URL) { self.modelURL = modelURL }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            modelURL as NSURL
        }
    }
}
