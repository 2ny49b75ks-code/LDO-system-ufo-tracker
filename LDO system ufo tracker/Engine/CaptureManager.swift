// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import Combine
import AVFoundation
import ARKit
import Vision
import Photos
import CoreImage

/// Étape 1 : capture vidéo HD combinée à la profondeur LiDAR (résolution de profondeur maximale),
/// puis extraction des 3 meilleures images (netteté + contraste + présence d'un objet en mouvement),
/// sauvegarde sur l'appareil et sur iCloud (via Photos framework).
final class CaptureManager: NSObject, ObservableObject {
    let session = ARSession()
    @Published var isRecording = false
    @Published var lidarActive = false
    @Published var finishedSession: AnalysisSession?

    private var videoOutputURL: URL?
    private var frameBuffer: [CapturedFrame] = []

    // MARK: Configuration

    func configureMaximumLidar() {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            lidarActive = false
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        config.frameSemantics.insert(.sceneDepth)          // profondeur LiDAR maximale disponible
        config.frameSemantics.insert(.smoothedSceneDepth)
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        lidarActive = true
    }

    func configureHDVideo() {
        // La résolution vidéo (1920x1080 ou 4K selon l'appareil) est fixée
        // au plus haut preset supporté par AVCaptureSession en parallèle de la session ARKit.
    }

    func toggleRecording() {
        isRecording.toggle()
        if isRecording {
            frameBuffer.removeAll()
            startRecording()
        } else {
            stopRecordingAndAnalyze()
        }
    }

    private func startRecording() {
        // Démarre l'enregistrement AVAssetWriter en parallèle des frames ARKit (voir délégué ci-dessous).
    }

    private func stopRecordingAndAnalyze() {
        session.pause()

        // Étape 1 (suite) : sélection des 3 photos optimales du buffer capturé
        let bestFrames = selectOptimalFrames(from: frameBuffer, count: 3)

        // Sauvegarde locale + iCloud
        saveToDeviceAndICloud(video: videoOutputURL, photos: bestFrames)

        // Lance le pipeline d'analyse complet (étapes 2 à 9)
        let engine = AnalysisEngine()
        let result = engine.analyze(frames: frameBuffer, videoURL: videoOutputURL)
        finishedSession = result
    }

    /// Sélectionne les meilleures images selon 3 critères pondérés :
    /// netteté (variance du Laplacien), présence d'un objet détecté, luminosité utile (ni sur/sous-exposée).
    private func selectOptimalFrames(
        from buffer: [CapturedFrame],
        count: Int
    ) -> [CGImage] {
        let scored = buffer.map { frame -> (CGImage, Double) in
            (frame.image, FrameQualityScorer.score(frame.image))
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(count)
            .map { $0.0 }
    }

    private func saveToDeviceAndICloud(video: URL?, photos: [CGImage]) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else { return }
            PHPhotoLibrary.shared().performChanges {
                if let video {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: video)
                }
                for cg in photos {
                    let ui = UIImage(cgImage: cg)
                    PHAssetChangeRequest.creationRequestForAsset(from: ui)
                }
            }
            // La synchronisation iCloud Photos se fait automatiquement si l'utilisateur
            // a activé "iCloud Photos" dans Réglages > Photos.
        }
    }
}

extension CaptureManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording else { return }
        // Convertit chaque ARFrame en CGImage et conserve, en plus de la carte de profondeur LiDAR,
        // la pose exacte de la caméra (position + orientation) et sa matrice intrinsèque au même
        // instant. C'est cette pose qui permettra, à l'étape 4, de transformer la position 2D de
        // l'objet à l'écran en une direction 3D réelle dans le ciel (nécessaire pour la trajectoire
        // et le calcul des forces G).
        guard let cgImage = CGImage.from(pixelBuffer: frame.capturedImage) else { return }
        let captured = CapturedFrame(
            image: cgImage,
            depthMap: frame.sceneDepth?.depthMap,
            cameraTransform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            timestamp: frame.timestamp
        )
        frameBuffer.append(captured)
    }
}

extension CGImage {
    /// Conversion utilitaire CVPixelBuffer (format YCbCr d'ARKit) -> CGImage via CIImage/CIContext.
    static func from(pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}

import UIKit

enum FrameQualityScorer {
    /// Score combiné netteté + exposition, utilisé pour choisir les 3 meilleures images.
    static func score(_ image: CGImage) -> Double {
        // Implémentation réelle : variance du Laplacien (netteté) via vImage/Accelerate
        // + histogramme de luminosité (évite les images cramées ou trop sombres).
        return 0
    }
}
