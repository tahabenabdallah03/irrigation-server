# Rapport Total du Systeme d'Irrigation

Date: 2026-04-07  
Projet: irrigation-server

## 1. Resume Executif

Ce projet implemente une plateforme IoT d'irrigation composee de:
- Un backend Node.js/Express connecte a SQLite.
- Une application mobile Flutter pour supervision et commande.
- Une integration LabVIEW pour acquisition des mesures et execution des commandes.

Le systeme supporte:
- Supervision temps reel (WebSocket Socket.IO).
- Pilotage des electrovannes par zone.
- Gestion des seuils capteurs et modes AUTO/MANUAL.
- Historique mixte (evenements + snapshots periodiques).
- Authentification JWT avec hash bcrypt et protections anti-bruteforce.

---

## 2. Perimetre Technique

### 2.1 Cote Serveur
- Fichier principal: server.js
- Runtime: Node.js
- Framework API: Express 5
- Temps reel: Socket.IO
- Base de donnees: SQLite (database.db)
- Authentification: JSON Web Token
- Hash mot de passe: bcrypt
- CORS: active

### 2.2 Cote Mobile Flutter
- Ecrans identifies:
  - dashboard.dart
  - history.dart
- Communication:
  - REST (package http)
  - Socket.IO (package socket_io_client)
- Stockage securise token: flutter_secure_storage
- Notifications locales: flutter_local_notifications

### 2.3 Integration Externe
- LabVIEW envoie les donnees capteurs et etats zones.
- LabVIEW lit les commandes en attente pour execution physique.

---

## 3. Langages, Outils et Bibliotheques

### 3.1 Langages
- JavaScript (backend)
- Dart (Flutter)
- SQL (requetes SQLite)

### 3.2 Dependances Backend (package.json)
- express
- sqlite3
- socket.io
- jsonwebtoken
- bcrypt
- cors

### 3.3 Outils/Technologies Utilises
- API REST JSON
- WebSocket avec Socket.IO
- SQLite avec migrations progressives au demarrage
- Variables d'environnement pour la securite et le reseau

---

## 4. Architecture Fonctionnelle

## 4.1 Flux Global
1. LabVIEW pousse les mesures environnement/zone vers le serveur.
2. Le serveur met a jour l'etat courant dans SQLite.
3. Le serveur enregistre l'historique:
   - Historique evenementiel
   - Historique periodique par timer
4. Le serveur diffuse les changements en temps reel (Socket.IO).
5. L'app Flutter affiche dashboard/historique et envoie les commandes.
6. LabVIEW recupere les commandes a executer.

### 4.2 Separation des Roles
- Serveur: logique metier, persistence, auth, orchestration temps reel.
- Flutter: visualisation, interaction utilisateur, notifications.
- LabVIEW: acquisition terrain et actionneur physique.

---

## 5. Modele de Donnees (SQLite)

Tables principales identifiees:
- environment: historique global (temperature air, humidite air, niveau eau)
- zones: etat courant de chaque zone (mesures, seuils, vanne, mode, activation capteurs)
- zones_history: historique d'etat par zone (changement detecte)
- zones_periodic_history: snapshots periodiques de toutes les zones
- commands: file de commandes/evenements inter-systemes
- users: comptes applicatifs
- zone_alerts: historique des alertes
- zone_active_alerts: alerte active par zone

Points importants:
- Migrations defensives au demarrage via PRAGMA table_info.
- Compatibilite legacy nutrition vers gaz preservee.
- Index SQL crees pour requetage historique et performance.

---

## 6. API REST - Inventaire Complet

### 6.1 Endpoints Generaux
- GET / : test serveur
- GET /health : healthcheck

