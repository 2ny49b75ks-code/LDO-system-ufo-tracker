// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI

/// Réticule de ciblage superposable sur un aperçu vidéo (caméra en direct ou lecteur de relecture) :
/// un tap place le centre, GLISSER LE DOIGT EN LE MAINTENANT sur la cible la déplace en continu vers
/// une nouvelle destination (pas seulement un saut instantané à la fin du geste — demande explicite
/// de Jean-David, 2026-09-13 : « tenir la cible pour la déplacer vers destination »), et une poignée
/// sur le bord du cercle permet de l'agrandir/rétrécir — demande explicite de Jean-David (2026-09-11) :
/// « toucher la cible à l'écran, c'est la zone à analyser, en mode capture et en mode analyse » +
/// choix explicite de la poignée de redimensionnement plutôt qu'un second geste de pincement (qui
/// entrerait en conflit avec le zoom).
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

    /// Espace de coordonnées nommé, partagé par les deux gestes ci-dessous — sans lui, `DragGesture`
    /// rapporte `value.location` dans le repère LOCAL de la vue à laquelle il est attaché (le
    /// comportement par défaut, `coordinateSpace: .local`) : pour la poignée (un cercle de 22×22pt),
    /// ça donne des coordonnées comprises entre 0 et 22 au lieu de la vraie position dans le cadre —
    /// sans rapport avec `center`/`radius`, qui vivent dans le repère du conteneur. BUG CORRIGÉ
    /// (2026-09-11, testé en direct dans le simulateur : la poignée ne redimensionnait jamais le
    /// cercle, le calcul de distance au centre était en réalité toujours minuscule et se plafonnait
    /// immédiatement à `minRadius`).
    private let coordinateSpaceName = "targetReticle"

    var body: some View {
        ZStack {
            // Zone de tap/glissement : place le centre au premier contact, puis le SUIT en continu
            // tant que le doigt reste posé (`onChanged`, pas seulement `onEnded`) — pour qu'on puisse
            // « tenir » la cible et la faire glisser vers une nouvelle destination avec un retour
            // visuel immédiat, plutôt qu'un simple saut instantané une fois le doigt relevé. Un tap
            // isolé continue de fonctionner tel quel : `onChanged` se déclenche dès le premier contact
            // même sans glissement (`minimumDistance: 0`). `contentShape` couvre tout le cadre pour
            // que le geste fonctionne n'importe où, pas seulement là où un cercle existe déjà.
            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
                        .onChanged { value in
                            // Ignore les touchers qui commencent près de la poignée existante (voir
                            // `handlePosition` ci-dessous) : cette zone doit rester réservée au
                            // redimensionnement, pas au déplacement du centre.
                            if let center {
                                let handlePosition = CGPoint(x: center.x + radius, y: center.y)
                                let dx = value.startLocation.x - handlePosition.x
                                let dy = value.startLocation.y - handlePosition.y
                                guard (dx * dx + dy * dy).squareRoot() > 30 else { return }
                            }
                            center = value.location
                        }
                )

            if let center {
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

                // Poignée de redimensionnement, sur le bord droit du cercle (angle 0) — on la glisse
                // horizontalement pour ajuster le rayon, distance de la poignée au centre = nouveau rayon.
                let handlePosition = CGPoint(x: center.x + radius, y: center.y)
                Circle()
                    .fill(Color.white)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.ldoSignal, lineWidth: 2))
                    .position(handlePosition)
                    .contentShape(Circle())
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
