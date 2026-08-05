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
