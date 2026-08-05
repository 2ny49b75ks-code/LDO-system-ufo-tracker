// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import Photos
import UIKit

/// Sauvegarde sur l'appareil et sur iCloud (via Photos), utilisé à la fois par `CaptureManager`
/// (vidéo brute, dès l'enregistrement) et par `SessionAnalyzer` (photos avec incrustations, une
/// fois l'analyse terminée — elles n'existent qu'à ce moment-là).
enum PhotoLibrarySaver {
    static func saveVideo(at url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        }
    }

    static func savePhotos(_ images: [CGImage]) {
        guard !images.isEmpty else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else { return }
            PHPhotoLibrary.shared().performChanges {
                for image in images {
                    PHAssetChangeRequest.creationRequestForAsset(from: UIImage(cgImage: image))
                }
            }
        }
    }
}
