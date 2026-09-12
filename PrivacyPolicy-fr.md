# Politique de confidentialité — LDO (Détecteur d'OVNI)

**Dernière mise à jour : 12 septembre 2026**

Cette politique de confidentialité décrit comment l'application LDO — Détecteur d'OVNI
(« l'Application ») traite les renseignements lorsque vous l'utilisez.

---

## 1. Résumé en un coup d'œil

- Depuis la version du pivot technique de septembre 2026, LDO envoie une **position GPS
  approximative et l'heure de la capture** au réseau public **OpenSky Network**
  (opensky-network.org), uniquement pour vérifier si un avion connu se trouvait dans la direction
  observée, et télécharge une liste publique de satellites brillants depuis **CelesTrak**
  (celestrak.org) pour le même type de vérification — voir la section 2bis ci-dessous pour le
  détail complet de ces échanges.
- En dehors de ces deux appels ponctuels, LDO **n'envoie aucune autre donnée à un serveur
  externe ni à Anthropic, Apple ou tout autre tiers**.
- Toutes les autres analyses (vidéo, photos, forme, illumination) sont effectuées **entièrement sur
  votre appareil**.
- Vos vidéos et photos sont enregistrées **uniquement dans votre photothèque personnelle**
  (appareil + iCloud, si vous avez vous-même activé iCloud Photos dans les réglages de votre iPhone).
- LDO **n'affiche aucune publicité** et **ne contient aucun outil de suivi publicitaire**.
- LDO **ne vend et ne partage aucune donnée** avec des tiers, au-delà de l'appel décrit ci-dessus.

## 2. Renseignements traités par l'Application

| Type de donnée | Utilisation | Où elle est conservée |
|---|---|---|
| Vidéo et images (caméra) | Capture de l'objet observé et analyse (forme, trajectoire, illumination) | Sur votre appareil, puis dans votre photothèque (appareil + iCloud si activé par vous) |
| Son (microphone) | Analyse du son associé à la vidéo capturée | Traité localement, conservé uniquement dans le fichier vidéo enregistré dans votre photothèque |
| Position approximative | Affichage de la trajectoire estimée sur une carte, dans la page de résultats ; et recoupement ADS-B (voir section 2bis) | Traitée localement pour l'affichage de la carte ; envoyée à OpenSky Network uniquement pour le recoupement ADS-B |
| Position et orientation de la caméra (ARKit) | Calcul de la direction réelle observée (boussole), utilisée pour la trajectoire angulaire et le recoupement ADS-B/astronomique | Traitées localement ; conservées uniquement dans le fichier annexe d'un enregistrement LIVE, pour permettre une ré-analyse ultérieure |

Aucun compte utilisateur, aucune adresse courriel et aucun identifiant publicitaire ne sont
collectés par l'Application elle-même.

## 2bis. Recoupement avec des données publiques externes (OpenSky Network, CelesTrak)

Pour vérifier si un avion réel et actuellement en vol se trouvait dans la direction que vous avez
filmée, LDO envoie une requête au service public **OpenSky Network** (opensky-network.org),
uniquement lorsque : (1) votre position GPS est disponible, (2) l'analyse a lieu peu après la
captation (moins d'une heure — au-delà, LDO n'envoie aucune requête, le service ne couvrant que le
trafic aérien en temps réel).

Cette requête transmet une zone géographique approximative (calculée à partir de votre position, un
rayon d'environ 100 km) — **jamais votre position exacte au mètre près, ni aucun autre
renseignement vous concernant** (pas de nom, pas d'identifiant, pas de vidéo). OpenSky Network
retourne en réponse la liste des avions actuellement signalés dans cette zone (position, altitude,
indicatif de vol) — LDO compare cette liste à la direction que vous avez filmée, entièrement sur
votre appareil, pour déterminer s'il y a une correspondance.

LDO ne contrôle pas les pratiques de confidentialité d'OpenSky Network, un service tiers
indépendant. Vous pouvez consulter sa propre politique sur opensky-network.org.

Dans les mêmes conditions (position GPS disponible, analyse peu après la captation), LDO télécharge
aussi la liste publique des satellites les plus brillants visibles à l'œil nu (dont la Station
spatiale internationale) depuis **CelesTrak** (celestrak.org), pour le même type de comparaison
directionnelle. Cette liste est la même pour tous les utilisateurs à un moment donné — **aucune
donnée vous concernant n'est envoyée à CelesTrak**, seule une requête de téléchargement standard.

## 3. Permissions demandées sur votre appareil

L'Application demande votre autorisation avant d'accéder à :
- **Caméra** — pour filmer l'objet observé
- **Microphone** — pour analyser le son de la vidéo
- **Position (lorsque l'app est utilisée)** — pour situer la trajectoire sur une carte
- **Photos (ajout uniquement)** — pour enregistrer la vidéo et les photos dans votre photothèque

Vous pouvez retirer chacune de ces autorisations en tout temps dans **Réglages > LDO** sur
votre iPhone. Le retrait d'une autorisation peut limiter certaines fonctions de l'Application
(par exemple, sans microphone, l'analyse du son ne sera pas disponible).

## 4. Stockage et synchronisation iCloud

Si vous avez activé **iCloud Photos** dans les réglages de votre appareil (indépendamment de
LDO), vos vidéos et photos enregistrées par l'Application sont synchronisées avec votre compte
iCloud personnel, selon les conditions d'utilisation d'Apple. LDO ne gère pas cette
synchronisation directement et n'a accès à votre compte iCloud d'aucune autre façon.

## 5. Partage avec des tiers

En dehors du recoupement ADS-B décrit à la section 2bis (une zone géographique approximative et
l'heure de la capture, envoyées à OpenSky Network), LDO ne partage, ne vend et ne loue aucun
renseignement à des tiers. L'Application ne contient aucun kit de développement logiciel (SDK)
publicitaire ni outil d'analyse comportementale tiers.

## 6. Conservation et suppression des données

Les vidéos et photos demeurent dans votre photothèque jusqu'à ce que vous les supprimiez
vous-même via l'application Photos d'Apple. LDO ne conserve pas de copie séparée en dehors de
ce que vous voyez dans votre photothèque.

## 7. Enfants

L'Application est classée 4+ sur l'App Store et ne cible pas spécifiquement les enfants. Elle ne
collecte sciemment aucun renseignement personnel auprès d'enfants de moins de 13 ans (ou de
l'âge minimal applicable selon votre juridiction).

## 8. Vos droits

Selon votre lieu de résidence (notamment au Québec, en vertu de la *Loi sur la protection des
renseignements personnels dans le secteur privé*, ou dans l'Union européenne en vertu du RGPD),
vous pouvez avoir le droit de demander l'accès, la rectification ou la suppression de vos
renseignements personnels. Puisque LDO ne collecte et ne conserve aucun renseignement sur ses
propres serveurs, l'exercice de ces droits s'effectue directement sur votre appareil (suppression
des photos/vidéos, retrait des autorisations).

## 9. Modifications de cette politique

Cette politique peut être mise à jour à l'occasion des futures versions de l'Application. La date
de dernière mise à jour figure en haut de ce document.

## 10. Nous joindre

Pour toute question concernant cette politique de confidentialité :
**Courriel : jdgeg@icloud.com**
