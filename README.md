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

### Remettre tout le monde à 0 (toi seulement)

1. Va sur <https://github.com/Otiston/poe-temple-tracker/actions/workflows/tracker.yml>
2. Clique **Run workflow**, choisis **reset**, puis **Run workflow**.

Seuls les comptes qui ont les droits sur le dépôt (toi) voient ce bouton. Le classement de la
session est archivé dans `state.json` (branche `data`), les joueurs restent dans la liste.
Le choix **sync** force une relecture immédiate de l'historique.

### À savoir

- GitHub lance la tâche « toutes les 5 minutes » mais avec du retard parfois (10-20 min aux
  heures chargées), plus ~5 min de cache : un dépôt apparaît en général en 5 à 15 minutes.
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
- `.github/workflows/tracker.yml` : la tâche GitHub Actions (toutes les 5 min, sync/reset).
- `docs/index.html` : la page (servie par GitHub Pages, et en local par `start.bat`).
- `config.actions.json` : réglages de la version GitHub (aucun secret).
- Branche `data` : `data.json` (ce qu'affiche la page) et `state.json` (historique, joueurs, archives).
