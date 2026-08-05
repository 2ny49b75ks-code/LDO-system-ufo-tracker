// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import CoreGraphics
import simd

/// Une image capturée avec toutes les métadonnées nécessaires à l'analyse :
/// - `cameraTransform` : position + orientation de la caméra dans l'espace ARKit au moment T
/// - `intrinsics` : matrice intrinsèque de la caméra (focale, point principal) au moment T
///
/// Ces deux éléments sont indispensables pour convertir une position d'objet en pixels (2D)
/// en une **direction réelle dans le ciel** (3D), et donc pour calculer une trajectoire et
/// des forces G qui aient un sens physique plutôt qu'un simple déplacement de pixels à l'écran.
/// La distance elle-même est toujours estimée par triangulation angulaire (voir
/// `DistanceEstimator`) — pas de LiDAR, dont la portée réelle (~5-8 m) est sans intérêt pour des
/// objets aériens observés à grande distance.
///
/// `cameraTransform`/`intrinsics` sont optionnels car ils n'existent que pour les images
/// capturées en direct via ARKit : une vidéo déjà enregistrée (onglet LIVE, ré-analysée plus
/// tard) conserve sa pose caméra dans un fichier annexe (voir `RecordingStore`), mais une vidéo
/// importée depuis la bibliothèque photo n'en a jamais eu.
struct CapturedFrame {
    let image: CGImage
    let cameraTransform: simd_float4x4?
    let intrinsics: simd_float3x3?
    let timestamp: TimeInterval
}
