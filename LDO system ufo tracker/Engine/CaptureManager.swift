// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import Combine
import AVFoundation
import CoreMedia
import ARKit
import CoreImage

/// Étape 1 : capture vidéo HD via ARKit (position/orientation de caméra à chaque image, utilisées
/// pour la triangulation angulaire — voir DistanceEstimator). L'enregistrement se contente de
/// sauvegarder la vidéo (sur l'appareil, sur iCloud, et dans la liste de l'onglet LIVE) —
/// l'analyse est déclenchée séparément, à la demande, par `SessionAnalyzer` une fois l'utilisateur
/// ayant choisi une vidéo à analyser.
///
/// N'utilise PAS le LiDAR : sa portée réelle (~5-8 m) est bien trop courte pour des objets aériens
/// observés à grande distance, donc la distance est toujours estimée par triangulation angulaire
/// (taille réelle supposée selon la forme détectée). Bénéfice secondaire : ARWorldTrackingConfiguration
/// fonctionne sur tout appareil compatible ARKit, pas seulement les iPhone équipés LiDAR (12 Pro+).
final class CaptureManager: NSObject, ObservableObject {
    let session = ARSession()
    @Published var isRecording = false
    @Published var trackingActive = false

    /// Injecté par la vue hôte : permet de sauvegarder l'enregistrement terminé pour qu'il
    /// apparaisse dans la liste de l'onglet LIVE.
    var recordingStore: RecordingStore?

    /// Choix Nuit/Jour de l'utilisateur (voir `CaptureMode`), réglé par la vue hôte avant
    /// l'enregistrement et sauvegardé avec la vidéo pour déterminer la stratégie d'analyse.
    @Published var captureMode: CaptureMode = .night

    private var frameBuffer: [CapturedFrame] = []

    // Cadence du buffer d'ANALYSE (pose ARKit + image en mémoire, voir `storeRecording`) : ~12
    // images/seconde suffit largement pour le mouvement/la trajectoire (l'analyse ré-échantillonne
    // de toute façon la vidéo à sa propre cadence fixe, voir `VideoFrameExtractor` — indépendante
    // de la cadence d'enregistrement ci-dessous). Volontairement plus faible que la vidéo pour
    // limiter la mémoire pendant l'enregistrement.
    private let captureIntervalSeconds: TimeInterval = 1.0 / 12.0
    private var lastCaptureTimestamp: TimeInterval = 0

    // Cadence du FICHIER VIDÉO écrit sur le disque : 30 images/seconde pour une lecture fluide,
    // indépendante du buffer d'analyse ci-dessus (l'écriture vidéo est un simple encodage matériel
    // HEVC, sans coût pour l'analyse).
    private let videoFrameIntervalSeconds: TimeInterval = 1.0 / 30.0
    private var lastVideoFrameTimestamp: TimeInterval = 0

    // MARK: Écriture du fichier vidéo (AVAssetWriter)

    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoOutputURL: URL?
    /// Contexte dédié au rehaussement faible luminosité de la vidéo écrite (voir
    /// `LowLightEnhancer`/`appendVideoFrame`), séparé de celui de `CGImage.from`.
    private let videoEnhanceContext = CIContext()

    // MARK: Configuration

