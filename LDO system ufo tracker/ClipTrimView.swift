// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI
import AVKit
import AVFoundation

/// Étape 1 du flux d'analyse : l'utilisateur choisit les 2 secondes de la vidéo à faire analyser.
/// L'analyse ne porte jamais sur la vidéo entière — seulement sur cet extrait — pour rester rapide
/// et ciblée ; la vidéo complète reste intacte pour la visualisation (voir `AnalysisFlowView`).
struct ClipTrimView: View {
    let videoURL: URL
    let initialMode: CaptureMode
    let onCancel: () -> Void
    let onConfirm: (ClosedRange<Double>?, CaptureMode) -> Void

    private let clipDuration: Double = 2.0

    @State private var player: AVPlayer
    @State private var duration: Double = 0
    @State private var clipStart: Double = 0
    @State private var isLoadingDuration = true
    @State private var mode: CaptureMode

    init(
        videoURL: URL,
        initialMode: CaptureMode,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (ClosedRange<Double>?, CaptureMode) -> Void
    ) {
        self.videoURL = videoURL
        self.initialMode = initialMode
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _player = State(initialValue: AVPlayer(url: videoURL))
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)

            Text("Choisissez les 2 secondes à analyser")
                .font(.headline)
                .foregroundColor(.white)
            Text("La vidéo complète reste disponible telle quelle — seul cet extrait sert au calcul.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            VideoPlayer(player: player)
                .frame(height: 320)
                .cornerRadius(12)
                .padding(.horizontal)

            VStack(spacing: 6) {
                Text("Conditions de la vidéo")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("Mode", selection: $mode) {
                    ForEach(CaptureMode.allCases) { option in
                        Label(option.label, systemImage: option.systemImage).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 60)
                Text(mode == .night
                     ? "Ciel sombre avec un point lumineux — détection par luminosité en priorité."
                     : "Scène normalement éclairée (jour, intérieur) — détection par mouvement.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }

            if isLoadingDuration {
                ProgressView()
                    .tint(.green)
            } else if duration > clipDuration {
                VStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { clipStart },
                            set: { newValue in
                                clipStart = newValue
                                seekPreview()
                            }
                        ),
                        in: 0...(duration - clipDuration)
                    )
                    .tint(.green)
                    Text(String(format: "Extrait : %.1fs – %.1fs (vidéo : %.1fs)", clipStart, clipStart + clipDuration, duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 30)
            } else if duration > 0 {
                Text("Vidéo trop courte pour choisir un extrait — les \(String(format: "%.1f", duration))s seront analysées en entier.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Button {
                onConfirm(duration > clipDuration ? clipStart...(clipStart + clipDuration) : nil, mode)
            } label: {
                Text("Analyser cet extrait")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .padding(.horizontal, 40)
            .disabled(isLoadingDuration)

            Spacer()
        }
        .padding(.top, 12)
        .background(Color.black.ignoresSafeArea())
        .task {
            let asset = AVURLAsset(url: videoURL)
            let seconds = (try? await asset.load(.duration).seconds) ?? 0
            duration = seconds.isFinite ? seconds : 0
            isLoadingDuration = false
        }
    }

    private func seekPreview() {
        player.pause()
        player.seek(to: CMTime(seconds: clipStart, preferredTimescale: 600))
    }
}
