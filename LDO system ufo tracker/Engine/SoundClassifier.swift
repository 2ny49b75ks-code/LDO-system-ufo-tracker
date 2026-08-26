// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import SoundAnalysis
import AVFoundation
import AVFAudio

/// Étape 7 : analyse du son de la vidéo.
/// Utilise le classificateur sonore intégré d'Apple (SoundAnalysis / SNClassifySoundRequest),
/// qui reconnaît nativement plusieurs centaines de catégories sonores — dont plusieurs
/// directement utiles ici : "Aircraft", "Propeller, airscrew", "Helicopter", "Fixed-wing aircraft,
/// airplane", "Buzz" (insecte), "Bird vocalization, bird call, bird song". Aucun modèle personnalisé
/// n'est nécessaire pour cette étape.
final class SoundClassifier {

    /// Confiance minimale sous laquelle on ne retient pas une catégorie (évite les faux positifs
    /// sur un son ambiant faible ou du bruit de vent). Abaissé de 0,5 à 0,3 (2026-08-09, signalé par
    /// Jean-David : un avion de ligne clairement audible à l'oreille sur sa vidéo n'était pas détecté)
    /// — un moteur d'avion filmé à distance avec un micro de téléphone, souvent partiellement couvert
    /// par le bruit de vent/de prise en main, ne franchissait quasiment jamais le seuil de 0,5 même
    /// quand le classificateur identifiait correctement la bonne catégorie. Reste au-dessus du bruit
    /// de fond pur (un classificateur qui hésite entre plusieurs étiquettes sans aucune ne dépassant
    /// même 0,3 reflète une vraie incertitude, pas un simple son distant).
    private let confidenceThreshold: Double = 0.3

    /// Seuil plus bas pour un deuxième palier "probable" plutôt que de rejeter silencieusement toute
    /// étiquette sous 0,3 (2026-08-25, même cas que ci-dessus) — un son distant et partiellement
    /// couvert par le vent franchit souvent ce plancher sans jamais atteindre 0,3, alors que
    /// l'étiquette elle-même reste correcte plus souvent qu'au hasard à ce niveau de confiance.
    private let lowConfidenceThreshold: Double = 0.15

    /// Correspondance entre les étiquettes du classificateur Apple et les catégories utiles à LDO.
    /// Catégories moteur/avion élargies (2026-08-09) : la seule présence de "Aircraft"/"Fixed-wing
    /// aircraft, airplane" ne couvrait pas les cas où le classificateur identifie plus spécifiquement
    /// le BRUIT DE MOTEUR entendu (jet lointain, hélice) sans forcément reconnaître la silhouette
    /// "avion" en tant que telle depuis le son seul.
    /// Catégories élargies une deuxième fois (2026-08-25, signalé par Jean-David : un avion de ligne
    /// clairement audible sur sa vidéo ressortait encore "Aucun son distinctif détecté") — le
    /// classificateur Apple étiquette parfois un moteur d'avion filmé à distance sous une catégorie
    /// plus générique (bruit moteur/véhicule) sans forcément retenir l'étiquette spécifique "Aircraft"
    /// / "Jet engine", surtout mêlé au bruit de vent du micro du téléphone.
    private let categoryMapping: [String: String] = [
        "Aircraft": "avion",
        "Fixed-wing aircraft, airplane": "avion",
        "Aircraft engine": "avion",
        "Jet engine": "avion",
        "Propeller, airscrew": "avion ou drone à hélice",
        "Helicopter": "hélicoptère",
        "Drone": "drone",
        "Buzz": "insecte",
        "Insect": "insecte",
        "Bird vocalization, bird call, bird song": "oiseau",
        "Bird": "oiseau",
        "Wind noise (microphone)": "vent (aucune source identifiable)",
        "Vehicle": "moteur (véhicule/aéronef, type non précisé)",
        "Engine": "moteur (type non précisé, cohérent avec avion/drone)",
        "Engine starting": "moteur (type non précisé, cohérent avec avion/drone)",
        "Idling": "moteur (type non précisé, cohérent avec avion/drone)",
        "Accelerating, revving, vroom": "moteur (type non précisé, cohérent avec avion/drone)",
        "Hum": "bourdonnement moteur (type non précisé)",
        "Rumble": "grondement moteur/aéronef lointain",
        "White noise": "bruit large bande (vent ou moteur lointain, non identifiable avec certitude)"
    ]

    func classifySound(videoURL: URL?, completion: @escaping (SoundResult) -> Void) {
        guard let videoURL else {
            completion(SoundResult(label: "Aucune piste audio disponible", matchedCategory: nil, confidence: 0))
            return
        }

        // Diagnostic explicite plutôt qu'un "aucun son détecté" trompeur : sans permission micro,
        // l'enregistrement n'a jamais capté d'audio du tout (voir CaptureManager), donc TOUTE analyse
        // échouera silencieusement — l'utilisateur a besoin de savoir que c'est un réglage à changer
        // dans Réglages > LDO > Micro, pas un vrai "aucun son distinctif".
        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            completion(SoundResult(label: "Micro refusé — activez-le dans Réglages > LDO pour analyser le son", matchedCategory: nil, confidence: 0))
            return
        case .undetermined:
            completion(SoundResult(label: "Permission micro jamais accordée — activez-la dans Réglages > LDO", matchedCategory: nil, confidence: 0))
            return
        case .granted:
            break
        @unknown default:
            break
        }