    func configureARTracking() {
        guard ARWorldTrackingConfiguration.isSupported else {
            trackingActive = false
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.providesAudioData = true

        // Résolution vidéo maximale disponible sur l'appareil (voir `configureHDVideo`) : on la
        // sélectionne directement dans la configuration ARKit plutôt que via une AVCaptureSession
        // séparée, qui ne peut pas partager fiablement la caméra avec ARKit.
        if let bestFormat = Self.bestAvailableVideoFormat() {
            config.videoFormat = bestFormat
        }

        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        trackingActive = true
    }

    func configureHDVideo() {
        // La résolution vidéo (jusqu'à 4K selon l'appareil) est déjà sélectionnée dans
        // `configureMaximumLidar()` ci-dessus, via `bestAvailableVideoFormat()`.
    }

    private static func bestAvailableVideoFormat() -> ARConfiguration.VideoFormat? {
        ARWorldTrackingConfiguration.supportedVideoFormats.max {
            $0.imageResolution.width * $0.imageResolution.height
                < $1.imageResolution.width * $1.imageResolution.height
        }
    }

    // MARK: Enregistrement

    func toggleRecording() {
        isRecording.toggle()
        debugLog("toggleRecording -> isRecording=\(isRecording)")
        if isRecording {
            frameBuffer.removeAll()
            lastCaptureTimestamp = 0
            lastVideoFrameTimestamp = 0
            videoOutputURL = nil
        } else {
            finishWriting { [weak self] finishedVideoURL in
                self?.storeRecording(videoURL: finishedVideoURL)
            }
        }
    }

    /// Crée l'`AVAssetWriter` dès la première image reçue après le début d'un enregistrement
    /// (on a alors besoin des dimensions et du format de pixel réels du flux ARKit).
    private func startWriting(for frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else {
            debugLog("Impossible de créer l'AVAssetWriter")
            return
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: Int(1.0 / videoFrameIntervalSeconds)
            ]
        ])
        videoInput.expectsMediaDataInRealTime = true
        // Le capteur ARKit filme nativement en paysage quelle que soit l'orientation de
        // l'appareil (même correction que `CGImage.from(pixelBuffer:)` pour les photos) ; on
        // l'exprime ici comme métadonnée de lecture plutôt qu'en pivotant chaque pixel.
        videoInput.transform = CGAffineTransform(rotationAngle: .pi / 2)

        guard writer.canAdd(videoInput) else {
            debugLog("Impossible d'ajouter l'entrée vidéo à l'AVAssetWriter")
            return
        }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        )

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1
        ])
        audioInput.expectsMediaDataInRealTime = true
        if writer.canAdd(audioInput) {
            writer.add(audioInput)
            self.audioWriterInput = audioInput
        }

        guard writer.startWriting() else {
            debugLog("startWriting() a échoué : \(writer.error?.localizedDescription ?? "erreur inconnue")")
            return
        }
        // Les timestamps ARKit (frame.timestamp) et ceux des CMSampleBuffer audio partagent la
        // même horloge absolue : on démarre la session à l'heure réelle de la première image,
        // ce qui garde vidéo et son synchronisés sans avoir à recaler manuellement chaque flux.
        writer.startSession(atSourceTime: CMTime(seconds: frame.timestamp, preferredTimescale: 600))

        self.assetWriter = writer
        self.videoWriterInput = videoInput
        self.pixelBufferAdaptor = adaptor
        self.videoOutputURL = outputURL
    }

    /// Écrit l'image dans le fichier vidéo, rehaussée si la scène est sombre (voir
    /// `LowLightEnhancer`) — seule la vidéo écrite est modifiée, `frame.capturedImage` d'origine
    /// reste inchangé pour tout le reste du pipeline (suivi ARKit, etc.).
    private func appendVideoFrame(_ frame: ARFrame) {
        guard let videoWriterInput, let pixelBufferAdaptor, videoWriterInput.isReadyForMoreMediaData else { return }
        let presentationTime = CMTime(seconds: frame.timestamp, preferredTimescale: 600)

        let sourceImage = CIImage(cvPixelBuffer: frame.capturedImage)
        let enhancement = LowLightEnhancer.enhanceIfDark(sourceImage, using: videoEnhanceContext)

        guard enhancement.wasEnhanced,
              let pool = pixelBufferAdaptor.pixelBufferPool
        else {
            pixelBufferAdaptor.append(frame.capturedImage, withPresentationTime: presentationTime)
            return
        }

        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let outputBuffer else {
            pixelBufferAdaptor.append(frame.capturedImage, withPresentationTime: presentationTime)
            return
        }
        videoEnhanceContext.render(enhancement.image, to: outputBuffer)
        pixelBufferAdaptor.append(outputBuffer, withPresentationTime: presentationTime)
    }

    /// Finalise le fichier vidéo (asynchrone côté AVFoundation) avant de lancer l'analyse, pour
    /// être certain que `videoOutputURL` pointe vers un fichier complet et lisible.
    private func finishWriting(completion: @escaping (URL?) -> Void) {
        guard let assetWriter, assetWriter.status == .writing else {
            completion(nil)
            return
        }
        let outputURL = videoOutputURL
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()

        assetWriter.finishWriting { [weak self] in
            DispatchQueue.main.async {
                self?.assetWriter = nil
                self?.videoWriterInput = nil
                self?.audioWriterInput = nil
                self?.pixelBufferAdaptor = nil
                completion(assetWriter.status == .completed ? outputURL : nil)
            }
        }
    }

    // MARK: Sauvegarde (l'analyse se fait séparément, à la demande — voir SessionAnalyzer)

    /// Déplace la vidéo terminée dans le stockage de l'onglet LIVE et enregistre, dans un fichier
    /// annexe, la pose ARKit de chaque image capturée — nécessaire pour retrouver une trajectoire/
    /// distance de bonne qualité au moment où l'utilisateur choisira d'analyser cette vidéo plus
    /// tard (voir `RecordingStore`, `VideoFrameExtractor`).
    private func storeRecording(videoURL: URL?) {
        guard let videoURL, let recordingStore else { return }

        let capturedFrames = frameBuffer
        let fileName = videoURL.lastPathComponent
        let destinationURL = recordingStore.directory.appendingPathComponent(fileName)

        do {
            try FileManager.default.moveItem(at: videoURL, to: destinationURL)
        } catch {
            debugLog("Échec du déplacement de la vidéo vers le stockage LIVE : \(error.localizedDescription)")
            return
        }

        var posesFileName: String?
        let poses = capturedFrames.compactMap { frame -> PersistedFramePose? in
            guard let transform = frame.cameraTransform, let intrinsics = frame.intrinsics else { return nil }
            return PersistedFramePose(timestamp: frame.timestamp, transform: transform.flatColumns, intrinsics: intrinsics.flatColumns)
        }
        if !poses.isEmpty, let data = try? JSONEncoder().encode(poses) {
            let posesFile = (fileName as NSString).deletingPathExtension + "-poses.json"
            try? data.write(to: recordingStore.directory.appendingPathComponent(posesFile), options: .atomic)
            posesFileName = posesFile
        }

        recordingStore.add(videoFileName: fileName, posesFileName: posesFileName, createdAt: Date(), mode: captureMode)

        // Sauvegarde également dans Photos/iCloud, comme avant (vidéo brute — les photos avec
        // incrustations ne sont générées qu'au moment de l'analyse, voir SessionAnalyzer).
        PhotoLibrarySaver.saveVideo(at: destinationURL)
    }
}

