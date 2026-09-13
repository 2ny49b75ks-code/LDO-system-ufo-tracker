// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI

/// Réticule de ciblage superposable sur un aperçu vidéo (caméra en direct ou lecteur de relecture) :
/// toucher la cible (l'intérieur du cercle) et glisser la DÉPLACE en continu vers une nouvelle
/// destination ; toucher ailleurs sur l'écran la REPOSITIONNE instantanément à l'endroit touché ;
/// toucher précisément le POINT BLANC sur le bord du cercle permet de l'agrandir/rétrécir — les
/// trois gestes sont mutuellement exclusifs (voir `FullScreenMinusHandle` ci-dessous), pas de zone
/// ambiguë entre eux. Demandes explicites de Jean-David (2026-09-13) : « tenir la cible pour la
/// déplacer vers destination », « si on touche ailleurs sur l'écran on doit pouvoir repositionner la
/// cible à l'endroit touché », et « pour agrandir la zone on doit toucher le point blanc... pas
/// n'importe où sur la cible » (voir le correctif ci-dessous, l'ancienne heuristique par distance
/// entre le début du geste et la poignée n'excluait pas fiablement le reste du cercle).
///
/// Composant partagé entre `LiveTabView` (ciblage en direct, avant/pendant l'enregistrement) et
/// `ClipTrimView` (ciblage après l'enregistrement, en choisissant l'extrait à analyser) — évite de
/// dupliquer cette logique dans les deux écrans.
///
/// `center`/`radius` sont exprimés en points, dans le repère LOCAL de la vue hôte (origine haut-gauche,
/// comme tout SwiftUI) — la conversion vers le repère Vision normalisé (0...1, origine bas-gauche)
/// attendu par le pipeline d'analyse se fait au point d'appel (voir `visionHintPoint`/`visionHintRadius`
/// ci-dessous), pas ici.
struct TargetReticleOverlay: View {
    @Binding var center: CGPoint?
    @Binding var radius: CGFloat
    let containerSize: CGSize

    private let minRadius: CGFloat = 24
    private let maxRadiusFraction: CGFloat = 0.45   // fraction de la plus petite dimension du cadre

    /// Rayon de la zone TACTILE (pas du dessin, voir `handleVisualDiameter`) réservée à la poignée de
    /// redimensionnement — plus grande que le point blanc affiché (repère Apple : cible tactile
    /// minimale ~44pt de diamètre), et surtout : EXACTEMENT la même zone est à la fois exclue du
    /// geste de déplacement/placement (voir `FullScreenMinusHandle`) et attachée au geste de
    /// redimensionnement (voir `.contentShape(Circle())` sur la poignée plus bas) — élimine toute
    /// zone morte ou ambiguïté entre les deux gestes par construction géométrique, plutôt que par une
    /// heuristique de distance au démarrage du geste (BUG CORRIGÉ, signalé par Jean-David,
    /// 2026-09-13 : « si on touche la cible ça s'agrandit » — toucher n'importe où sur l'anneau
    /// visible, pas seulement le point blanc, pouvait déclencher le redimensionnement).
    private let handleTouchRadius: CGFloat = 22
    private let handleVisualDiameter: CGFloat = 22

    /// Espace de coordonnées nommé, partagé par les deux gestes ci-dessous — sans lui, `DragGesture`
    /// rapporte `value.location` dans le repère LOCAL de la vue à laquelle il est attaché (le
    /// comportement par défaut, `coordinateSpace: .local`) : pour la poignée (un cercle de 22×22pt),
    /// ça donne des coordonnées comprises entre 0 et 22 au lieu de la vraie position dans le cadre —
    /// sans rapport avec `center`/`radius`, qui vivent dans le repère du conteneur. BUG CORRIGÉ
    /// (2026-09-11, testé en direct dans le simulateur : la poignée ne redimensionnait jamais le
    /// cercle, le calcul de distance au centre était en réalité toujours minuscule et se plafonnait
    /// immédiatement à `minRadius`).
    private let coordinateSpaceName = "targetReticle"

    /// Position de la poignée de redimensionnement (bord droit du cercle, angle 0) — `nil` tant
    /// qu'aucune cible n'est placée. Calculée une seule fois ici, réutilisée à la fois pour le
    /// dessin, l'exclusion géométrique du geste de déplacement, et le geste de redimensionnement
    /// lui-même, pour qu'ils restent forcément synchronisés.
    private var handlePosition: CGPoint? {
        guard let center else { return nil }
        return CGPoint(x: center.x + radius, y: center.y)
    }

