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

private let sharedFrameConversionContext = CIContext(options: [.useSoftwareRenderer: false])

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

    private let captureIntervalSeconds: TimeInterval = 1.0 / 12.0
    private var lastCaptureTimestamp: TimeInterval = 0

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
        NSLog("LDO_DEBUG configureMaximumLidar appelé, lidarActive=%@", String(lidarActive))
    }

    func configureHDVideo() {
    }

    func toggleRecording() {
        isRecording.toggle()
        NSLog("LDO_DEBUG toggleRecording -> isRecording=%@", String(isRecording))
        if isRecording {
            frameBuffer.removeAll()
            lastCaptureTimestamp = 0
            startRecording()
        } else {
            stopRecordingAndAnalyze()
        }
    }

    private func startRecording() {
        NSLog("LDO_DEBUG startRecording appelé")
    }

    private func stopRecordingAndAnalyze() {
        session.pause()
        isAnalyzing = true

        let capturedFrames = frameBuffer
        let capturedVideoURL = videoOutputURL

        NSLog("LDO_DEBUG Arrêt enregistrement, %d frames capturées", capturedFrames.count)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                NSLog("LDO_DEBUG self est nil dans le bloc async, abandon")
                return
            }

            NSLog("LDO_DEBUG Début analyse en arrière-plan")
            let windowFrames = self.extractMotionWindow(from: capturedFrames)
            let bestFrames = self.selectOptimalFrames(from: windowFrames, count: 3)

            let engine = AnalysisEngine()
            let result = engine.analyze(frames: windowFrames, videoURL: capturedVideoURL)
            NSLog("LDO_DEBUG AnalysisEngine.analyze terminé")

            DispatchQueue.main.async {
                self.saveToDeviceAndICloud(video: capturedVideoURL, photos: bestFrames)
                self.finishedSession = result
                self.isAnalyzing = false
                NSLog("LDO_DEBUG Analyse terminée, résultat prêt, finishedSession assigné")
            }
        }
    }

    private func extractMotionWindow(from frames: [CapturedFrame]) -> [CapturedFrame] {
        guard frames.count >= 2 else {
            NSLog("LDO_DEBUG extractMotionWindow: moins de 2 frames (%d), retour direct", frames.count)
            return frames
        }

        var motionStartIndex: Int?
        var maxScoreSeen: Double = 0

        for i in 1..<frames.count {
            let score = quickMotionScore(previous: frames[i - 1].image, current: frames[i].image)
            maxScoreSeen = max(maxScoreSeen, score)
            if score >= quickMotionThreshold {
                motionStartIndex = i
                NSLog("LDO_DEBUG MOUVEMENT DÉTECTÉ à l'index %d/%d, score=%.4f, timestamp=%.3f", i, frames.count, score, frames[i].timestamp)
                break
            }
        }

        guard let startIndex = motionStartIndex else {
            NSLog("LDO_DEBUG Aucun mouvement détecté sur %d frames (score max = %.4f). Repli sur les 2 dernières secondes.", frames.count, maxScoreSeen)
            let lastTimestamp = frames.last!.timestamp
            let fallback = frames.filter { lastTimestamp - $0.timestamp <= analysisWindowSeconds }
            NSLog("LDO_DEBUG Fenêtre de repli: %d frames", fallback.count)
            return fallback
        }

        let motionTimestamp = frames[startIndex].timestamp
        let halfWindow = analysisWindowSeconds / 2

        let window = frames.filter {
            $0.timestamp >= motionTimestamp - halfWindow &&
            $0.timestamp <= motionTimestamp + halfWindow
        }
        NSLog("LDO_DEBUG Fenêtre extraite: %d frames autour de t=%.3f", window.count, motionTimestamp)
        return window
    }

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

    private func selectOptimalFrames(
        from buffer: [CapturedFrame],
        count: Int
    ) -> [CGImage] {
        let scored = buffer.map { frame -> (CGImage, Double) in
            (frame.image, FrameQualityScorer.score(frame.image))
        }
        let sorted = scored.sorted { $0.1 > $1.1 }
        NSLog("LDO_DEBUG selectOptimalFrames: %d frames évaluées, meilleur score=%.2f", buffer.count, sorted.first?.1 ?? -1)
        return sorted
            .prefix(count)
            .map { $0.0 }
    }

    private func saveToDeviceAndICloud(video: URL?, photos: [CGImage]) {
        NSLog("LDO_DEBUG saveToDeviceAndICloud appelé, %d photos, vidéo=%@", photos.count, video?.absoluteString ?? "nil")
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                NSLog("LDO_DEBUG Autorisation photothèque refusée, status=%d", status.rawValue)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                if let video {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: video)
                }
                for cg in photos {
                    let ui = UIImage(cgImage: cg)
                    PHAssetChangeRequest.creationRequestForAsset(from: ui)
                }
            }
        }
    }
}

extension CaptureManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording else { return }

        guard frame.timestamp - lastCaptureTimestamp >= captureIntervalSeconds else { return }
        lastCaptureTimestamp = frame.timestamp

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
    static func from(pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        return sharedFrameConversionContext.createCGImage(ciImage, from: ciImage.extent)
    }
}

import UIKit

enum FrameQualityScorer {
    static func score(_ image: CGImage) -> Double {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }

        let width = image.width
        let height = image.height
        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow

        guard width > 2, height > 2, bytesPerPixel >= 3 else { return 0 }

        let stepX = max(1, width / 200)
        let stepY = max(1, height / 200)

        var laplacianSum: Double = 0
        var laplacianSumSq: Double = 0
        var brightnessSum: Double = 0
        var count: Double = 0

        func luminance(_ x: Int, _ y: Int) -> Double {
            let offset = y * bytesPerRow + x * bytesPerPixel
            guard offset + 2 < CFDataGetLength(data) else { return 0 }
            let r = Double(bytes[offset])
            let g = Double(bytes[offset + 1])
            let b = Double(bytes[offset + 2])
            return 0.299 * r + 0.587 * g + 0.114 * b
        }

        var y = stepY
        while y < height - stepY {
            var x = stepX
            while x < width - stepX {
                let center = luminance(x, y)
                let up = luminance(x, y - stepY)
                let down = luminance(x, y + stepY)
                let left = luminance(x - stepX, y)
                let right = luminance(x + stepX, y)

                let laplacian = up + down + left + right - 4 * center
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
        let variance = (laplacianSumSq / count) - (mean * mean)
        let sharpnessScore = variance

        let averageBrightness = brightnessSum / count
        let exposurePenalty: Double
        if averageBrightness < 20 || averageBrightness > 235 {
            exposurePenalty = 0.3
        } else {
            exposurePenalty = 1.0
        }

        return sharpnessScore * exposurePenalty
    }
}
