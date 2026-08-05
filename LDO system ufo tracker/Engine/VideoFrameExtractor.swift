// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import AVFoundation
import CoreGraphics
import simd

/// Reconstruit un tableau de `CapturedFrame` à partir d'un fichier vidéo déjà enregistré (onglet
/// LIVE ou vidéo importée depuis la bibliothèque), en ré-échantillonnant les images à intervalle
/// régulier — contrairement à la capture en direct (`CaptureManager`), on n'a plus le flux ARKit
/// ici, seulement le fichier vidéo final.
///
/// Si `poses` est fourni (vidéo enregistrée via l'onglet LIVE, voir `RecordingStore`), chaque image
/// récupère la pose ARKit la plus proche en temps, ce qui permet une trajectoire/distance de bonne
/// qualité même en ré-analyse différée. Sans pose (vidéo importée depuis la bibliothèque),
/// `cameraTransform`/`intrinsics` restent `nil` — voir la dégradation gracieuse déjà prévue dans
/// `TrajectoryCalculator` et `DistanceEstimator` pour ce cas.
enum VideoFrameExtractor {
    /// `timeRange` restreint l'extraction à un extrait de la vidéo (en secondes depuis le début) —
    /// c'est le mécanisme derrière « choisir les 2 secondes à analyser » (voir `ClipTrimView`) :
    /// on n'échantillonne et n'analyse jamais la vidéo entière, seulement l'extrait choisi. `nil`
    /// couvre la vidéo entière (utilisé uniquement en secours, ex. vidéo trop courte pour 2s).
    static func extractFrames(
        from videoURL: URL,
        poses: [PersistedFramePose] = [],
        timeRange: ClosedRange<Double>? = nil,
        maxFrames: Int = 240
    ) -> [CapturedFrame] {
        let asset = AVURLAsset(url: videoURL)
        guard asset.tracks(withMediaType: .video).first != nil else { return [] }

        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0 else { return [] }

        let startTime = max(0, timeRange?.lowerBound ?? 0)
        let endTime = min(duration, timeRange?.upperBound ?? duration)
        guard endTime > startTime else { return [] }
        let rangeDuration = endTime - startTime

        // Même cadence que la capture en direct (voir CaptureManager.captureIntervalSeconds), sauf
        // pour un extrait plus long que ~20s où l'on espace davantage pour rester sous `maxFrames`
        // (ne devrait normalement pas arriver avec un extrait de 2s).
        let interval = max(1.0 / 12.0, rangeDuration / Double(maxFrames))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var frames: [CapturedFrame] = []
        var t = startTime
        while t < endTime {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                let pose = nearestPose(to: t, in: poses)
                frames.append(CapturedFrame(
                    image: cgImage,
                    cameraTransform: pose.flatMap { simd_float4x4(flatColumns: $0.transform) },
                    intrinsics: pose.flatMap { simd_float3x3(flatColumns: $0.intrinsics) },
                    timestamp: t
                ))
            }
            t += interval
        }
        return frames
    }

    private static func nearestPose(to timestamp: Double, in poses: [PersistedFramePose]) -> PersistedFramePose? {
        guard !poses.isEmpty else { return nil }
        return poses.min { abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp) }
    }
}