extension CaptureManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording else { return }

        // Vidéo : cadence dédiée (~30 fps), indépendante du buffer d'analyse ci-dessous.
        if frame.timestamp - lastVideoFrameTimestamp >= videoFrameIntervalSeconds {
            lastVideoFrameTimestamp = frame.timestamp
            if assetWriter == nil {
                startWriting(for: frame)
            }
            appendVideoFrame(frame)
        }

        // Analyse : throttle plus large (~12 fps), au plus une frame gardée toutes les
        // `captureIntervalSeconds`.
        guard frame.timestamp - lastCaptureTimestamp >= captureIntervalSeconds else { return }
        lastCaptureTimestamp = frame.timestamp

        guard let cgImage = CGImage.from(pixelBuffer: frame.capturedImage) else { return }
        frameBuffer.append(
            CapturedFrame(
                image: cgImage,
                cameraTransform: frame.camera.transform,
                intrinsics: frame.camera.intrinsics,
                timestamp: frame.timestamp
            )
        )
    }

    func session(_ session: ARSession, didOutputAudioSampleBuffer audioSampleBuffer: CMSampleBuffer) {
        guard isRecording, let audioWriterInput, audioWriterInput.isReadyForMoreMediaData else { return }
        audioWriterInput.append(audioSampleBuffer)
    }
}

extension CGImage {
    /// Contexte Core Image partagé : éviter d'en recréer un à chaque frame,
    /// ce qui provoquait des saccades pendant l'enregistrement.
    private static let conversionContext = CIContext(options: nil)

    /// Conversion utilitaire CVPixelBuffer (format YCbCr d'ARKit) -> CGImage, réorientée pour
    /// correspondre à l'orientation portrait de l'appareil (ARKit capture nativement en paysage,
    /// quelle que soit l'orientation de l'UI, d'où l'image de travers sans cette correction), et
    /// rehaussée automatiquement si la scène est sombre (voir `LowLightEnhancer`) — sert à la fois
    /// au buffer d'analyse et de base aux photos (voir `PhotoComposer`).
    static func from(pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let enhanced = LowLightEnhancer.enhanceIfDark(ciImage, using: conversionContext).image
        return conversionContext.createCGImage(enhanced, from: enhanced.extent)
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
