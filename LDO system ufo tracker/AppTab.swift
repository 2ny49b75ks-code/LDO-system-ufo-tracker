// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI

enum AppTab {
    case live
    case library
}

/// Barre d'en-tête commune aux deux onglets : logo/titre à gauche, sélecteur d'onglets
/// (« en haut à droite ») à droite. `trackingActive` n'est renseigné que par l'onglet LIVE.
struct AppTopBar: View {
    @Binding var selectedTab: AppTab
    var trackingActive: Bool?

    var body: some View {
        HStack {
            Image("Logo")
                .resizable()
                .frame(width: 40, height: 40)
            Text("LDO")
                .foregroundColor(.green)
                .font(.headline)
            if let trackingActive {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundColor(trackingActive ? .green : .red)
                    .accessibilityLabel(trackingActive ? "Suivi AR actif" : "Suivi AR indisponible")
            }
            Spacer(minLength: 8)
            tabSwitcher
        }
        .padding()
        .background(.black.opacity(0.4))
    }

    private var tabSwitcher: some View {
        HStack(spacing: 4) {
            tabButton("LIVE", .live)
            tabButton("Bibliothèque", .library)
        }
        .padding(4)
        .background(.black.opacity(0.5))
        .clipShape(Capsule())
    }

    private func tabButton(_ title: String, _ tab: AppTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Text(title)
                .font(.caption.bold())
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selectedTab == tab ? Color.green : Color.clear)
                .foregroundColor(selectedTab == tab ? .black : .green)
                .clipShape(Capsule())
        }
    }
}
