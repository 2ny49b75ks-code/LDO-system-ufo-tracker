// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI
import AVKit
import AVFoundation

/// Étape 1 du flux d'analyse : l'utilisateur choisit les 4 secondes de la vidéo à faire analyser
/// (durée portée de 2s à 5s le 2026-08-09, demande explicite de Jean-David sur l'analyse d'une
/// vidéo de bibliothèque — 2s coupait trop souvent l'avion en plein mouvement — puis ramenée à 4s
/// par précaution supplémentaire après un plantage mémoire, voir `clipDuration` ci-dessous).
/// L'analyse ne porte
/// jamais sur la vidéo entière — seulement sur cet extrait — pour rester rapide et ciblée ; la vidéo
/// complète reste intacte pour la visualisation (voir `AnalysisFlowView`).
struct ClipTrimView: View {
    let videoURL: URL
    let initialMode: CaptureMode
    /// Ciblage déjà désigné en direct sur le réticule de `LiveTabView` (voir `RecordedSession.hintPoint`),
    /// repère Vision normalisé — préremplit le réticule ci-dessous, l'utilisateur peut l'ajuster ou le
    /// retirer avant de lancer l'analyse. `nil` pour une vidéo importée de la bibliothèque.
    var initialHintPoint: CGPoint? = nil
    var initialHintRadius: CGFloat? = nil
    let onCancel: () -> Void
    /// `CGPoint?`/`CGFloat?` : point + rayon désignés par l'utilisateur pour indiquer l'objet à
    /// analyser (repère Vision, normalisé 0...1, origine bas-gauche) — `nil` s'il n'a rien désigné, la
    /// détection reste alors entièrement automatique comme avant.
    let onConfirm: (ClosedRange<Double>?, CaptureMode, CGPoint?, CGFloat?) -> Void

    // Réduit de 5s à 4s (2026-08-09, demande de Jean-David par précaution supplémentaire après un
    // plantage en analysant une vidéo de bibliothèque réelle en 4K) — marge de sécurité additionnelle
    // sur la mémoire au-delà du plafond de résolution des images ajouté dans VideoFrameExtractor
    // (cause probable principale : images extraites en pleine résolution source, pas la durée elle-même).
    private let clipDuration: Double = 4.0

    @State private var player: AVPlayer
    @State private var duration: Double = 0
    @State private var clipStart: Double = 0
    @State private var isLoadingDuration = true
    @State private var mode: CaptureMode
    /// Images miniatures réparties sur toute la durée de l'enregistrement — pour visualiser les
    /// parties de la vidéo disponibles avant de choisir l'extrait à analyser (demande explicite de
    /// Jean-David, Mode LIVE). Générées une fois la durée connue, voir `generateFilmstrip`.
    @State private var filmstripThumbnails: [UIImage] = []
    /// Centre/rayon du réticule de ciblage (voir `TargetReticleOverlay`), repère SwiftUI local (origine
    /// haut-gauche) du lecteur vidéo — convertis au repère Vision (origine bas-gauche) normalisé
    /// seulement au moment de `onConfirm`. Préremplis, une fois la taille du lecteur connue (voir
    /// `.onAppear` ci-dessous), à partir de `initialHintPoint`/`initialHintRadius` si fournis.
    @State private var targetCenter: CGPoint?
    @State private var targetRadius: CGFloat = 60
    /// Taille réelle du cadre vidéo, connue seulement à l'affichage (voir `GeometryReader` ci-dessous)
    /// — nécessaire pour convertir `targetCenter`/`targetRadius` en repère Vision au moment d'`onConfirm`.
    @State private var videoContainerSize: CGSize = .zero

