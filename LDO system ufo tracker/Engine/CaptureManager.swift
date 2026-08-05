// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import Combine
import AVFoundation
import ARKit
import Photos
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

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

    private let analysisWindowSeconds: TimeInterval = 2.0
    private let quickMotionThreshold: Double = 0.02

    // Limite la capture à ~12 images/seconde (au lieu des ~60 fps d'ARKit) : largement
    // suffisant pour l'analyse de mouvement/trajectoire, et réduit nettement la charge
    // mémoire/CPU pendant l'enregistrement — donc plus de fluidité côté UI.
    private let captureIntervalSeconds: TimeInterval = 1.0 / 12.0
    private var lastCaptureTimestamp: TimeInterval = 0

    // MARK: Configuration

    func configureMaximumLidar() {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            lidarActive = false
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        config.frameSemantics.insert(.sceneDepth)
        config.frameSemantics.insert(.smoothedSceneDepth)
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        lidarActive = true
    }

    func configureHDVideo() {
        // La résolution vidéo (1920x1080 ou 4K selon l'appareil) sera fixée
        // au plus haut preset supporté par AVCaptureSession, en parallèle de la session ARKit.
    }

    // MARK: Enregistrement

    func toggleRecording() {
        isRecording.toggle()
        debugLog("toggleRecording -> isRecording=\(isRecording)")
        if isRecording {
            frameBuffer.removeAll()
            lastCaptureTimestamp = 0
        } else {
            stopRecordingAndAnalyze()
        }
    }

    private func stopRecordingAndAnalyze() {
        // La session ARKit reste active : seul le drapeau `isRecording` contrôle la
        // capture des frames, ce qui permet de relancer un enregistrement sans
        // avoir à relancer (et donc perdre le suivi de) la session LiDAR.
        isAnalyzing = true

        let capturedFrames = frameBuffer
        let capturedVideoURL = videoOutputURL

        debugLog("Arrêt enregistrement, \(capturedFrames.count) frames capturées")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let windowFrames = self.extractMotionWindow(from: capturedFrames)
            let bestFrames = self.selectOptimalFrames(from: windowFrames, count: 3)
            let result = AnalysisEngine().analyze(frames: windowFrames, videoURL: capturedVideoURL)

            DispatchQueue.main.async {
                self.saveToDeviceAndICloud(video: capturedVideoURL, photos: bestFrames)
                self.finishedSession = result
                self.isAnalyzing = false
            }
        }
    }

    // MARK: Détection de mouvement

    /// Isole la fenêtre de `analysisWindowSeconds` autour du premier mouvement détecté.
    /// Sans mouvement détecté, on retombe sur les dernières secondes capturées.
    private func extractMotionWindow(from frames: [CapturedFrame]) -> [CapturedFrame] {
        guard frames.count >= 2, let lastTimestamp = frames.last?.timestamp else { return frames }

        let motionIndex = (1..<frames.count).first {
            quickMotionScore(previous: frames[$0 - 1].image, current: frames[$0].image) >= quickMotionThreshold
        }

        guard let motionIndex else {
            debugLog("Aucun mouvement détecté, repli sur les \(analysisWindowSeconds)s les plus récentes.")
            return frames.filter { lastTimestamp - $0.timestamp <= analysisWindowSeconds }
        }

        let motionTimestamp = frames[motionIndex].timestamp
        let halfWindow = analysisWindowSeconds / 2
        debugLog("Mouvement détecté à t=\(motionTimestamp)")
        return frames.filter { abs($0.timestamp - motionTimestamp) <= halfWindow }
    }

    /// Score de mouvement rapide entre deux frames (différence moyenne de luminosité, 0…1).
    private func quickMotionScore(previous: CGImage, current: CGImage) -> Double {
        let diffFilter = CIFilter.differenceBlendMode()
        diffFilter.inputImage = CIImage(cgImage: current)
        diffFilter.backgroundImage = CIImage(cgImage: previous)
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

    /// Sélectionne les meilleures images selon la netteté et l'exposition (voir `FrameQualityScorer`).
    private func selectOptimalFrames(from buffer: [CapturedFrame], count: Int) -> [CGImage] {
        buffer
            .map { ($0.image, FrameQualityScorer.score($0.image)) }
            .sorted { $0.1 > $1.1 }
            .prefix(count)
            .map { $0.0 }
    }

    // MARK: Sauvegarde

    private func saveToDeviceAndICloud(video: URL?, photos: [CGImage]) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                debugLog("Autorisation photothèque refusée, status=\(status.rawValue)")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                if let video {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: video)
                }
                for image in photos {
                    PHAssetChangeRequest.creationRequestForAsset(from: UIImage(cgImage: image))
                }
            }
        }
    }
}

