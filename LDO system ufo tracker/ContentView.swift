// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI

/// Écran d'ouverture de l'application LDO : héberge les deux onglets (sélecteur en haut à droite,
/// voir `AppTopBar`) — LIVE (capture + liste des enregistrements) et Bibliothèque (import +
/// analyse d'une vidéo existante).
struct ContentView: View {
    @EnvironmentObject var recordingStore: RecordingStore
    @StateObject private var capture = CaptureManager()
    @State private var selectedTab: AppTab = .live

    var body: some View {
        Group {
            switch selectedTab {
            case .live:
                LiveTabView(capture: capture, selectedTab: $selectedTab)
            case .library:
                LibraryTabView(selectedTab: $selectedTab)
            }
        }
        .onAppear {
            capture.recordingStore = recordingStore
        }
    }
}
