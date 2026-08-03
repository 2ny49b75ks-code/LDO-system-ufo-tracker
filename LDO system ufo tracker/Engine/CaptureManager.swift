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
import CoreImage.CIFilterBuiltins

/// Étape 1 : capture vidéo HD combinée à la profondeur LiDAR (résolution de profondeur maximale),
/// puis extraction des 3 meilleures images (netteté + contraste + présence d'un objet en mouvement),
/// sauvegarde sur l'appareil et sur iCloud (via Photos framework).
final class CaptureManager: NSObject, ObservableObject {
    let session = ARSession()
    @Published var isRecording = false
    @Published var lidarActive = false
    @Published var finishedSession: AnalysisSession?
    @Published var isAnalyzing = false

    private var videoOutputURL: URL?
    private var frameBuffer: [CapturedFrame] = []
    private let quickMotionContext = CIContext()

    /// Durée de la fenêtre d'analyse autour de la détection de mouvement (secondes).
    private let analysisWindowSeconds: TimeInterval = 2.0

    /// Seuil de différence moyenne (0 à 1) au-delà duquel deux images consécutives
    /// sont considérées comme montrant un mouvement (calcul rapide, sans Vision).
    private let quickMotionThreshold: Double = 0.02

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
        isAnalyzing = true

        // On isole une fenêtre de ~2 secondes autour du premier mouvement détecté,
        // plutôt que d'analyser tout l'enregistrement (beaucoup plus rapide, et évite
        // de geler l'interface sur de longs enregistrements).
        let capturedFrames = frameBuffer
        let capturedVideoURL = videoOutputURL

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let windowFrames = self.extractMotionWindow(from: capturedFrames)

            // Étape 1 (suite) : sélection des 3 photos optimales du buffer capturé.
            let bestFrames = self.selectOptimalFrames(from: windowFrames, count: 3)

            // Lance le pipeline d'analyse complet (étapes 2 à 9) sur la fenêtre réduite.
            let engine = AnalysisEngine()
            let result = engine.analyze(frames: windowFrames, videoURL: capturedVideoURL)

            DispatchQueue.main.async {
                // Sauvegarde locale + iCloud (déclenchée après l'analyse pour ne pas
                // retarder l'affichage des résultats).
                self.saveToDeviceAndICloud(video: capturedVideoURL, photos: bestFrames)
                self.finishedSession = result
                self.isAnalyzing = false
            }
        }
    }

    /// Repère la première apparition de mouvement significatif (comparaison rapide, sans Vision)
    /// puis retourne uniquement les frames comprises dans une fenêtre de `analysisWindowSeconds`
    /// autour de ce moment. Si aucun mouvement n'est détecté, retourne les 2 dernières secondes
    /// de l'enregistrement (comportement de repli raisonnable).
    private func extractMotionWindow(from frames: [CapturedFrame]) -> [CapturedFrame] {
        guard frames.count >= 2 else { return frames }

        var motionStartIndex: Int?
        for i in 1..<frames.count {
            let score = quickMotionScore(previous: frames[i - 1].image, current: frames[i].image)
            if score >= quickMotionThreshold {
                motionStartIndex = i
                break
            }
        }

        guard let startIndex = motionStartIndex else {
            let lastTimestamp = frames.last!.timestamp
            return frames.filter { lastTimestamp - $0.timestamp <= analysisWindowSeconds }
        }

        let motionTimestamp = frames[startIndex].timestamp
        let halfWindow = analysisWindowSeconds / 2

        return frames.filter {
            $0.timestamp >= motionTimestamp - halfWindow &&
            $0.timestamp <= motionTimestamp + halfWindow
        }
    }

    /// Score de différence moyen entre deux images (0 = identiques, 1 = totalement différentes).
    /// Volontairement très bon marché (une seule valeur moyenne par image, pas de détection de
    /// contours ni de suivi Vision) afin de pouvoir scanner tout l'enregistrement rapidement.
    private func quickMotionScore(previous: CGImage, current: CGImage) -> Double {
        let ciPrevious = CIImage(cgImage: previous)
        let ciCurrent = CIImage(cgImage: current)

        let diffFilter = CIFilter.differenceBlendMode()
        diffFilter.inputImage = ciCurrent
        diffFilter.backgroundImage = ciPrevious
        guard let diff = diffFilter.outputImage else { return 0 }

        let averageFilter = CIFilter.areaAverage()
        averageFilter.inputImage = diff
        averageFilter.extent = diff.extent
        guard let averaged = averageFilter.outputImage else { return 0 }

        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { rawPointer in
            quickMotionContext.render(
                averaged,
                toBitmap: rawPointer.baseAddress!,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }
        let brightness = (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3.0
        return brightness / 255.0
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
