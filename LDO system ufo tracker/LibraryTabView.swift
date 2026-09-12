// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

/// Onglet Bibliothèque : importe une vidéo déjà présente dans la photothèque (bouton « + ») et
/// l'analyse avec le même pipeline que l'onglet LIVE. `PhotosPicker` ne demande aucune permission
/// de lecture de la photothèque (accès limité au fichier explicitement choisi par l'utilisateur).
///
/// Sans pose ARKit (cette vidéo n'a jamais été filmée en direct par LDO), la distance/altitude et
/// la trajectoire réelle sont moins précises — voir la dégradation gracieuse déjà prévue dans
/// `TrajectoryCalculator`/`DistanceEstimator` pour les images sans `cameraTransform`/`intrinsics`.
struct LibraryTabView: View {
    @Binding var selectedTab: AppTab
    @State private var pickerItem: PhotosPickerItem?
    @State private var analysisTarget: AnalysisTarget?
    @State private var isImporting = false
    @State private var importErrorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                AppTopBar(selectedTab: $selectedTab)

                Spacer()

                VStack(spacing: 20) {
                    Image(systemName: "film")
                        .font(.system(size: 56))
                        .foregroundColor(.green)

                    Text("Analyser une vidéo de votre bibliothèque")
                        .foregroundColor(.white)
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    Text("Distance et altitude moins précises qu'un enregistrement LIVE (position de la caméra non disponible pour une vidéo déjà filmée).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    if isImporting {
                        ProgressView("Importation…")
                            .tint(.green)
                            .foregroundColor(.white)
                    } else {
                        PhotosPicker(selection: $pickerItem, matching: .videos) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 64))
                                .foregroundColor(.green)
                        }
                    }

                    if let importErrorMessage {
                        Text(importErrorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                }

                Spacer()
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            importErrorMessage = nil
            isImporting = true
            Task {
                await importVideo(newItem)
                isImporting = false
                pickerItem = nil
            }
        }
        .fullScreenCover(item: $analysisTarget) { target in
            AnalysisFlowView(videoURL: target.videoURL, poses: target.poses, initialMode: target.initialMode, captureLocation: target.captureLocation, captureStartedAt: target.captureStartedAt) {
                // « Nouvelle capture » : referme le flux d'analyse et réinitialise l'état
                // d'importation, prêt pour une prochaine vidéo.
                analysisTarget = nil
                pickerItem = nil
                importErrorMessage = nil
            }
        }
    }

    private func importVideo(_ item: PhotosPickerItem) async {
        do {
            guard let movie = try await item.loadTransferable(type: MovieFile.self) else {
                importErrorMessage = "Impossible de lire cette vidéo."
                return
            }
            // Pas de mode connu pour une vidéo importée (jamais filmée par LDO) — Nuit par défaut,
            // l'utilisateur peut le changer dans ClipTrimView avant de lancer l'analyse. Pas de
            // pose ARKit non plus (même limitation, voir AnalysisTarget). La position GPS, elle,
            // EST récupérable : une vidéo filmée avec l'app Appareil photo (Services de localisation
            // actifs) embarque sa propre position dans ses métadonnées QuickTime — on la lit
            // directement du fichier plutôt que d'utiliser la position ACTUELLE du téléphone, qui
            // n'aurait aucun rapport avec l'endroit où la vidéo a réellement été filmée (2026-08-09,
            // demande de Jean-David : toujours donner la position de l'iPhone qui a pris la capture —
            // ici, l'iPhone qui a filmé la vidéo importée, lue depuis ses propres métadonnées).
            let location = await Self.extractEmbeddedLocation(from: movie.url)
            // Date de création embarquée (voir le commentaire dédié ci-dessous) : nécessaire pour
            // que le recoupement ADS-B/astral (pivot du 2026-09-12) vise le bon instant plutôt que
            // l'heure de l'analyse, qui peut être bien plus tardive pour une vidéo déjà existante.
            let creationDate = await Self.extractEmbeddedCreationDate(from: movie.url)
            analysisTarget = AnalysisTarget(videoURL: movie.url, poses: [], initialMode: .night, captureLocation: location, captureStartedAt: creationDate)
        } catch {
            importErrorMessage = "Échec de l'importation : \(error.localizedDescription)"
        }
    }

    /// Lit la position GPS embarquée dans les métadonnées QuickTime d'une vidéo (présente si les
    /// Services de localisation étaient actifs au moment du tournage — cas standard pour une vidéo
    /// filmée avec l'app Appareil photo). `nil` si absente (métadonnées supprimées lors d'un
    /// transfert, localisation désactivée au tournage, etc.) — `ResultsView` affiche alors le
    /// message « position GPS non disponible » existant plutôt qu'une position inventée.
    private static func extractEmbeddedLocation(from url: URL) async -> CLCoordinate? {
        let asset = AVURLAsset(url: url)
        guard let metadataItems = try? await asset.load(.metadata) else { return nil }
        for item in metadataItems {
            guard item.commonKey == .commonKeyLocation || item.identifier == .quickTimeMetadataLocationISO6709,
                  let stringValue = try? await item.load(.stringValue)
            else { continue }
            if let coordinate = parseISO6709(stringValue) {
                return coordinate
            }
        }
        return nil
    }

    /// Lit la date de création embarquée dans les métadonnées QuickTime d'une vidéo (présente pour
    /// une vidéo filmée avec l'app Appareil photo standard) — sert d'heure absolue de captation pour
    /// le recoupement ADS-B/astral (voir `AircraftLookupService`/`CelestialPositionCalculator`,
    /// pivot du 2026-09-12), qui sans cela retomberait sur l'heure de l'ANALYSE (potentiellement
    /// bien plus tardive pour une vidéo déjà existante importée de la bibliothèque). `nil` si
    /// absente (métadonnées supprimées lors d'un transfert, vidéo produite par une autre app) — le
    /// recoupement retombe alors sur l'heure de l'analyse, comme avant cet ajout.
    private static func extractEmbeddedCreationDate(from url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let creationDateItem = try? await asset.load(.creationDate) else { return nil }
        return try? await creationDateItem.load(.dateValue)
    }

    /// Coordonnées ISO 6709 (format standard des métadonnées de localisation QuickTime/EXIF), ex.
    /// `"+45.5017-073.5673+050.000/"` — latitude et longitude signées à largeur variable, altitude
    /// optionnelle. Extraction par expression régulière plutôt qu'un découpage à position fixe : la
    /// largeur des champs varie selon le nombre de décimales.
    private static func parseISO6709(_ string: String) -> CLCoordinate? {
        guard let regex = try? NSRegularExpression(pattern: #"([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let latRange = Range(match.range(at: 1), in: string),
              let lonRange = Range(match.range(at: 2), in: string),
              let lat = Double(string[latRange]), let lon = Double(string[lonRange])
        else { return nil }
        return CLCoordinate(lat: lat, lon: lon)
    }
}

/// Copie la vidéo choisie dans un fichier temporaire propre à l'app, sans charger tout son
/// contenu en mémoire (contrairement à un simple `loadTransferable(type: Data.self)`).
private struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}
