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
///
/// Chaque étape (permission refusée, fichier introuvable, requête Photos rejetée en silence,
/// échec de `performChanges`) est journalisée en Debug : sans ça, une vidéo qui ne se sauvegarde
/// pas échoue silencieusement — aucune de ces défaillances ne remonte à l'écran.
enum PhotoLibrarySaver {
    static func saveVideo(at url: URL, completion: ((Bool) -> Void)? = nil) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            debugLog("saveVideo : fichier introuvable à \(url.path)")
            completion?(false)
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                debugLog("saveVideo : autorisation photothèque refusée (status=\(status.rawValue))")
                completion?(false)
                return
            }
            var requestFailedSilently = false
            PHPhotoLibrary.shared().performChanges {
                if PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) == nil {
                    // Arrive si Photos ne reconnaît pas le fichier comme une vidéo valide
                    // (mauvais conteneur/codec, fichier corrompu, etc.).
                    requestFailedSilently = true
                }
            } completionHandler: { success, error in
                if requestFailedSilently {
                    debugLog("saveVideo : Photos n'a pas reconnu \(url.lastPathComponent) comme vidéo valide")
                    completion?(false)
                } else if let error {
                    debugLog("saveVideo : échec — \(error.localizedDescription)")
                    completion?(false)
                } else {
                    debugLog("saveVideo : \(url.lastPathComponent) sauvegardée dans Photos (succès=\(success))")
                    completion?(success)
                }
            }
        }
    }

    static func savePhotos(_ images: [CGImage], completion: ((Bool) -> Void)? = nil) {
        guard !images.isEmpty else {
            completion?(true)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                debugLog("savePhotos : autorisation photothèque refusée (status=\(status.rawValue))")
                completion?(false)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                for image in images {
                    PHAssetChangeRequest.creationRequestForAsset(from: UIImage(cgImage: image))
                }
            } completionHandler: { success, error in
                if let error {
                    debugLog("savePhotos : échec — \(error.localizedDescription)")
                } else {
                    debugLog("savePhotos : \(images.count) photo(s) sauvegardée(s) dans Photos (succès=\(success))")
                }
                completion?(error == nil && success)
            }
        }
    }
}

/// Log de debug actif uniquement en build Debug (aucun coût en production).
private func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("LDO_DEBUG \(message())")
    #endif
}
