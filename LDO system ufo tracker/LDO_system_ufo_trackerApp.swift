//
//  LDO_system_ufo_trackerApp.swift
//  LDO system ufo tracker
//
//  Created by Jean-David Giroux on 2026-07-29.
//

import SwiftUI

@main
struct LDO_system_ufo_trackerApp: App {
    @StateObject private var recordingStore = RecordingStore()
    /// Affiche `SplashView` (logo LDO) pendant 2 secondes à l'ouverture de l'app — demande explicite
    /// de Jean-David (2026-08-09), voir `SplashView`. `false` ensuite pour toute la durée de vie du
    /// processus (pas réaffiché en revenant au premier plan, seulement au lancement).
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                } else {
                    ContentView()
                        .environmentObject(recordingStore)
                        .transition(.opacity)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showSplash = false
                    }
                }
            }
        }
    }
}
