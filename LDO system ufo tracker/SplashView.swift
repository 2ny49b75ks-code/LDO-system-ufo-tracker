// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI

/// Écran de démarrage : logo LDO en plein écran pendant 2 secondes à l'ouverture de l'app —
/// demande explicite de Jean-David (2026-08-09). Affiché une seule fois par lancement de l'app
/// (pas à chaque changement d'onglet), voir `LDO_system_ufo_trackerApp`.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280)
                .clipShape(RoundedRectangle(cornerRadius: 48, style: .continuous))
        }
    }
}
