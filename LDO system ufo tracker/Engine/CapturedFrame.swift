// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import CoreVideo
import CoreGraphics
import simd

/// Une image capturée avec toutes les métadonnées nécessaires à l'analyse 3D :
/// - `cameraTransform` : position + orientation de la caméra dans l'espace ARKit au moment T
/// - `intrinsics` : matrice intrinsèque de la caméra (focale, point principal) au moment T
///
/// Ces deux éléments sont indispensables pour convertir une position d'objet en pixels (2D)
/// en une **direction réelle dans le ciel** (3D), et donc pour calculer une trajectoire et
/// des forces G qui aient un sens physique plutôt qu'un simple déplacement de pixels à l'écran.
struct CapturedFrame {
    let image: CGImage
    let depthMap: CVPixelBuffer?
    let cameraTransform: simd_float4x4
    let intrinsics: simd_float3x3
    let timestamp: TimeInterval
}
