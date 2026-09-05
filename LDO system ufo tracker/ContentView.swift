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
        // BUG CORRIGÉ (revue de code du 2026-08-27) : un `switch` dans un `@ViewBuilder` change
        // l'IDENTITÉ structurelle de la vue à chaque bascule — SwiftUI détruit entièrement
        // `LiveTabView` (et son `@State`, dont `zoomAtGestureStart`/`zoomAtButtonDragStart`) en
        // passant à Bibliothèque, puis en recrée une INSTANCE NEUVE au retour sur LIVE, ré-exécutant
        // `.onAppear` (réinitialise le suivi ARKit et redemande le GPS à chaque fois — un aller-retour
        // d'onglet pendant une observation en cours provoque un scintillement caméra visible ET un
        // décalage du zoom : le badge affiche encore le bon niveau (lu directement depuis
        // `capture.zoomFactor`, qui survit), mais le PROCHAIN pincement/glissement repart d'une base
        // remise à 1.0, faisant sauter le zoom au lieu de continuer en douceur. Les deux vues restent
        // maintenant vivantes en permanence (empilées, visibilité par opacité) : ni l'une ni l'autre
        // n'est jamais détruite/recréée par un simple changement d'onglet.
        ZStack {
            LiveTabView(capture: capture, selectedTab: $selectedTab)
                .opacity(selectedTab == .live ? 1 : 0)
                .allowsHitTesting(selectedTab == .live)
            LibraryTabView(selectedTab: $selectedTab)
                .opacity(selectedTab == .library ? 1 : 0)
                .allowsHitTesting(selectedTab == .library)
        }
        .onAppear {
            capture.recordingStore = recordingStore
        }
    }
}
