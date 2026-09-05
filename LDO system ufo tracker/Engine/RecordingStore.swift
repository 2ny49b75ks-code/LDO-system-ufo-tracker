// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import Combine
import simd

/// Une image capturée par l'onglet LIVE conserve sa pose ARKit (position + orientation de la
/// caméra, matrice intrinsèque) dans ce fichier annexe au format JSON, à côté de la vidéo —
/// nécessaire pour la triangulation angulaire même en ré-analyse différée, voir `CapturedFrame`.
struct PersistedFramePose: Codable, Timestamped {
    let timestamp: Double
    let transform: [Float]     // simd_float4x4, colonnes concaténées (16 éléments)
    let intrinsics: [Float]    // simd_float3x3, colonnes concaténées (9 éléments)
}

extension simd_float4x4 {
    var flatColumns: [Float] {
        [columns.0.x, columns.0.y, columns.0.z, columns.0.w,
         columns.1.x, columns.1.y, columns.1.z, columns.1.w,
         columns.2.x, columns.2.y, columns.2.z, columns.2.w,
         columns.3.x, columns.3.y, columns.3.z, columns.3.w]
    }

    init?(flatColumns f: [Float]) {
        guard f.count == 16 else { return nil }
        self.init(columns: (
            SIMD4<Float>(f[0], f[1], f[2], f[3]),
            SIMD4<Float>(f[4], f[5], f[6], f[7]),
            SIMD4<Float>(f[8], f[9], f[10], f[11]),
            SIMD4<Float>(f[12], f[13], f[14], f[15])
        ))
    }
}

extension simd_float3x3 {
    var flatColumns: [Float] {
        [columns.0.x, columns.0.y, columns.0.z,
         columns.1.x, columns.1.y, columns.1.z,
         columns.2.x, columns.2.y, columns.2.z]
    }

    init?(flatColumns f: [Float]) {
        guard f.count == 9 else { return nil }
        self.init(columns: (
            SIMD3<Float>(f[0], f[1], f[2]),
            SIMD3<Float>(f[3], f[4], f[5]),
            SIMD3<Float>(f[6], f[7], f[8])
        ))
    }
}

/// Une vidéo enregistrée via l'onglet LIVE, en attente d'être sélectionnée puis analysée
/// (l'enregistrement ne déclenche plus l'analyse automatiquement — voir `CaptureManager`).
struct RecordedSession: Identifiable, Codable, Equatable {
    let id: UUID
    let videoFileName: String
    let posesFileName: String?
    let createdAt: Date
    let mode: CaptureMode
    /// Position GPS demandée au début de l'enregistrement (voir `LocationProvider`) — `nil` si la
    /// permission de localisation n'a pas été accordée ou si aucune position n'a pu être obtenue à
    /// temps. Utilisée uniquement pour situer la capture sur une carte dans les résultats.
    let latitude: Double?
    let longitude: Double?

    init(id: UUID, videoFileName: String, posesFileName: String?, createdAt: Date, mode: CaptureMode, latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id
        self.videoFileName = videoFileName
        self.posesFileName = posesFileName
        self.createdAt = createdAt
        self.mode = mode
        self.latitude = latitude
        self.longitude = longitude
    }

    private enum CodingKeys: String, CodingKey {
        case id, videoFileName, posesFileName, createdAt, mode, latitude, longitude
    }

    // Décodeur personnalisé : les enregistrements sauvegardés avant l'ajout du mode Nuit/Jour ou de
    // la position GPS n'ont pas ces clés — on retombe sur `.night` / `nil` (comportement d'avant)
    // plutôt que de faire échouer la lecture de l'index existant.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        videoFileName = try container.decode(String.self, forKey: .videoFileName)
        posesFileName = try container.decodeIfPresent(String.self, forKey: .posesFileName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        mode = try container.decodeIfPresent(CaptureMode.self, forKey: .mode) ?? .night
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(videoFileName, forKey: .videoFileName)
        try container.encodeIfPresent(posesFileName, forKey: .posesFileName)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(latitude, forKey: .latitude)
        try container.encodeIfPresent(longitude, forKey: .longitude)
    }

    var captureCoordinate: CLCoordinate? {
        guard let latitude, let longitude else { return nil }
        return CLCoordinate(lat: latitude, lon: longitude)
    }
}

/// Gère la liste des vidéos enregistrées via l'onglet LIVE, stockées localement dans le dossier
/// Documents de l'app (indépendant de Photos, pour lister/sélectionner sans permission de lecture
/// étendue de la photothèque — voir la discussion sur le choix de stockage).
final class RecordingStore: ObservableObject {
    @Published private(set) var sessions: [RecordedSession] = []

    let directory: URL
    private let indexURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Recordings", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([RecordedSession].self, from: data)
        else { return }
        sessions = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    @discardableResult
    func add(videoFileName: String, posesFileName: String?, createdAt: Date, mode: CaptureMode, latitude: Double? = nil, longitude: Double? = nil) -> RecordedSession {
        let session = RecordedSession(id: UUID(), videoFileName: videoFileName, posesFileName: posesFileName, createdAt: createdAt, mode: mode, latitude: latitude, longitude: longitude)
        sessions.insert(session, at: 0)
        persistIndex()
        return session
    }

    func delete(_ session: RecordedSession) {
        sessions.removeAll { $0.id == session.id }
        persistIndex()
        try? FileManager.default.removeItem(at: videoURL(for: session))
        if let posesURL = posesURL(for: session) {
            try? FileManager.default.removeItem(at: posesURL)
        }
    }

    func videoURL(for session: RecordedSession) -> URL {
        directory.appendingPathComponent(session.videoFileName)
    }

    func posesURL(for session: RecordedSession) -> URL? {
        guard let name = session.posesFileName else { return nil }
        return directory.appendingPathComponent(name)
    }

    func poses(for session: RecordedSession) -> [PersistedFramePose] {
        guard let url = posesURL(for: session),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([PersistedFramePose].self, from: data)
        else { return [] }
        return decoded
    }
}
