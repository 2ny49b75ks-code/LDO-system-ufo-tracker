// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI

/// Affiche la progression réelle du calcul (par étape terminée, voir `AnalysisEngine.analyze`),
/// plutôt qu'une simple estimation de durée qu'il n'est pas possible de calibrer sans mesure sur
/// un appareil physique. Le radar animé n'a qu'un rôle visuel (aucune donnée réelle affichée dessus) ;
/// la barre linéaire, le libellé d'étape et le pourcentage en dessous restent la source de vérité.
struct AnalysisProgressView: View {
    @ObservedObject var analyzer: SessionAnalyzer

    var body: some View {
        VStack(spacing: 20) {
            RadarSweepView()
                .frame(width: 180, height: 180)

            ProgressView(value: analyzer.progress)
                .progressViewStyle(.linear)
                .tint(.green)
                .frame(width: 220)
            Text(analyzer.progressLabel)
                .foregroundColor(.green)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Text("\(Int(analyzer.progress * 100)) %")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(30)
        .background(.black.opacity(0.85))
        .cornerRadius(16)
    }
}

/// Radar circulaire animé (balayage en rotation continue) affiché pendant le calcul de l'analyse —
/// purement décoratif, pour donner une impression de « détection en cours » pendant l'attente réelle.
private struct RadarSweepView: View {
    @State private var rotationDegrees: Double = 0
    @State private var blipPulse: Bool = false

    private let ringCount = 4

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.green.opacity(0.6), lineWidth: 1.5)

            ForEach(1..<ringCount, id: \.self) { ring in
                Circle()
                    .stroke(Color.green.opacity(0.22), lineWidth: 1)
                    .scaleEffect(CGFloat(ring) / CGFloat(ringCount))
            }

            RadarSweepWedge(sweepDegrees: 70)
                .fill(
                    AngularGradient(
                        gradient: Gradient(colors: [Color.green.opacity(0.5), Color.green.opacity(0)]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(70)
                    )
                )
                .rotationEffect(.degrees(rotationDegrees))

            // Point cible clignotant : purement décoratif, ne représente pas une vraie détection.
            Circle()
                .fill(Color.yellow)
                .frame(width: 7, height: 7)
                .shadow(color: .yellow, radius: blipPulse ? 6 : 2)
                .opacity(blipPulse ? 1 : 0.5)
                .offset(x: 22, y: -18)

            Circle()
                .fill(Color.green)
                .frame(width: 4, height: 4)
        }
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                rotationDegrees = 360
            }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                blipPulse = true
            }
        }
    }
}

/// Secteur circulaire (camembert) utilisé pour dessiner le balayage du radar.
private struct RadarSweepWedge: Shape {
    let sweepDegrees: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: .degrees(0), endAngle: .degrees(sweepDegrees), clockwise: false)
        path.closeSubpath()
        return path
    }
}
