// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
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
        session.run(config,
