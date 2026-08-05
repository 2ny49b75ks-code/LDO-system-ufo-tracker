// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI

/// Affiche la progression réelle du calcul (par étape terminée, voir `AnalysisEngine.analyze`),
/// plutôt qu'une simple estimation de durée qu'il n'est pas possible de calibrer sans mesure sur
/// un appareil physique.
struct AnalysisProgressView: View {
    @ObservedObject var analyzer: SessionAnalyzer

    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: analyzer.progress)
                .progressViewStyle(.linear)
                .tint(.green)
                .frame(width: 220)
            Text(analyzer.progressLabel)
                .foregroundColor(.green)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Text("\(Int(analyzer.progress * 100)) %")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(30)
        .background(.black.opacity(0.85))
        .cornerRadius(16)
    }
}

/// Identifie une vidéo (enregistrée via LIVE, avec pose ARKit optionnelle, ou importée depuis la
/// bibliothèque, sans pose) à analyser — présentée en plein écran depuis l'un ou l'autre onglet.
struct AnalysisTarget: Identifiable {
    let id = UUID()
    let videoURL: URL
    let poses: [PersistedFramePose]
}

/// Lance l'analyse dès l'apparition, affiche la progression, puis les résultats une fois terminée.
struct VideoAnalysisFlow: View {
    let videoURL: URL
    let poses: [PersistedFramePose]

    @StateObject private var analyzer = SessionAnalyzer()
    @State private var result: AnalysisSession?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let result {
                ResultsView(session: result)
            } else {
                AnalysisProgressView(analyzer: analyzer)
            }
        }
        .onAppear {
            guard result == nil, !analyzer.isAnalyzing else { return }
            analyzer.analyze(videoURL: videoURL, poses: poses) { session in
                result = session
            }
        }
    }
}
