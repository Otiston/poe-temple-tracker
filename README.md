# Temple Tracker — Chronicle of Atzoatl

Une page web qui affiche, pour la guilde, qui a déposé combien de **Chronicle of Atzoatl**
dans le coffre de guilde. Les données viennent de l'historique du coffre
(`pathofexile.com/guild/profile/233281/stash-history`), lu automatiquement toutes les 2 minutes
avec le compte du chef de guilde.

Rien à installer : ça tourne avec Windows PowerShell, déjà présent sur Windows 10/11.

## Règles de comptage

- **+1** quand quelqu'un dépose un temple dans le coffre de guilde.
- **−1** quand quelqu'un retire un temple…
- …**sauf les runners** (`templeRunners` dans `config.json`, par défaut `Otiston`) : c'est leur
  rôle de sortir les temples pour les lancer, donc leurs retraits ne comptent pas
  (ils apparaissent comme « run » dans les derniers mouvements).
- Un joueur qui a participé **reste dans la liste pour toujours**, même après un reset (il repart à 0).
- À égalité, celui qui a atteint son score en premier passe devant.

## Mise en route (5 minutes)

1. **Ouvre `config.json`** (avec le Bloc-notes ; s'il n'existe pas, copie `config.example.json`
   en `config.json`) et remplis :
   - `poesessid` : ton cookie de session pathofexile.com (voir ci-dessous) ;
   - `adminPassword` : un mot de passe à toi (remplace `change-moi`). Il sert uniquement à
     afficher le bouton de reset sur la page.
2. **Double-clique sur `start.bat`**. Une fenêtre noire s'ouvre (le serveur) et la page s'ouvre
   dans ton navigateur : <http://localhost:8080>. Laisse la fenêtre noire ouverte.
3. En bas à droite de la page, clique sur **🔒 Admin**, entre ton mot de passe : la barre
   « Mode chef de guilde » apparaît avec le bouton **Remettre tout le monde à 0**.
   Les autres membres ne voient jamais ce bouton.

### Récupérer le POESESSID

1. Va sur <https://www.pathofexile.com> en étant connecté au compte chef de guilde.
2. Appuie sur **F12** → onglet **Application** (Chrome/Edge) ou **Stockage** (Firefox)
   → **Cookies** → `https://www.pathofexile.com`.
3. Copie la valeur de **POESESSID** (32 caractères) dans `config.json`.

⚠️ Le POESESSID donne accès à ton compte : **ne partage jamais `config.json`**.
Il devient invalide si tu te déconnectes du site ; dans ce cas la page affiche
« Synchro en échec » : recopie le nouveau cookie dans `config.json` (pas besoin de relancer).

## Réglages de `config.json`

| Champ | Rôle |
| --- | --- |
| `guildId` | Identifiant de la guilde (233281). |
| `poesessid` | Cookie de session du compte chef de guilde. |
| `adminPassword` | Mot de passe pour le bouton de reset. |
| `templeRunners` | Comptes dont les retraits ne comptent pas, ex. `["Otiston"]`. Sans `#1234`, tous les comptes de ce nom sont concernés. |
| `firstSessionStart` | Début de la **première** session (heure locale), ex. `"2026-11-26"` ou `"2026-11-26 21:30"`. Les mouvements plus anciens sont ignorés. Ne sert plus après le premier reset. |
| `githubRepo` | Dépôt GitHub où publier les scores (`Otiston/poe-temple-tracker`). Vide = pas de page publique. |
| `port` | Port local de la page (8080). |
| `pollMinutes` | Fréquence de lecture de l'historique (2 min ; évite de descendre sous 1). |
| `itemName` | Objet compté (`Chronicle of Atzoatl`). |

`firstSessionStart` doit être réglé **avant le premier lancement avec le POESESSID** : il
n'est appliqué que tant qu'aucun reset n'a eu lieu, et l'historique plus ancien n'est pas récupéré.

## Le bouton « Remettre tout le monde à 0 »

Il relit une dernière fois l'historique, archive le classement de la session dans
`data/state.json` (rubrique `archives`), puis tout le monde repart à 0 pour la session suivante.
Les noms restent dans la liste.

## La page publique pour la guilde (GitHub)

Le lien à donner à la guilde : **<https://otiston.github.io/poe-temple-tracker/>**

- C'est la même page, en lecture seule, sans bouton admin. Le reset se fait uniquement sur
  ta page locale <http://localhost:8080>.
- Pendant que `start.bat` tourne, ton PC envoie le classement (`data.json`, sur la branche
  `data` du dépôt) à chaque changement de score, et au moins toutes les 15 minutes.
  Il utilise ta connexion GitHub CLI (`gh`) : aucune clé à mettre dans `config.json`.
- GitHub garde le fichier en cache : un dépôt peut mettre jusqu'à ~5 minutes à apparaître.
- PC éteint ou `start.bat` fermé : la page garde les derniers scores et affiche
  « Pas de mise à jour depuis … ».
- Seuls la page, le code et les scores sont publiés : `config.json` (POESESSID, mot de passe)
  et `data/` sont exclus par `.gitignore`.
- Pour arrêter la publication : vide `githubRepo` dans `config.json`.

Sur ta page locale, en mode chef de guilde, une ligne indique l'état de la publication.

## Dépannage

- **« Choisis un mot de passe admin »** au démarrage : change `adminPassword` dans `config.json`.
- **« Impossible d'ouvrir le port 8080 »** : le serveur tourne déjà, ou change `port`.
- **« POESESSID refusé »** : cookie expiré, recopie-le.
- **« Bloqué par Cloudflare »** : pathofexile.com refuse les requêtes automatiques depuis ton PC ;
  réessaie plus tard.
- `data/last-response.json` contient la dernière page brute renvoyée par pathofexile.com
  (utile pour comprendre un comptage bizarre).
- Pour retirer quelqu'un de la liste : arrête le serveur, supprime son nom dans `members`
  de `data/state.json`, relance (il revient s'il a déjà bougé un temple pendant la session en cours).

## Fichiers

- `start.bat` : lance le serveur.
- `server.ps1` : le serveur (lecture de l'historique, comptage, page web, reset, publication).
- `docs/index.html` : la page (servie en local et par GitHub Pages).
- `config.json` : tes réglages (**secret**, jamais publié). Modèle : `config.example.json`.
- `data/state.json` : scores, participants et archives des sessions (créé automatiquement).
