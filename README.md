# Temple Tracker — Chronicle of Atzoatl

Classement de la guilde : qui a apporté combien de **Chronicle of Atzoatl** dans le coffre de
guilde. Les données viennent de l'historique du coffre
(`pathofexile.com/guild/profile/233281/stash-history`).

**Page de la guilde : <https://otiston.github.io/poe-temple-tracker/>**

## Règles de comptage

- **+1** quand quelqu'un dépose un temple dans le coffre de guilde.
- **−1** quand quelqu'un retire un temple…
- …**sauf les runners** (`templeRunners`, par défaut `Otiston`) : c'est leur rôle de sortir les
  temples pour les lancer, donc leurs retraits ne comptent pas (affichés « run »).
- Un joueur qui a déjà déposé un temple **reste dans la liste pour toujours** (à 0 après un reset).
- À égalité, celui qui a atteint son score en premier passe devant.

## Fonctionnement sans PC (GitHub Actions)

Toutes les 5 minutes environ, GitHub relit l'historique du coffre et met à jour la page.
Ton PC n'a pas besoin d'être allumé.

### Mise en place (une seule fois)

Le suivi a besoin de ton cookie **POESESSID** (voir plus bas comment le trouver), rangé comme
**secret** du dépôt : chiffré par GitHub, jamais visible dans le code ni dans les journaux.
Dans un terminal PowerShell, lance :

```powershell
gh secret set POESESSID --repo Otiston/poe-temple-tracker
```

Colle ton POESESSID quand c'est demandé, puis Entrée. (Ou sur le site : dépôt → **Settings** →
**Secrets and variables** → **Actions** → **New repository secret**, nom `POESESSID`.)

Si ton POESESSID est déjà dans `config.json`, cette commande le reprend directement :

```powershell
(Get-Content config.json -Raw | ConvertFrom-Json).poesessid | gh secret set POESESSID --repo Otiston/poe-temple-tracker
```

Dans les journaux de la tâche, la ligne `POESESSID : 32 caracteres, format ok, empreinte …`
permet de vérifier que c'est le bon cookie sans jamais l'afficher.

### Remettre tout le monde à 0 (toi seulement)

**Depuis la page** : en bas, **🔒 Admin** → ton mot de passe admin (celui de `config.json`) →
**Remettre tout le monde à 0**. Il faut l'activer une fois (voir ci-dessous).

