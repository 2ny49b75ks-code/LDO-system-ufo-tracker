// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI

/// Identifie une vidéo (enregistrée via LIVE, avec pose ARKit optionnelle, ou importée depuis la
/// bibliothèque, sans pose) à analyser — présentée en plein écran depuis l'un ou l'autre onglet.
struct AnalysisTarget: Identifiable {
    let id = UUID()
    let videoURL: URL
    let poses: [PersistedFramePose]
}

/// Enchaîne les 3 étapes de l'analyse d'une vidéo déjà enregistrée, dans une seule présentation
/// plein écran : choix de l'extrait de 2s (`ClipTrimView`), calcul avec progression
/// (`AnalysisProgressView`), puis résultats (`ResultsView`). `onFinished` remonte jusqu'à l'écran
/// de capture — voir la réinitialisation automatique après un cycle complet capture+analyse.
struct AnalysisFlowView: View {
    let videoURL: URL
    let poses: [PersistedFramePose]
    let onFinished: () -> Void

    private enum Step {
        case trimming
        case analyzing
        case results(AnalysisSession)
    }

    @State private var step: Step = .trimming
    @StateObject private var analyzer = SessionAnalyzer()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch step {
            case .trimming:
                ClipTrimView(
                    videoURL: videoURL,
                    onCancel: { dismiss() },
                    onConfirm: { clipRange in
                        step = .analyzing
                        analyzer.analyze(videoURL: videoURL, poses: poses, clipRange: clipRange) { session in
                            step = .results(session)
                        }
                    }
                )
            case .analyzing:
                AnalysisProgressView(analyzer: analyzer)
            case .results(let session):
                ResultsView(session: session, onFinished: onFinished)
            }
        }
    }
}