    var body: some View {
        ZStack {
            // Zone de tap/glissement : place le centre au premier contact (n'importe où À
            // L'EXTÉRIEUR de la cible existante = repositionnement instantané à l'endroit touché ;
            // À L'INTÉRIEUR de la cible = déplacement, qui la suit ensuite en continu tant que le
            // doigt reste posé, voir `onChanged` plutôt que `onEnded` seul). La poignée de
            // redimensionnement (voir `handlePosition` ci-dessus) est GÉOMÉTRIQUEMENT EXCLUE de cette
            // zone tactile (voir `FullScreenMinusHandle`, un simple découpage de forme, pas une
            // vérification de distance a posteriori) : un toucher qui commence sur la poignée n'active
            // donc jamais ce geste-ci, seulement celui de la poignée plus bas.
            Color.clear
                .contentShape(FullScreenMinusHandle(handleCenter: handlePosition, handleRadius: handleTouchRadius), eoFill: true)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
                        .onChanged { value in
                            center = value.location
                        }
                )

            if let center, let handlePosition {
                Circle()
                    .stroke(Color.ldoSignal, lineWidth: 2.5)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)
                    .allowsHitTesting(false)
                Circle()
                    .fill(Color.ldoSignal)
                    .frame(width: 6, height: 6)
                    .position(center)
                    .allowsHitTesting(false)

                // Poignée de redimensionnement — le cadre visible (`handleVisualDiameter`) reste
                // petit et discret, mais la zone tactile réelle (`handleTouchRadius`, voir le
                // commentaire de sa déclaration) est plus généreuse et surtout identique à celle
                // exclue ci-dessus, pour qu'aucun toucher ne tombe dans une zone morte entre les deux.
                Circle()
                    .fill(Color.white)
                    .frame(width: handleVisualDiameter, height: handleVisualDiameter)
                    .overlay(Circle().stroke(Color.ldoSignal, lineWidth: 2))
                    .frame(width: handleTouchRadius * 2, height: handleTouchRadius * 2)
                    .contentShape(Circle())
                    .position(handlePosition)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
                            .onChanged { value in
                                let dx = value.location.x - center.x
                                let dy = value.location.y - center.y
                                let candidate = (dx * dx + dy * dy).squareRoot()
                                let maxRadius = min(containerSize.width, containerSize.height) * maxRadiusFraction
                                radius = min(max(candidate, minRadius), max(maxRadius, minRadius))
                            }
                    )
            }
        }
        .coordinateSpace(name: coordinateSpaceName)
    }
}

/// Rectangle plein avec un « trou » circulaire découpé à l'emplacement de la poignée de
/// redimensionnement (règle du remplissage pair-impair, voir `.contentShape(_:eoFill:)` au point
/// d'appel) — exclusion géométrique pure, contrairement à une vérification de distance après coup :
/// un toucher qui débute dans le trou ne peut tout simplement pas être hit-testé par la vue à
/// laquelle cette forme sert de `contentShape`, quel que soit l'ordre d'évaluation des gestes.
private struct FullScreenMinusHandle: Shape {
    let handleCenter: CGPoint?
    let handleRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if let handleCenter {
            let holeRect = CGRect(
                x: handleCenter.x - handleRadius, y: handleCenter.y - handleRadius,
                width: handleRadius * 2, height: handleRadius * 2
            )
            path.addPath(Path(ellipseIn: holeRect))
        }
        return path
    }
}

extension TargetReticleOverlay {
    /// Convertit `center` (repère local, origine haut-gauche) en repère Vision normalisé (0...1,
    /// origine bas-gauche) attendu par `AnalysisEngine`/`MotionDetector`.
    static func visionHintPoint(center: CGPoint?, containerSize: CGSize) -> CGPoint? {
        guard let center, containerSize.width > 0, containerSize.height > 0 else { return nil }
        return CGPoint(x: center.x / containerSize.width, y: 1 - center.y / containerSize.height)
    }

    /// Convertit `radius` (points) en rayon normalisé — même référence (plus petite dimension du
    /// cadre) que la conversion du centre, pour rester cohérent visuellement entre le cercle affiché
    /// à l'écran et la zone réellement filtrée par la détection.
    static func visionHintRadius(radius: CGFloat, containerSize: CGSize) -> CGFloat? {
        let reference = min(containerSize.width, containerSize.height)
        guard reference > 0 else { return nil }
        return radius / reference
    }
}