### 6.2 Authentification
- POST /register
- POST /login
- GET /login (retour 405, message d'usage)

### 6.3 Ingestion LabVIEW
- POST /update-environment
- POST /update-zones
- POST /labview/data

### 6.4 Commandes pour LabVIEW
- GET /command
- GET /labview/command (payload normalise)

### 6.5 Endpoints Mobile Proteges JWT
- GET /dashboard
- GET /alerts
- GET /zone-config
- POST /command
- POST /add-zone
- POST /remove-zone
- POST /update-thresholds
- POST /update-zone-name
- POST /sync-zone-config
- GET /history
- GET /historique

---

## 7. Temps Reel et Evenements Socket.IO

Evenements emis par le serveur:
- environment-update
- zones-update
- zone-alert
- zone-config-update
- history-realtime
- zone-removed

Effet metier:
- Dashboard et historique peuvent se rafraichir sans polling exclusif.
- L'utilisateur voit rapidement les changements de terrain.

---

## 8. Securite

Mecanismes en place:
- JWT Bearer obligatoire sur endpoints sensibles.
- bcrypt pour les mots de passe.
- Validation email/password.
- Limitation des tentatives login par IP (fenetre + blocage temporaire).
- Parametrage de l'expiration JWT.
- Option de desactiver l'inscription publique.

Variables de securite/reseau (.env.example):
- SECRET_KEY
- SINGLE_USER_EMAIL
- SINGLE_USER_PASSWORD
- ALLOW_REGISTER
- AUTH_BCRYPT_ROUNDS
- LOGIN_WINDOW_MS
- LOGIN_MAX_FAILURES
- JWT_EXPIRES_IN
- HOST
- PORT

---

## 9. Application Flutter - Fonctionnalites Observees

### 9.1 Dashboard
- Recuperation token session (secure storage).
- Chargement snapshot dashboard.
- Connexion Socket.IO pour updates temps reel.
- Synchronisation periodique et mecanismes anti-conflits UI.
- Affichage zones, environnement, alertes.
- Notifications locales Android sur alertes.

### 9.2 Historique
- Modes:
  - actions (events)
  - periodic (mesures)
  - mixed
- Filtres:
  - recherche texte
  - zone
  - plage de dates
  - inclusion alertes
- Pagination avec offset/limit.
- Auto-refresh + trigger via event history-realtime.

---

## 10. Logique Metier Cle

- Normalisation d'entrees multi-formats (noms de champs differents entre clients).
- Gestion des seuils capteurs par zone.
- Gestion des modes EV (AUTO/MANUAL).
- Historisation intelligente pour eviter les doublons inutiles.
- Conservation d'une alerte active par zone + historique complet des alertes.
- Generation de snapshots periodiques toutes les 60 secondes.

---

## 11. Performance et Fiabilite

Bonnes pratiques deja presentes:
- Index SQL sur dates et zone_id.
- Deduplication de certains evenements d'alerte.
- Pagination historique.
- Separation event history vs periodic history.

Points de vigilance:
- Logging complet du payload LabVIEW peut devenir couteux a haute frequence.
- PORT est fixe a 8080 dans le code; la variable d'environnement PORT devrait etre appliquee partout.
- URL backend mobile actuellement en dur dans le code Flutter.

---

## 12. Qualite et Maintenabilite

Points positifs:
- Code serveur richement structure en blocs fonctionnels.
- Compatibilite schema legacy prise en compte.
- API historique evoluee et exploitable.

Lacunes identifiees:
- README tres minimal (pas de guide complet d'installation/exploitation).
- Peu ou pas de tests automatises visibles.
- Pas de separation explicite en modules backend (tout concentre dans server.js).

---

## 13. Recommandations Priorisees

### Priorite Haute (P1)
1. Rendre PORT configurable depuis process.env.PORT de facon effective.
2. Externaliser baseUrl Flutter selon environnement (dev/test/prod).
3. Limiter/structurer les logs de /labview/data (niveau, taille, echantillonnage).
4. Ajouter un README operationnel complet.

### Priorite Moyenne (P2)
1. Ajouter tests backend (auth, commandes, historique).
2. Introduire validation schema des payloads (ex: zod/joi).
3. Scinder server.js en modules (auth, history, labview, zones).

### Priorite Basse (P3)
1. Ajouter observabilite (metrics, tracing leger).
2. Ajouter scripts de backup/recovery SQLite.
3. Formaliser versionning API.

---

## 14. Checklist de Deploiement

1. Definir un SECRET_KEY robuste.
2. Definir SINGLE_USER_PASSWORD fort.
3. Configurer HOST et PORT selon l'environnement.
4. Verifier exposition reseau pour acces mobile et LabVIEW.
5. Demarrer le serveur avec npm start.
6. Verifier:
   - GET /health
   - login + token
   - GET /dashboard
   - flux Socket.IO
7. Tester cycle complet:
   - commande mobile -> lecture LabVIEW
   - donnee LabVIEW -> dashboard mobile
   - historique actions + mesures

---

## 15. Conclusion

Le systeme est deja avance et couvre les besoins critiques d'une plateforme d'irrigation intelligente:
- supervision,
- commande,
- historique,
- alertes,
- securite de base,
- temps reel.

Avec les ameliorations P1, il peut passer d'un prototype solide a une base quasi-production plus fiable, maintenable et simple a deployer.
