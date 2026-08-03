// ============================================================
// CONFIDENTIEL — JDG Entrepreneur général inc.
// Projet LDO — Usage interne uniquement. Ne pas distribuer,
// copier ou partager sans autorisation écrite.
// ============================================================

import Foundation
import SoundAnalysis
import AVFoundation

/// Étape 7 : analyse du son de la vidéo.
/// Utilise le classificateur sonore intégré d'Apple (SoundAnalysis / SNClassifySoundRequest),
/// qui reconnaît nativement plusieurs centaines de catégories sonores — dont plusieurs
/// directement utiles ici : "Aircraft", "Propeller, airscrew", "Helicopter", "Fixed-wing aircraft,
/// airplane", "Buzz" (insecte), "Bird vocalization, bird call, bird song". Aucun modèle personnalisé
/// n'est nécessaire pour cette étape.
final class SoundClassifier {

    /// Confiance minimale sous laquelle on ne retient pas une catégorie (évite les faux positifs
    /// sur un son ambiant faible ou du bruit de vent).
    private let confidenceThreshold: Double = 0.5

    /// Correspondance entre les étiquettes du classificateur Apple et les catégories utiles à LDO.
    private let categoryMapping: [String: String] = [
        "Aircraft": "avion",
        "Fixed-wing aircraft, airplane": "avion",
        "Propeller, airscrew": "avion ou drone à hélice",
        "Helicopter": "hélicoptère",
        "Drone": "drone",
        "Buzz": "insecte",
        "Insect": "insecte",
        "Bird vocalization, bird call, bird song": "oiseau",
        "Bird": "oiseau",
        "Wind noise (microphone)": "vent (aucune source identifiable)"
    ]

    func classifySound(videoURL: URL?, completion: @escaping (SoundResult) -> Void) {
        guard let videoURL else {
            completion(SoundResult(label: "Aucune piste audio disponible", matchedCategory: nil, confidence: 0))
            return
        }

        do {
       let analyzer = try SNAudioFileAnalyzer(url: videoURL)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)

            let observer = ClassificationObserver { [weak self] results in
                guard let self else { return }
                let best = self.bestMatch(among: results)
                completion(best)
            }

            try analyzer.add(request, withObserver: observer)
            analyzer.analyze()
        } catch {
            completion(SoundResult(label: "Analyse audio impossible (\(error.localizedDescription))", matchedCategory: nil, confidence: 0))
        }
    }

    private func bestMatch(among results: [(identifier: String, confidence: Double)]) -> SoundResult {
        // Ne retient que les étiquettes pertinentes pour LDO, à la confiance la plus élevée.
        let relevant = results
            .compactMap { result -> (String, Double)? in
                guard let mapped = categoryMapping[result.identifier], result.confidence >= confidenceThreshold else { return nil }
                return (mapped, result.confidence)
            }
            .sorted { $0.1 > $1.1 }

        guard let top = relevant.first else {
            return SoundResult(label: "Aucun son distinctif détecté", matchedCategory: nil, confidence: 0)
        }
        return SoundResult(
            label: "Son cohérent avec : \(top.0) (\(Int(top.1 * 100))% de confiance)",
            matchedCategory: top.0,
            confidence: top.1
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