extension CaptureManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording else { return }

        // Throttle : au plus une frame gardée toutes les `captureIntervalSeconds`.
        guard frame.timestamp - lastCaptureTimestamp >= captureIntervalSeconds else { return }
        lastCaptureTimestamp = frame.timestamp

        guard let cgImage = CGImage.from(pixelBuffer: frame.capturedImage) else { return }
        frameBuffer.append(
            CapturedFrame(
                image: cgImage,
                depthMap: frame.sceneDepth?.depthMap,
                cameraTransform: frame.camera.transform,
                intrinsics: frame.camera.intrinsics,
                timestamp: frame.timestamp
            )
        )
    }
}

extension CGImage {
    /// Contexte Core Image partagé : éviter d'en recréer un à chaque frame,
    /// ce qui provoquait des saccades pendant l'enregistrement.
    private static let conversionContext = CIContext(options: nil)

    /// Conversion utilitaire CVPixelBuffer (format YCbCr d'ARKit) -> CGImage, réorientée pour
    /// correspondre à l'orientation portrait de l'appareil (ARKit capture nativement en paysage,
    /// quelle que soit l'orientation de l'UI, d'où l'image de travers sans cette correction).
    static func from(pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        return conversionContext.createCGImage(ciImage, from: ciImage.extent)
    }
}

enum FrameQualityScorer {
    /// Score combiné netteté (variance du Laplacien) + pénalité d'exposition,
    /// utilisé pour choisir les 3 meilleures images.
    static func score(_ image: CGImage) -> Double {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }

        let width = image.width
        let height = image.height
        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow

        guard width > 2, height > 2, bytesPerPixel >= 3 else { return 0 }

        let stepX = max(1, width / 200)
        let stepY = max(1, height / 200)

        func luminance(_ x: Int, _ y: Int) -> Double {
            let offset = y * bytesPerRow + x * bytesPerPixel
            guard offset + 2 < CFDataGetLength(data) else { return 0 }
            return 0.299 * Double(bytes[offset]) + 0.587 * Double(bytes[offset + 1]) + 0.114 * Double(bytes[offset + 2])
        }

        var laplacianSum = 0.0
        var laplacianSumSq = 0.0
        var brightnessSum = 0.0
        var count = 0.0

        var y = stepY
        while y < height - stepY {
            var x = stepX
            while x < width - stepX {
                let center = luminance(x, y)
                let laplacian = luminance(x, y - stepY) + luminance(x, y + stepY)
                    + luminance(x - stepX, y) + luminance(x + stepX, y) - 4 * center
                laplacianSum += laplacian
                laplacianSumSq += laplacian * laplacian
                brightnessSum += center
                count += 1
                x += stepX
            }
            y += stepY
        }

        guard count > 0 else { return 0 }

        let mean = laplacianSum / count
        let sharpness = (laplacianSumSq / count) - (mean * mean)
        let averageBrightness = brightnessSum / count
        let exposurePenalty = (averageBrightness < 20 || averageBrightness > 235) ? 0.3 : 1.0

        return sharpness * exposurePenalty
    }
}

/// Log de debug actif uniquement en build Debug (aucun coût en production).
private func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("LDO_DEBUG \(message())")
    #endif
}
