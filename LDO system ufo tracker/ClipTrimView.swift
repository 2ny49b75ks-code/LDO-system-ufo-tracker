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
    /// `CGPoint?` : point touché par l'utilisateur pour indiquer l'objet à analyser (repère Vision,
    /// normalisé 0...1, origine bas-gauche) — `nil` s'il n'a touché nulle part, la détection reste
    /// alors entièrement automatique comme avant.
    let onConfirm: (ClosedRange<Double>?, CaptureMode, CGPoint?) -> Void

    private let clipDuration: Double = 2.0

    @State private var player: AVPlayer
    @State private var duration: Double = 0
    @State private var clipStart: Double = 0
    @State private var isLoadingDuration = true
    @State private var mode: CaptureMode
    /// Point touché par l'utilisateur dans le repère SwiftUI (origine haut-gauche) du lecteur vidéo —
    /// converti au repère Vision (origine bas-gauche) seulement au moment de `onConfirm`.
    @State private var tappedPoint: CGPoint?

    init(
        videoURL: URL,
        initialMode: CaptureMode,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (ClosedRange<Double>?, CaptureMode, CGPoint?) -> Void
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

            GeometryReader { geo in
                ZStack {
                    VideoPlayer(player: player)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    let x = min(max(value.location.x / geo.size.width, 0), 1)
                                    let y = min(max(value.location.y / geo.size.height, 0), 1)
                                    tappedPoint = CGPoint(x: x, y: y)
                                }
                        )

                    if let tappedPoint {
                        let markerPosition = CGPoint(x: tappedPoint.x * geo.size.width, y: tappedPoint.y * geo.size.height)
                        Circle()
                            .stroke(Color.green, lineWidth: 3)
                            .frame(width: 36, height: 36)
                            .position(markerPosition)
                            .allowsHitTesting(false)
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .position(markerPosition)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 320)
            .cornerRadius(12)
            .padding(.horizontal)

            VStack(spacing: 2) {
                Text(tappedPoint == nil
                     ? "Touchez l'objet lumineux dans la vidéo pour aider l'analyse (optionnel)"
                     : "Point indiqué — l'analyse priorisera cette zone")
                    .font(.caption2)
                    .foregroundColor(tappedPoint == nil ? .secondary : .green)
                if tappedPoint != nil {
                    Button("Retirer le point") { tappedPoint = nil }
                        .font(.caption2)
                }
            }

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
                // SwiftUI (origine haut-gauche) -> Vision (origine bas-gauche) : seule la
                // composante Y s'inverse.
                let visionPoint = tappedPoint.map { CGPoint(x: $0.x, y: 1 - $0.y) }
                onConfirm(duration > clipDuration ? clipStart...(clipStart + clipDuration) : nil, mode, visionPoint)
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