    init(
        videoURL: URL,
        initialMode: CaptureMode,
        initialHintPoint: CGPoint? = nil,
        initialHintRadius: CGFloat? = nil,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (ClosedRange<Double>?, CaptureMode, CGPoint?, CGFloat?) -> Void
    ) {
        self.videoURL = videoURL
        self.initialMode = initialMode
        self.initialHintPoint = initialHintPoint
        self.initialHintRadius = initialHintRadius
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

            Text("Choisissez les 4 secondes à analyser")
                .font(.headline)
                .foregroundColor(.white)
            Text("La vidéo complète reste disponible telle quelle — seul cet extrait sert au calcul.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            GeometryReader { geo in
                ZStack {
                    // BUG CORRIGÉ (revue de code du 2026-08-27) : `.gesture()` (priorité exclusive)
                    // avec `minimumDistance: 0` (un simple tap suffit) captait TOUT toucher sur la
                    // vidéo avant qu'AVKit ne puisse afficher ses propres contrôles lecture/pause —
                    // l'utilisateur ne pouvait jamais prévisualiser l'extrait avant de le confirmer,
                    // seul le repère cible bougeait. `TargetReticleOverlay` utilise le même geste
                    // simultané pour laisser les deux coexister.
                    VideoPlayer(player: player)
                        .contentShape(Rectangle())

                    TargetReticleOverlay(center: $targetCenter, radius: $targetRadius, containerSize: geo.size)
                }
                .onAppear {
                    videoContainerSize = geo.size
                    // Préremplit le réticule à partir du ciblage désigné en direct (voir
                    // `RecordedSession.hintPoint`) — seulement possible une fois `geo.size` connu, donc
                    // ici plutôt qu'à l'initialisation de la vue.
                    guard targetCenter == nil, let initialHintPoint else { return }
                    targetCenter = CGPoint(x: initialHintPoint.x * geo.size.width, y: (1 - initialHintPoint.y) * geo.size.height)
                    if let initialHintRadius {
                        targetRadius = initialHintRadius * min(geo.size.width, geo.size.height)
                    }
                }
            }
            .frame(height: 320)
            .cornerRadius(12)
            .padding(.horizontal)

            VStack(spacing: 2) {
                Text(targetCenter == nil
                     ? "Touchez l'objet lumineux dans la vidéo pour cibler la zone à analyser (optionnel)"
                     : "Zone ciblée — l'analyse se concentrera sur cette zone, ajustez la taille avec la poignée")
                    .font(.caption2)
                    .foregroundColor(targetCenter == nil ? .secondary : .green)
                if targetCenter != nil {
                    Button("Retirer le ciblage") { targetCenter = nil }
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
                let visionPoint = TargetReticleOverlay.visionHintPoint(center: targetCenter, containerSize: videoContainerSize)
                let visionRadius = TargetReticleOverlay.visionHintRadius(radius: targetRadius, containerSize: videoContainerSize)
                onConfirm(duration > clipDuration ? clipStart...(clipStart + clipDuration) : nil, mode, visionPoint, visionRadius)
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
    /// de l'enregistrement complet avant de choisir les 4 secondes à analyser.
    private static func generateFilmstrip(videoURL: URL, duration: Double, count: Int = 10) async -> [UIImage] {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)

        let times = (0..<count).map { i in
            CMTime(seconds: duration * Double(i) / Double(max(count - 1, 1)), preferredTimescale: 600)
        }

        // Dégradation silencieuse sur un échec individuel (cas `.failure` ignoré ci-dessous) : sans
        // miniatures, le curseur de sélection ci-dessus reste pleinement fonctionnel, seul l'aperçu
        // visuel supplémentaire est absent. La séquence elle-même ne lance plus d'erreur (les échecs
        // arrivent comme des éléments `.failure`, pas via `throw`), d'où l'absence de `try`/`do-catch`.
        var images: [UIImage] = []
        for await result in generator.images(for: times) {
            if case let .success(_, cgImage, _) = result {
                images.append(UIImage(cgImage: cgImage))
            }
        }
        return images
    }
}

/// Bandeau de miniatures représentant toute la vidéo enregistrée, avec un cadre vert indiquant
/// l'extrait de 4 secondes actuellement sélectionné — permet de visualiser en un coup d'œil les
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
