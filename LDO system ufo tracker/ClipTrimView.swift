// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI
import AVKit
import AVFoundation

/// Étape 1 du flux d'analyse : l'utilisateur choisit les 5 secondes de la vidéo à faire analyser
/// (durée portée de 2s à 5s le 2026-08-09, demande explicite de Jean-David sur l'analyse d'une
/// vidéo de bibliothèque — 2s coupait trop souvent l'avion en plein mouvement). L'analyse ne porte
/// jamais sur la vidéo entière — seulement sur cet extrait — pour rester rapide et ciblée ; la vidéo
/// complète reste intacte pour la visualisation (voir `AnalysisFlowView`).
struct ClipTrimView: View {
    let videoURL: URL
    let initialMode: CaptureMode
    let onCancel: () -> Void
    /// `CGPoint?` : point touché par l'utilisateur pour indiquer l'objet à analyser (repère Vision,
    /// normalisé 0...1, origine bas-gauche) — `nil` s'il n'a touché nulle part, la détection reste
    /// alors entièrement automatique comme avant.
    let onConfirm: (ClosedRange<Double>?, CaptureMode, CGPoint?) -> Void

    private let clipDuration: Double = 5.0

    @State private var player: AVPlayer
    @State private var duration: Double = 0
    @State private var clipStart: Double = 0
    @State private var isLoadingDuration = true
    @State private var mode: CaptureMode
    /// Images miniatures réparties sur toute la durée de l'enregistrement — pour visualiser les
    /// parties de la vidéo disponibles avant de choisir l'extrait à analyser (demande explicite de
    /// Jean-David, Mode LIVE). Générées une fois la durée connue, voir `generateFilmstrip`.
    @State private var filmstripThumbnails: [UIImage] = []
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

            Text("Choisissez les 5 secondes à analyser")
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
                    if !filmstripThumbnails.isEmpty {
                        FilmstripView(
                            thumbnails: filmstripThumbnails,
                            duration: duration,
                            clipStart: clipStart,
                            clipDuration: clipDuration
                        ) { newStart in
                            clipStart = newStart
                            seekPreview()
                        }
                        .frame(height: 56)
                        .padding(.horizontal, 30)
                    }
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
            if duration > 0 {
                filmstripThumbnails = await Self.generateFilmstrip(videoURL: videoURL, duration: duration)
            }
        }
    }

    private func seekPreview() {
        player.pause()
        player.seek(to: CMTime(seconds: clipStart, preferredTimescale: 600))
    }

    /// Génère des miniatures réparties uniformément sur toute la vidéo, pour donner un aperçu visuel
    /// de l'enregistrement complet avant de choisir les 5 secondes à analyser.
    private static func generateFilmstrip(videoURL: URL, duration: Double, count: Int = 10) async -> [UIImage] {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)

        let times = (0..<count).map { i in
            CMTime(seconds: duration * Double(i) / Double(max(count - 1, 1)), preferredTimescale: 600)
        }

        var images: [UIImage] = []
        do {
            for try await result in generator.images(for: times) {
                if case let .success(_, cgImage, _) = result {
                    images.append(UIImage(cgImage: cgImage))
                }
            }
        } catch {
            // Dégradation silencieuse : sans miniatures, le curseur de sélection ci-dessus reste
            // pleinement fonctionnel, seul l'aperçu visuel supplémentaire est absent.
        }
        return images
    }
}

/// Bandeau de miniatures représentant toute la vidéo enregistrée, avec un cadre vert indiquant
/// l'extrait de 5 secondes actuellement sélectionné — permet de visualiser en un coup d'œil les
/// parties de la vidéo disponibles avant de choisir laquelle faire analyser. Touche/glisse
/// directement sur le bandeau pour déplacer la sélection, en plus du curseur ci-dessous.
private struct FilmstripView: View {
    let thumbnails: [UIImage]
    let duration: Double
    let clipStart: Double
    let clipDuration: Double
    let onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                HStack(spacing: 1) {
                    ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, thumbnail in
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width / CGFloat(thumbnails.count))
                            .clipped()
                    }
                }
                .cornerRadius(8)

                let selectionWidth = min(CGFloat(clipDuration / duration) * geo.size.width, geo.size.width)
                let selectionX = min(CGFloat(clipStart / duration) * geo.size.width, geo.size.width - selectionWidth)
                Rectangle()
                    .stroke(Color.green, lineWidth: 3)
                    .background(Color.green.opacity(0.15))
                    .frame(width: max(selectionWidth, 4), height: geo.size.height)
                    .offset(x: selectionX)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        let newStart = min(max(fraction * duration - clipDuration / 2, 0), duration - clipDuration)
                        onScrub(newStart)
                    }
            )
        }
    }
}
