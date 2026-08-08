// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI
import UIKit

/// Rend l'écran de résultats complet (`ResultsView.resultsContent` : photos, mesures, cartes,
/// verdict) en une seule image, pour la sauvegarder dans Photos à la suite des 3 photos recadrées —
/// demande explicite de Jean-David : « à la fin de l'analyse, fais capture d'écran et sauvegarde
/// dans la bibliothèque toute l'analyse avec la carte géographique et tous les résultats ».
///
/// Héberge brièvement la vue dans une fenêtre réelle hors écran (pas seulement `ImageRenderer` seul) :
/// la carte MapKit incluse dans `resultsContent` a besoin d'être posée dans une vraie fenêtre pour
/// charger ses tuiles avant d'être capturée, sinon le rendu produit une carte vide. `resultsContent`
/// est un simple `VStack` (pas de `ScrollView`), donc sa hauteur intrinsèque est bien définie et peut
/// être mesurée via Auto Layout plutôt que devinée.
@MainActor
enum ResultsScreenshotRenderer {
    static func render(session: AnalysisSession) async -> CGImage? {
        let width: CGFloat = 1080

        let hostingController = UIHostingController(
            rootView: ResultsView(session: session).resultsContent
                .frame(width: width)
                .background(Color.black)
                .preferredColorScheme(.dark)
        )
        hostingController.view.backgroundColor = .black

        // Fenêtre réelle mais hors écran (à gauche de l'écran visible) — nécessaire pour que MapKit
        // charge ses tuiles ; une vue jamais posée dans une fenêtre produirait une carte vide.
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
                ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        else { return nil }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: -width - 200, y: 0, width: width, height: 200)
        window.rootViewController = hostingController
        window.isHidden = false

        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        let fittingSize = hostingController.view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let height = max(fittingSize.height, 200)
        window.frame = CGRect(x: -width - 200, y: 0, width: width, height: height)
        hostingController.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        hostingController.view.layoutIfNeeded()

        // Laisse une courte fenêtre de temps pour que MapKit charge ses tuiles réseau avant capture.
        try? await Task.sleep(nanoseconds: 500_000_000)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { _ in
            hostingController.view.drawHierarchy(in: CGRect(x: 0, y: 0, width: width, height: height), afterScreenUpdates: true)
        }

        window.isHidden = true
        window.rootViewController = nil

        return image.cgImage
    }
}