- **Reset instantané** (jeton avec la permission *Contents*) : la page écrit elle-même la
  nouvelle session. Tu vois tout le monde à 0 tout de suite ; les autres joueurs le voient au
  prochain rafraîchissement automatique de leur page (moins d'une minute). La page relance
  aussitôt une synchro : les temples déposés juste avant ton clic (pas encore lus) sont ajoutés
  à la session archivée, ceux déposés après comptent dans la nouvelle. Pendant cette minute, la
  session archivée affiche « vérification des derniers dépôts… ».
- **Sans la permission *Contents*** : le reset passe par la tâche GitHub (1 à 2 minutes), et
  la barre admin le signale.

**Depuis GitHub** (toujours possible) : <https://github.com/Otiston/poe-temple-tracker/actions/workflows/tracker.yml>
→ **Run workflow** → **reset** → **Run workflow**. Seuls les comptes qui ont les droits sur le
dépôt voient ce bouton.

Le classement de la session est archivé (`state.json`, branche `data`) et reste visible par
tous en bas de la page, dans **Sessions précédentes** : dates, total de temples, vainqueur, et
le classement complet en cliquant sur une session. Les joueurs restent dans la liste. Un reset
sans aucun mouvement depuis le précédent (double clic, par exemple) n'ajoute pas de session vide.
Le choix **sync** force une relecture immédiate de l'historique.

### Activer le bouton Admin de la page (une fois)

Une page GitHub n'a pas de serveur pour vérifier un mot de passe. Le bouton utilise donc un
jeton GitHub limité à ce dépôt : lancer la tâche, et (pour le reset instantané) écrire les
scores. Ce jeton est publié **chiffré avec ton mot de passe admin**, et c'est ton navigateur
qui le déchiffre quand tu tapes le mot de passe.

1. Crée le jeton : github.com → ta photo → **Settings** → **Developer settings** →
   **Personal access tokens** → **Fine-grained tokens** → **Generate new token**.
   - Nom : `temple-tracker-reset`, expiration : la plus longue proposée.
   - **Repository access** : *Only select repositories* → `poe-temple-tracker`.
   - **Permissions** → **Repository permissions** → **Actions** : *Read and write*.
   - Pour le reset instantané, aussi **Contents** : *Read and write* — seulement une fois le
     dépôt protégé (voir « Sécurité du reset instantané » ci-dessous).
   - **Generate token**, puis copie-le (`github_pat_…`).
2. Dans le dossier du projet, lance :

```powershell
powershell -ExecutionPolicy Bypass -File tools\set-admin-token.ps1
```

   Colle le jeton quand c'est demandé. Le script vérifie qu'il marche, le chiffre avec
   `adminPassword` de `config.json`, publie `docs/admin.json` (chiffré uniquement), puis le
   bouton apparaît sur la page en 1 à 10 minutes.

- La version chiffrée est publique : garde un mot de passe admin **long** (12 caractères ou
  plus) et utilisé nulle part ailleurs. Avec la seule permission *Actions*, quelqu'un qui le
  devinerait pourrait lancer des resets, rien d'autre.
- Ajouter une permission à un jeton existant (son nom → **Edit**) ne change pas le jeton :
  pas besoin de relancer le script.
- Changer de mot de passe : modifie `adminPassword` dans `config.json` et relance le script.
- Jeton expiré (message sur la page) : crée-en un nouveau et relance le script.
- Désactiver : supprime `docs/admin.json` du dépôt et supprime le jeton sur GitHub.

### Sécurité du reset instantané

La permission *Contents* permet d'écrire dans **tout** le dépôt, code compris. Sans protection,
quelqu'un qui devinerait le mot de passe admin pourrait modifier le code lancé par la tâche
GitHub et lui faire envoyer ton POESESSID ailleurs. Avant d'ajouter *Contents* au jeton :

- la branche `main` (le code et la page) est protégée : elle ne change que par une
  *pull request*, que ce jeton ne peut ni créer ni fusionner ;
- le POESESSID est rangé dans l'environnement `poe` du dépôt, réservé à la branche `main` :
  une tâche lancée depuis une autre branche ne le reçoit pas.

Le jeton ne peut alors modifier que les scores (branche `data`), et lancer la tâche.

### Relance automatique fiable (cron-job.org)

La planification interne de GitHub est « au mieux » : elle peut prendre beaucoup de retard, voire
ne jamais démarrer (c'est arrivé ici). Un service gratuit externe demande donc à GitHub de lancer
la synchro toutes les 5 minutes :

1. Crée un jeton GitHub dédié, comme pour le bouton Admin (Fine-grained, nom `temple-tracker-cron`,
   uniquement le dépôt `poe-temple-tracker`, permission **Actions : Read and write**).
2. Crée un compte gratuit sur <https://cron-job.org>, puis **Create cronjob** :
   - **Title** : `Temple tracker`
   - **URL** : `https://api.github.com/repos/Otiston/poe-temple-tracker/actions/workflows/tracker.yml/dispatches`
   - **Execution schedule** : *Every 5 minutes*
   - Onglet **Advanced** :
     - **Request method** : `POST`
     - **Headers** (trois lignes) : `Authorization` = `Bearer github_pat_…` (ton jeton),
       `Accept` = `application/vnd.github+json`, `Content-Type` = `application/json`
     - **Request body** : `{"ref":"main","inputs":{"action":"sync"}}`
   - **Test run** : la réponse attendue est **204** (= tâche lancée). Puis **Create**.

Ce jeton ne permet que de lancer la tâche de ce dépôt. Si un jour il expire, cron-job.org
affichera des échecs (401) : crée un nouveau jeton et remplace-le dans l'en-tête.

### À savoir

- Avec cron-job.org, une synchro part toutes les 5 minutes et met à jour l'heure affichée
  « Synchronisé il y a … » sur la page, qui reste donc entre 0 et 6 minutes. La page lit
  l'API GitHub (60 lectures/heure par connexion) ; au-delà, elle passe sur
  raw.githubusercontent.com, qui peut avoir 5 minutes de retard en plus.
  Si elle affiche « Pas de mise à jour depuis … » (plus de 20 min), regarde l'historique de
  cron-job.org.
- Si le POESESSID expire (déconnexion du site), la page affiche « Synchro en échec » :
  récupère le nouveau cookie et relance la commande `gh secret set` ci-dessus.
- GitHub met en pause les tâches planifiées d'un dépôt public sans activité pendant 60 jours ;
  il prévient par e-mail, un clic dans l'onglet Actions suffit pour réactiver.

### Récupérer le POESESSID

1. Va sur <https://www.pathofexile.com>, connecté au compte chef de guilde.
2. **F12** → onglet **Application** (Chrome/Edge) ou **Stockage** (Firefox) → **Cookies** →
   `https://www.pathofexile.com`.
3. Copie la valeur de **POESESSID** (32 caractères).

⚠️ Il donne accès à ton compte : ne le donne à personne, ne le mets jamais dans un fichier du
dépôt. Ne clique pas « Se déconnecter » sur le site (ça l'annule) : ferme juste l'onglet.

## Réglages (`config.actions.json`)

| Champ | Rôle |
| --- | --- |
| `guildId` | Identifiant de la guilde (233281). |
| `templeRunners` | Comptes dont les retraits ne comptent pas, ex. `["Otiston"]`. Sans `#1234`, tous les comptes de ce nom. |
| `firstSessionStart` | Début de la **première** session, avec le décalage horaire : `"2026-11-26T16:49:00+01:00"`. Ne sert plus après le premier reset. |
| `initialMembers` | Joueurs à afficher dans la liste dès le départ (ils ont déposé avant la session). |
| `itemName` | Objet compté (`Chronicle of Atzoatl`). |

## Version PC (optionnelle)

`start.bat` lance le même suivi sur ton PC, avec une page locale <http://localhost:8080>
(bouton reset protégé par mot de passe). Elle utilise `config.json` (secret, jamais publié ;
modèle : `config.example.json`) et garde son propre classement dans `data/`.
Pour ne pas se mélanger avec la version GitHub, laisse `"githubRepo": ""` dans `config.json`.

## Fichiers

- `server.ps1` : le suivi (lecture de l'historique, comptage, reset, page locale).
- `.github/workflows/tracker.yml` : la tâche GitHub Actions (toutes les 5 min, sync/reset ;
  archive aussi pour de bon les resets faits depuis la page).
- `docs/index.html` : la page (servie par GitHub Pages, et en local par `start.bat`).
- `config.actions.json` : réglages de la version GitHub (aucun secret).
- `tools/set-admin-token.ps1` : active le bouton Admin de la page GitHub (jeton chiffré).
- `docs/admin.json` : ce jeton, chiffré avec le mot de passe admin.
- Branche `data` : `data.json` (ce qu'affiche la page) et `state.json` (historique, joueurs, archives).
