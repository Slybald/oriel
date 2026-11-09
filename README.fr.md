# Oriel

App macOS native qui transforme la notch du MacBook en petit panneau pour tout le monde. Survole la notch : elle se
déplie avec un lecteur, ton agenda et ses réunions, des réglages rapides, une étagère, l'historique du
presse-papiers, un minuteur, des notes rapides et, si tu le veux, tes messages et tes e-mails. Si tu utilises Claude
Code ou Codex, deux onglets optionnels suivent leurs sessions et te laissent leur répondre depuis la notch. Ni l'un ni
l'autre n'est nécessaire pour utiliser l'app.

> **Première ouverture ?** macOS bloque le premier lancement : voir [Premier lancement](#premier-lancement) (30 secondes).
> **Anciennement Claude Notch.** Mise à jour depuis la 2.1 ou avant : voir [la note plus bas](#mises-à-jour).

<p align="center">
  <img src="docs/collapsed.png" width="380" alt="Notch repliée : une main levée sur l'oreille gauche, 2·2 sur l'oreille droite">
</p>
<p align="center">
  <img src="docs/expanded.png" width="620" alt="Panneau déplié avec trois sessions : une qui attend une permission, une qui lance une commande avec sa liste de tâches, une terminée">
</p>

Interface en anglais et en français (suit la langue du système). Les captures utilisent des données fictives.

*Projet indépendant, ni affilié à Anthropic ni approuvé par Anthropic. Claude est une marque d'Anthropic.*

[English version](README.md) · [Guide complet](docs/GUIDE.fr.md)

## Fonctionnalités

- **Dix onglets, tous facultatifs** : Lecteur (avec une semaine de ton calendrier), Agenda (ton prochain rendez-vous
  et son bouton **Rejoindre**), Réglages rapides (Wi-Fi, Bluetooth, Concentration, Économie d'énergie, caféine,
  ventilateurs, batteries, scènes), Étagère, Presse-papiers, Minuteur et Pomodoro, Notes rapides et, désactivés par
  défaut, Messages, Mail et Micro et caméra. Masque-les, change leur ordre ou choisis celui qui s'ouvre dans Réglages ›
  Onglets, ou directement dans la notch.
- **Intercalaires sur la notch repliée** : le morceau en cours, le minuteur, le prochain rendez-vous, les messages non
  lus… chacun a son petit intercalaire contre la notch. Survole-le pour ses détails, clique pour ouvrir son onglet.
- **Pop-ups** pour un message, un e-mail, la fin d'un minuteur ou un rendez-vous proche. Pendant une réunion ou quand
  un micro est utilisé, ils cachent l'expéditeur et le texte.
- **Barre de commande** : `t 25` lance un minuteur, `n idée` crée une note, `c lien` cherche dans tes copies,
  `s présentation` applique une scène. Rien ne s'exécute avant Entrée.
- **Bulle** : tire le coin du panneau ouvert et la notch se détache en une bulle que tu poses où tu veux.
- **Écrans sans notch** (écran externe, Mac sans notch) : une petite perle pendant une activité, qui devient une notch
  en verre dépoli quand le pointeur approche.
- **Tes scripts** peuvent afficher un court état à côté de la notch : `notch run -- make` montre un sablier, puis ✓ ou ✗.
- **Santé** (Réglages › Santé) : ce qu'Oriel fait tourner et ce que ça coûte. La notch allège ses animations toute
  seule en économie d'énergie ou quand le Mac chauffe.

En option, si tu utilises ces agents de code :

- **Claude Code** : l'état de chaque session d'un coup d'œil (réflexion, outil en cours, attend ta réponse, terminé),
  sa liste de tâches et ses sous-agents et, si tu l'actives, des réponses depuis la notch : autoriser ou refuser une
  permission, répondre à une question, approuver un plan, écrire à une session.
- **Codex** (en ligne de commande ou dans l'app ChatGPT) : le même suivi, et les approbations depuis la notch.
- **Jauges de quota** des fenêtres de 5 heures et de 7 jours pour les deux.

Chaque onglet et chaque réglage en détail : [docs/GUIDE.fr.md](docs/GUIDE.fr.md).

## Installation

1. Télécharge `Oriel-<version>.dmg` depuis la page [Releases](https://github.com/Slybald/oriel/releases).
2. Ouvre-le et glisse **Oriel** sur **Applications**.
3. Facultatif : vérifie le téléchargement avec le fichier `.sha256` publié à côté :
   `shasum -a 256 -c Oriel-<version>.dmg.sha256` (dans le dossier du téléchargement).

### Premier lancement

Oriel n'est pas notarisée (pas de compte Apple Developer ; les releases sont signées avec un
certificat auto-signé) : macOS la bloque à la première ouverture. Ce n'est pas un virus, il faut juste le dire à
macOS une fois. Les mêmes étapes sont dans un fichier texte à l'intérieur du DMG.

- **macOS 13 et 14** : clic droit (ou Ctrl + clic) sur **Oriel** dans Applications › **Ouvrir** › **Ouvrir**.
- **macOS 15 et après** : ouvre Oriel, ferme l'alerte, va dans **Réglages Système › Confidentialité et
  sécurité**, descends et clique sur **Ouvrir quand même** à côté du message sur Oriel, puis confirme.
- Ou, dans le Terminal :

  ```sh
  xattr -dr com.apple.quarantine /Applications/Oriel.app
  ```

Le certificat est le même à chaque release : macOS reconnaît chaque mise à jour comme la même app et garde les
accès que tu as accordés (calendrier, Bluetooth, Automation, dossiers). Les versions précédentes étaient
signées ad hoc, une signature qui change à chaque build : au passage à la première release signée avec le
certificat, macOS redemande ces accès une dernière fois, puis plus jamais.

Au premier lancement, un court assistant te laisse choisir tes onglets et la façon d'ouvrir le panneau. **Passer**
est toujours là et ne change rien. Détails : [Assistant de configuration](docs/GUIDE.fr.md#assistant-de-configuration).

### Prérequis

- macOS 13 Ventura ou plus récent, Apple silicon ou Intel.
- Pour l'onglet Claude seulement : Claude Code (CLI, ou onglet Code de Claude Desktop).
- Pour l'onglet Codex seulement : Codex (l'app ChatGPT ou la commande `codex`), versions 0.154 (commande) et 0.162 (app)
  testées, hooks activés (par défaut).
- Configuration de Claude Code dans `~/.claude`. `CLAUDE_CONFIG_DIR` n'est pas pris en charge par l'app :
  les hooks sont toujours installés dans `~/.claude`.

## Mises à jour

Oriel se met à jour seule depuis la page [Releases](https://github.com/Slybald/oriel/releases).

- 60 secondes après le lancement, puis toutes les 6 heures, l'app demande à GitHub la dernière release
  (`api.github.com` ; seule la version de l'app part, dans le User-Agent). Brouillons et préversions sont
  ignorés.
- Une version plus récente est téléchargée avec sa signature (`Oriel-<version>.dmg.sig`) et n'est
  installée que si sa signature Ed25519 correspond à la clé publique intégrée à l'app. Un DMG sans signature,
  ou à la signature invalide, est refusé et rien n'est installé.
- Au lancement, la nouvelle version s'installe tout de suite ; ensuite, seulement quand aucune session n'est
  en cours ni ne t'attend (sinon l'app réessaie toutes les 10 minutes). L'app redémarre alors seule et le
  menu **…** affiche « Mis à jour en X ».
- L'installation automatique demande que l'app soit dans `/Applications` ou `~/Applications`, dans un dossier
  où tu peux écrire. Sinon, le menu **…** propose d'ouvrir la page de la release.
- Pour la désactiver : menu **…** › décoche **Mises à jour automatiques**. Les nouvelles versions sont alors
  seulement signalées dans le menu, avec un bouton **Installer**. **Rechercher les mises à jour** vérifie
  tout de suite.
- Une app compilée depuis les sources (`scripts/build.sh`, `scripts/install.sh`) ne se met jamais à jour
  seule : le menu affiche « Build de développement : mises à jour désactivées ».
- **Mise à jour depuis la 2.1 ou avant** (quand l'app s'appelait encore Claude Notch) : la mise à jour
  automatique ne peut pas passer le renommage. Télécharge `Oriel-<version>.dmg` une fois à la main et glisse **Oriel**
  sur Applications (elle remplace l'ancienne app), puis redonne les accès macOS demandés. Tes réglages, tes notes et
  tes hooks sont repris au premier lancement (dossier de données, ouverture à la connexion, hooks de Claude Code
  déplacés vers les nouveaux noms ; les hooks Codex gardent leur approbation). Ensuite, les mises à jour redeviennent automatiques. Si tu avais activé
  l'autorisation des ventilateurs ou de l'économie d'énergie, refais-le dans les Réglages ; les anciennes règles se
  retirent avec `sudo rm /etc/sudoers.d/claude-notch-*` et
  `sudo rm /Library/PrivilegedHelperTools/io.github.slybald.claudenotch.fanctl`.

## Confidentialité

- Tout reste sur ton Mac : pas de compte, pas de statistiques. Les seules requêtes sortantes sont la vérification des
  mises à jour et le téléchargement des nouvelles versions depuis GitHub.
- L'app n'écoute que sur `127.0.0.1`, et chaque requête doit porter un jeton que seul ton compte peut lire.
- Rien n'est approuvé par défaut : quand la notch ne répond pas à une demande de Claude ou de Codex, elle repart vers
  le terminal.
- Presse-papiers : les copies faites dans un gestionnaire de mots de passe ne sont jamais enregistrées, et
  l'historique reste en mémoire sauf si tu choisis de le garder.
- Les autorisations macOS ne sont demandées que quand tu utilises la fonction qui en a besoin, jamais au lancement.

Ce que l'app lit et écrit, et chaque autorisation : [Confidentialité](docs/GUIDE.fr.md#confidentialité) et
[Autorisations macOS](docs/GUIDE.fr.md#autorisations-macos) dans le guide.

## Désinstallation

Menu **…** › **Désinstaller Oriel…** retire les hooks (ceux de Claude Code, et ceux de Codex si tu les as installés) et ce
que l'app a installé, puis la quitte.
Jette ensuite `Oriel.app` du dossier Applications à la Corbeille.

## Documentation

- [Guide](docs/GUIDE.fr.md) : chaque onglet et chaque réglage, confidentialité et autorisations en détail,
  fonctionnement, limites.
- [API locale](docs/API.md) (en anglais) : la commande `notch` et l'API HTTP pour tes scripts.
- [Développement](docs/DEVELOPMENT.md) (en anglais) : compilation, tests, publication.
- [Architecture](docs/ARCHITECTURE.md) (en anglais) : carte du code et décisions de conception.

## Licence

[MIT](LICENSE).

Code tiers : `Vendor/mediaremote-adapter` (ungive/mediaremote-adapter, BSD-3-Clause, copié sans modification).
Sa notice figure dans **À propos › Licences**.