        // `SNAudioFileAnalyzer` s'appuie sur `AVAudioFile`, qui n'ouvre fiablement que des fichiers
        // purement audio (WAV, CAF, M4A...) — pas un conteneur vidéo .mov (HEVC + AAC), même si la
        // piste audio existe bel et bien dedans. Lui passer directement `videoURL` échouait
        // silencieusement avec "Couldn't open audio file" à chaque analyse (bug signalé par
        // Jean-David, confirmé par le message d'erreur exact). On extrait donc d'abord la piste
        // audio seule dans un fichier temporaire .m4a avant de l'analyser.
        extractAudioTrack(from: videoURL) { [weak self] audioURL in
            guard let self else { return }
            guard let audioURL else {
                completion(SoundResult(label: "Analyse audio impossible (extraction de la piste audio échouée)", matchedCategory: nil, confidence: 0))
                return
            }
            do {
                let analyzer = try SNAudioFileAnalyzer(url: audioURL)
                let request = try SNClassifySoundRequest(classifierIdentifier: .version1)

                let observer = ClassificationObserver { results in
                    let best = self.bestMatch(among: results)
                    try? FileManager.default.removeItem(at: audioURL)
                    completion(best)
                }

                try analyzer.add(request, withObserver: observer)
                analyzer.analyze()
            } catch {
                try? FileManager.default.removeItem(at: audioURL)
                completion(SoundResult(label: "Analyse audio impossible (\(error.localizedDescription))", matchedCategory: nil, confidence: 0))
            }
        }
    }

    /// Exporte uniquement la piste audio de `videoURL` vers un fichier .m4a temporaire, seul format
    /// fiable pour `SNAudioFileAnalyzer` (voir commentaire ci-dessus).
    private func extractAudioTrack(from videoURL: URL, completion: @escaping (URL?) -> Void) {
        let asset = AVURLAsset(url: videoURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            completion(nil)
            return
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.exportAsynchronously {
            completion(exportSession.status == .completed ? outputURL : nil)
        }
    }

    private func bestMatch(among results: [(identifier: String, confidence: Double)]) -> SoundResult {
        // Ne retient que les étiquettes pertinentes pour LDO, à la confiance la plus élevée.
        let relevantAboveMain = results
            .compactMap { result -> (String, Double)? in
                guard let mapped = categoryMapping[result.identifier], result.confidence >= confidenceThreshold else { return nil }
                return (mapped, result.confidence)
            }
            .sorted { $0.1 > $1.1 }

        if let top = relevantAboveMain.first {
            return SoundResult(
                label: "Son cohérent avec : \(top.0) (\(Int(top.1 * 100))% de confiance)",
                matchedCategory: top.0,
                confidence: top.1
            )
        }

        // Palier "probable" (2026-08-25) : rien n'a atteint le seuil principal, mais une catégorie
        // pertinente reste au-dessus du plancher plus bas — mieux vaut la montrer, marquée comme
        // incertaine, qu'afficher "aucun son" alors que le classificateur a bien détecté quelque chose.
        let relevantLowConfidence = results
            .compactMap { result -> (String, Double)? in
                guard let mapped = categoryMapping[result.identifier], result.confidence >= lowConfidenceThreshold else { return nil }
                return (mapped, result.confidence)
            }
            .sorted { $0.1 > $1.1 }

        guard let lowTop = relevantLowConfidence.first else {
            return SoundResult(label: "Aucun son distinctif détecté", matchedCategory: nil, confidence: 0)
        }
        return SoundResult(
            label: "Son probablement cohérent avec : \(lowTop.0) (\(Int(lowTop.1 * 100))% de confiance — faible, à confirmer)",
            matchedCategory: lowTop.0,
            confidence: lowTop.1
        )
    }
}

/// Pont entre le callback SNResultsObserving (Objective-C style) et Swift concurrency-friendly closure.
private final class ClassificationObserver: NSObject, SNResultsObserving {
    private var allResults: [(identifier: String, confidence: Double)] = []
    private let onComplete: ([(identifier: String, confidence: Double)]) -> Void

    init(onComplete: @escaping ([(identifier: String, confidence: Double)]) -> Void) {
        self.onComplete = onComplete
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classificationResult = result as? SNClassificationResult else { return }
        for classification in classificationResult.classifications {
            allResults.append((classification.identifier, classification.confidence))
        }
    }

    func requestDidComplete(_ request: SNRequest) {
        onComplete(allResults)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        onComplete(allResults)
    }
}

struct SoundResult {
    let label: String
    let matchedCategory: String?
    let confidence: Double
}
