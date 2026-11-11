# Guide d'Oriel

Tout ce que le [README](../README.fr.md) ne détaille pas : chaque onglet, chaque réglage, ce que l'app lit et
écrit, son fonctionnement et ses limites. [English version](GUIDE.md).

## Fonctionnalités en détail

- **États des sessions** : prête, réfléchit, outil en cours (avec la commande ou le fichier), attend ta
  permission, attend ta réponse, plan à valider, terminé, erreur, compacte le contexte. Les sessions qui
  t'attendent passent en tête, avec un contour ambre.
- **Pop-ups** : un petit pop-up descend de la notch repliée pour un message, un mail, Claude ou Codex, la fin d'un
  minuteur ou un rendez-vous proche, pour les onglets activés. Le survol le garde ouvert, un clic ouvre l'onglet (Réglages › Général). Pendant une réunion avec un lien, une recopie d'écran ou quand un micro est utilisé, le pop-up cache l'expéditeur et le texte. Ce n'est pas une protection totale : un partage d'écran sans micro ouvert n'est pas détecté.
- **Notch repliée avec des intercalaires** : chaque activité (Claude, lecture en cours, minuteur, Codex, messages non
  lus…) a son petit onglet contre la notch, à gauche et à droite, le plus important au plus près d'elle (trois par
  côté au plus, puis un « +N »). Celui de Claude montre son état (main levée quand une session t'attend, un spinner
  pendant que Claude travaille, une coche à la fin d'un tour) et `sessions actives·sous-agents en cours`, par exemple
  `1·6`, ou l'avancement de la liste de tâches (`2/5`). Les intercalaires s'étalent en éventail, comme des cartes
  décalées sur une table : le plus important au-dessus, contre la notch, chacun des autres glissé sous le précédent et
  n'en montrant que la tranche avec son icône. Passe la souris sur un intercalaire : il s'ouvre en grand avec son détail
  (le morceau et ses commandes, le minuteur, les sessions et leur état) ; un clic ouvre le panneau sur son onglet.
  Réglages › Apparence : toujours visibles, ou rétractés en fine languette chacun jusqu'au survol (une alerte, comme
  Claude qui attend ta réponse, reste toujours visible).
- **Permissions** : la carte montre ce que Claude demande (`Terminal · rm -rf build`, le fichier à modifier,
  la question posée).
- **Répondre depuis la notch** (désactivé par défaut ; une carte en haut de l'onglet Claude propose de
  l'activer, comme Réglages › Claude) : autoriser ou refuser une permission (avec un motif facultatif pour
  Claude), répondre à une question (choix unique ou multiple, ou texte libre), approuver un plan ou demander des
  changements, et discuter avec une session (survole sa carte : **Converser**) : ce que Claude vient de dire,
  tes messages et un champ pour écrire. Ça marche pour le CLI et pour l'onglet Code de Claude Desktop. Le
  dialogue du terminal (ou de Claude Desktop) reste utilisable en même temps : la première réponse gagne.
  Jamais de « toujours autoriser » depuis la notch. Entrée envoie, Échap ferme.
- **Onglet Codex** (optionnel, voir [Onglet Codex](#onglet-codex)) : les sessions de Codex (OpenAI, CLI ou app), qui travaillent,
  attendent une approbation ou ont fini, avec le dernier message ; autoriser ou refuser une commande ou un patch depuis la notch.
- **Jauges de quota** (optionnelles, voir [Jauges de quota](#jauges-de-quota)) : un anneau fin et le pourcentage utilisé des
  fenêtres de 5 heures et de 7 jours dans les onglets Claude et Codex, avec l'heure de remise à zéro. Ambre dès 80 %, rouge dès 95 %.
- **Tâches** : barre de progression et tâche en cours de la liste de Claude Code ; le chevron déplie la liste.
- **Sous-agents** : nombre de sous-agents en cours dans chaque session.
- **Clic → retour à la session** : un clic sur une carte ramène l'app hôte au premier plan (Terminal, iTerm2,
  Ghostty, VS Code, Claude Desktop…). Pour une session de l'onglet Code de Claude Desktop, le clic ouvre
  cette session précise.
- **Claude Desktop** : une ligne indique si Claude Desktop est ouvert, avec un bouton pour le ramener devant.
- **Dix autres onglets** : Lecteur, Agenda, Réglages rapides, Étagère, Presse-papiers, Minuteur, Notes rapides,
  Messages, Mail et Micro et caméra (voir [Onglets](#onglets)).
- **Santé** (Réglages › Santé) : ce qui tourne (mémoire, processeur, autorisations) et un rapport à copier. La notch allège ses animations toute seule en économie d'énergie ou quand le Mac chauffe.
- **Tes propres intercalaires** (en option, voir [Scripts](#scripts--api-locale-et-commande-notch)) : `notch run -- make`
  affiche un sablier, puis ✓ ou ✗ avec la durée ; n'importe quel script peut afficher un état court par une API locale.
- **Barre de commande** : un champ, des préfixes d'une touche (voir [Barre de commande](#barre-de-commande)) : `t 25`
  lance un minuteur, `n idée` crée une note, `c lien` cherche dans tes copies, `s présentation` applique une scène,
  `> message` écrit à Claude.
- Marche aussi sur un écran sans notch (Mac sans encoche, écran externe, capot fermé) : par défaut, rien n'est
  dessiné au repos, une perle minuscule apparaît pendant une activité, et la souris qui s'approche la transforme en
  notch en verre dépoli. Elle peut aussi rester une notch en verre dépoli, une pilule qui flotte juste sous le haut
  de l'écran, ou une notch dessinée.

## Onglets

La notch déployée est une rangée d'onglets. Clique sur un onglet, ou survole-le un instant. Tous les onglets sont
activés par défaut, sauf Claude et Codex s'ils ne sont pas sur le Mac, et Messages et Mail, qui restent désactivés tant
que tu ne les actives pas. Dans **Réglages › Onglets**, tu peux masquer
un onglet (un onglet masqué ne fait aucun travail), changer leur ordre ou choisir celui qui s'ouvre par défaut. Tu
peux aussi le faire dans la notch, comme les apps sur iPhone : appui long sur la barre d'onglets, puis glisse les
icônes, masque un onglet avec **−** ou remets-en un avec **+**, et clique sur **OK** (ou Échap, ou un clic hors de la
barre). Le panneau se rouvre sur le dernier onglet utilisé, ou sur Claude (ou Codex) quand une session a besoin de toi.

- **Claude** : tes sessions, avec leur état, leurs permissions, leurs questions et leurs plans. En option : au
  premier lancement, il n'est activé que si Claude Code est sur le Mac (`~/.claude` ou `$CLAUDE_CONFIG_DIR`).
  Désactivé, rien de Claude ne tourne : ni scan des processus, ni suivi des sessions, événements des hooks ignorés.
- **Lecteur** : le morceau en cours dans Musique, Spotify ou ton navigateur, avec la pochette, la progression
  (glisse pour avancer) et les commandes. Dessous, une vue de la semaine de ton calendrier : un clic sur un
  événement l'ouvre dans Calendrier.
- **Agenda** : ton prochain rendez-vous en grand, avec un bouton **Rejoindre** qui ouvre son lien Zoom, Meet, Teams,
  Webex ou FaceTime, et le reste de la journée dessous. Notch repliée, il devient un intercalaire qui compte à rebours
  (discret à 15 minutes, ambre à 5, « en cours » en vert pendant le rendez-vous) ; aucun sondage, rien ne tourne entre
  deux échéances. Un lien ne s'ouvre que sur un clic sur **Rejoindre**.
- **Réglages rapides** : Wi-Fi, Bluetooth, Concentration, Économie d'énergie, caféine (empêche la mise en veille
  pendant 1 h, 2 h ou sans limite), ventilateurs (automatique ou vitesse fixe), batterie du Mac et des AirPods, et trois scènes : Autonomie, Normal et
  Présentation.
- **Étagère** : des fichiers et des dossiers à garder sous la main. Dépose-les sur la notch, même repliée, et
  glisse-les vers le Finder ou une autre app. L'étagère garde un lien vers chaque élément : rien n'est copié.
- **Presse-papiers** : tes copies récentes (texte, liens, images, fichiers, couleurs). Un clic les recopie ; rien
  n'est collé à ta place. Les copies faites dans les gestionnaires de mots de passe ne sont pas enregistrées. Un clic droit sur une image copie son texte ou lit un QR code ; une couleur se copie en hexadécimal ou en RGB. Un texte qui ressemble à un jeton, une clé ou un numéro de carte disparaît de l'historique au bout de 60 s (un réglage le désactive ; liste courte, pas une garantie).
- **Minuteur** : un compte à rebours, ou un cycle Pomodoro avec les durées de concentration et de pause que tu
  règles. Il continue de compter après une mise en veille ou un redémarrage.
- **Notes rapides** : des notes en texte brut. Épingle celles que tu utilises, supprime avec annulation, et cherche
  dès que tu en as plus de huit.
- **Messages** (désactivé par défaut) : tes conversations iMessage et SMS récentes, une pastille de non-lus sur la
  notch repliée et une réponse rapide. Il lit la base de Messages sur ton Mac, ce qui exige l'Accès complet au
  disque ; rien n'est enregistré ni envoyé ailleurs. Limites : la pastille compte les non-lus des 30 derniers jours
  et peut différer de celle du Dock ; une conversation de groupe ouvre seulement l'app Messages.
- **Mail** (désactivé par défaut) : le nombre de messages non lus d'Apple Mail et tes 3 à 5 derniers mails reçus
  (expéditeur, objet, début du texte, heure, pastille s'il n'est pas lu). Un clic en ouvre un dans Mail ; au survol,
  **Répondre** ouvre un champ pour écrire la réponse dans la notch. Elle ne part que sur ton clic sur **Envoyer** (ou
  Entrée) ; **Continuer dans Mail** ouvre la fenêtre de réponse de Mail avec ton texte déjà tapé. Si Mail ne
  confirme pas en 60 s, la notch le dit et te demande de vérifier avant de réessayer. Oriel ne lance jamais Mail : il
  ne le lit que pendant qu'il est ouvert.
- **Micro et caméra** (désactivé par défaut) : un intercalaire sur la notch repliée, orange quand un micro sert, vert pour une caméra. Oriel n'ouvre jamais le micro ni la caméra et n'affiche pas l'app qui les utilise.

## Barre de commande

Un champ dans la notch pour agir sans chercher le bon onglet. Ouvre-le avec son raccourci (Réglages › Général ›
Raccourcis, aucun par défaut) ou par **…** › **Barre de commande…**, tape, appuie sur Entrée. Rien ne part avant
Entrée (ou un clic sur la ligne), et Échap la ferme.

| Tape | Effet |
|---|---|
| `t 25`, `t 1h30`, `25 min` | Lance un minuteur (`t` seul : 25, 5 et 10 minutes, et le Pomodoro) |
| `n une idée` | Crée une note rapide |
| `c lien` | Cherche dans l'historique du presse-papiers ; Entrée recopie l'élément |
| `s présentation` | Applique une scène des Réglages rapides (Autonomie, Présentation, Normal) ; avec une vitesse fixe des ventilateurs, `s ventil` la rend à macOS |
| `m facture` | Cherche dans les derniers mails de l'onglet Mail ; Entrée ouvre le mail dans Mail |
| `a équipe` | Liste les rendez-vous d'aujourd'hui et de demain ; Entrée rejoint la réunion (lien reconnu) ou ouvre Calendrier à ce jour |
| `i sauvegarde` | Retire un intercalaire posé par un de tes scripts (ou tous) |
| `> relance les tests` | Écrit à une session Claude (le même canal que le champ de la conversation ; demande « Répondre depuis la notch ») |

Les préfixes sont listés sous le champ, et cliquables. Un préfixe est une lettre suivie d'une espace (`>` n'en demande
pas) ; le reste est du texte libre, auquel seule une durée avec son unité (`25 min`), ou une scène, un mail ou un rendez-vous d'au
moins trois lettres, peut répondre. Quand les noms ne tiennent pas, seules les touches sont montrées. La recherche ignore la casse et les accents et pardonne des lettres manquantes dans un texte court
(`prsnt` trouve Présentation). La barre n'interroge que les onglets activés et en marche : un onglet masqué n'est pas
réveillé, un onglet Claude coupé n'a pas de `>`. Le presse-papiers et les intercalaires de tes scripts ne sont
jamais cherchés sans leur préfixe. Pas de langage
naturel, aucune permission, rien ne quitte ton Mac.

## Répondre depuis la notch

Désactivé par défaut : l'onglet Claude affiche une carte (**Activer** / **Plus tard**) et **Réglages › Claude**
a l'interrupteur. Claude Code attend alors ta réponse dans la notch comme dans le terminal ou dans Claude Desktop :

- **Permissions** : autoriser ou refuser un appel d'outil, avec un motif facultatif que Claude lit. La notch ne
  propose jamais « toujours autoriser ».
- **Questions** : choisir une ou plusieurs réponses, ou écrire la tienne.
- **Plans** : approuver un plan, ou demander des changements.
- **Conversation** : survole la carte d'une session et clique sur **Converser**. Tu vois les derniers messages
  de Claude (ce qu'il a dit en s'arrêtant, ce que ses sous-agents ont rapporté), ce que tu as écrit, et un champ
  pour écrire à Claude. Le message lui parvient après l'action en cours, ou démarre un tour (3 s environ) s'il
  attendait. Un clic sur un long message le déplie.

Le dialogue du terminal reste utilisable : la première réponse gagne. Si la notch ne répond pas à temps (4 secondes
si sa carte n'a jamais été affichée, environ 590 secondes sinon), la demande revient au terminal. Il en va de même
quand l'app est fermée ou le réglage coupé : rien n'est jamais approuvé par défaut.

**Claude Desktop (onglet Code).** Vérifié avec Claude Code 2.1.304 lancé comme le lance l'onglet Code : le hook de
permission est appelé et sa décision appliquée (en mode « ignorer les autorisations », rien ne demande de
permission, mais les questions arrivent bien dans la notch), une question répondue depuis la notch est reçue par
Claude, et un message envoyé depuis la notch réveille Claude (un nouveau tour 3 s plus tard, ou lu après l'action
en cours). Les plans n'ont pas été vérifiés avec Desktop, ni la façon dont la fenêtre de Desktop montre un tour
démarré depuis la notch.

Quand la notch ne peut pas écrire à une session (`claude -p`, SDK Agent, IDE, ou session ouverte avant la mise à jour
du script de hook), la conversation affiche « Réponds dans *app* » avec un bouton **Ouvrir** à la place du champ.
Une session ouverte avant la mise à jour ne reçoit les réponses qu'après son redémarrage.

## Onglet Codex

Codex a ses propres hooks : l'onglet marche comme celui de Claude. Il suit Codex où qu'il tourne : l'**app ChatGPT**
(qui contient maintenant Codex), la commande `codex` dans un terminal, ou un éditeur.

1. **Réglages › Codex › Installer les hooks Codex** (le bouton de l'onglet l'ouvre). Une entrée par événement est ajoutée à
   `~/.codex/hooks.json` (sauvegarde horodatée d'abord, tes hooks restent) et `codex-notch-hook.sh` est copié dans
   `~/.codex/hooks/`. Ton `notify` n'est jamais touché.
2. **Approuve les hooks dans Codex.** Codex ignore un hook neuf tant qu'il n'est pas approuvé, sans rien dire.
   L'onglet et Réglages › Codex montrent où tu en es (*non posés*, *en attente d'approbation dans Codex*, *actifs*).
   Tant que l'approbation attend, clique sur **Approuver dans Codex** : l'app demande à Codex lui-même de faire confiance
   aux 8 hooks d'Oriel, et seulement à eux (la requête du bouton **Review hooks** de l'app ChatGPT). Tu peux aussi
   les revoir toi-même là, ou avec `/hooks` dans un terminal. L'onglet se met à jour tout seul dès qu'ils sont approuvés.
3. **Ouvre une nouvelle conversation** dans l'app ChatGPT (ou lance `codex`). Les conversations déjà ouvertes quand les
   hooks ont été approuvés ne sont pas suivies.
4. Chaque carte montre le projet, l'app (ChatGPT, Terminal, VS Code…), le modèle, ce que fait Codex (la commande ou le
   fichier) et son dernier message. Un clic sur la carte ramène cette app devant ; pour une session de l'app ChatGPT,
   il ouvre la conversation elle-même.

**Approuver depuis la notch** (Réglages › Codex, désactivé par défaut) : quand Codex demande à lancer une commande ou à
appliquer un patch, la carte l'affiche, avec **Autoriser**, **Refuser** et **Dans le terminal**. Contrairement à Claude
Code, Codex attend la notch avant de demander dans le terminal : l'attente est courte, 4 secondes si la carte n'a jamais
été affichée, 60 secondes sinon, puis Codex te demande lui-même. Rien n'est approuvé par défaut, jamais de « toujours
autoriser ». Impossible : écrire à une session Codex en cours, ou répondre aux questions propres de Codex.

## Scripts : API locale et commande `notch`

Désactivée par défaut (**Réglages › Scripts**). Une fois activée, tes scripts et tes programmes peuvent poser jusqu'à
trois intercalaires à eux à côté de la notch repliée, avec un texte court, une icône et une couleur prises dans des
listes, pour une heure au plus. La commande `notch` s'installe depuis le même volet (dans `~/.local/bin`, seulement sur
ton clic) :

```sh
notch show --title "Sauvegarde finie" --text OK --icon externaldrive.fill --color green
notch run -- make test
```

Aucun code n'est chargé dans l'app et un intercalaire ne lance rien : la seule action est un bouton qui ouvre l'app que
tu as nommée. Seuls les programmes de ton compte qui lisent le fichier du jeton peuvent l'appeler, jamais une page web ;
l'intercalaire d'un script dit toujours de quel programme il vient et ne peut pas se faire passer pour une demande de
Claude ou de Codex. Détails HTTP, limites et modèle de sécurité : [API.md](API.md).

## Jauges de quota

Un anneau fin, le pourcentage utilisé et l'heure de la prochaine remise à zéro, pour les fenêtres de 5 heures et de 7 jours,
sous les sessions de l'onglet **Claude** et de l'onglet **Codex** (et dans le résumé qui se déplie quand tu survoles leur
intercalaire). Ambre dès 80 %, rouge dès 95 %. Rien n'apparaît quand un onglet est désactivé, ni quand l'agent ne donne aucun
chiffre.

- **Claude** (Réglages › Claude › Afficher le quota, désactivé par défaut). Claude Code donne le quota (`rate_limits`) à sa
  `statusLine` et nulle part ailleurs, et n'accepte qu'une seule commande de `statusLine`. Le réglage met donc un petit relais à
  sa place dans `~/.claude/settings.json` (sauvegarde horodatée d'abord). Le relais envoie les données à l'app (127.0.0.1, avec
  le jeton), puis relance **ta commande précédente** avec les mêmes données : ta ligne d'état ne change pas (sans commande, il
  affiche `5h 39% · 7d 63%`). Couper le réglage, ou désinstaller Oriel, remet ta commande. Seulement pour les abonnés
  Pro et Max de claude.ai, et seulement après la première réponse d'une session. Les chiffres sont ceux du compte : n'importe
  quelle session les met à jour. L'app garde les pourcentages et les heures en mémoire ; le reste de ce que reçoit la ligne
  d'état (dossier, modèle, session) est jeté. Mesuré avec Claude Code 2.1.304 : rien avant la première réponse, puis les deux fenêtres.
  Le quota s'affiche quand Claude Code tourne dans un terminal (`claude`). L'app Claude (onglet Code compris) ne le
  transmet pas : elle n'exécute jamais la `statusLine`.
- **Codex** (Réglages › Codex › Afficher le quota, activé par défaut). Rien à installer : panneau ouvert, l'app interroge
  Codex lui-même (`codex app-server`, requête `account/rateLimits/read`, environ 1 s) au plus une fois par minute, puis toutes
  les 5 minutes. Mesuré avec la commande Codex 0.154 et le Codex de l'app ChatGPT 0.162. Il faut un compte ChatGPT : avec une clé
  d'API, Codex répond par une erreur et aucune jauge ne s'affiche. Un résumé vu sur un intercalaire replié cache un chiffre de
  plus de 15 minutes.

## Réglages de la notch

Ouvre **…** › **Réglages…** (⌘,).

- **Visibilité** : toujours visible (par défaut), seulement quand Claude est ouvert (proposé avec l'onglet Claude
  activé), ou seulement pendant une activité : une session qui travaille, attend ou vient de finir, ou un onglet qui affiche des oreilles (minuteur,
  lecteur).
- **Masquer la notch** pendant 1 h, jusqu'à demain, ou jusqu'à ce que tu la réaffiches. Les mêmes choix sont dans le
  menu **…** et dans le menu du clic droit sur la notch repliée.
- **Ouverture** : au survol (avec un délai) ou au clic. **Fermer au clic à l'extérieur** garde le panneau ouvert
  jusqu'à un clic ailleurs, au lieu de le refermer quand la souris le quitte.
- **Raccourcis** (aucun par défaut) : l'un ouvre ou ferme le panneau, l'autre masque ou réaffiche la notch, un
  troisième ouvre la [barre de commande](#barre-de-commande). Ils marchent partout, sans l'autorisation d'accessibilité. Panneau ouvert au clavier : ← et → changent d'onglet, ⌘1 à
  ⌘9 vont à un onglet, Échap ferme.
- **Taille et apparence** : largeur du panneau (compact, standard, grand, ou une largeur personnalisée de 460 à
  720 pt), fond (noir, graphite, bleu nuit ou couleur libre), opacité, ombre, couleur d'accent et vitesse des
  animations. Avec « Réduire les animations » activé dans macOS, les animations deviennent un simple fondu.
- **Écran** : l'écran intégré (par défaut), l'écran principal, l'écran sous la souris, ou un écran choisi par son
  nom. Un écran sans encoche reçoit une encoche virtuelle en haut au centre, dans le style choisi dans Apparence
  (« Écran sans encoche ») : perle (par défaut : une perle de 44 × 20 pt avec l'icône et le chiffre de l'activité, rien au repos ; la souris qui
  s'approche la transforme en encoche en verre dépoli, puis le panneau s'ouvre), caméléon (invisible au repos, en verre
  dépoli pendant une activité), pilule qui flotte juste sous le haut de l'écran, ou encoche dessinée.
- **Bulle** : glisse l'angle en bas à droite du panneau ouvert, et la notch se décolle en une bulle à poser où tu
  veux, ses onglets en barillet de revolver (molette ou clic pour tourner, clic au centre pour ouvrir ; le bouton
  retour, Échap, un clic à l'extérieur ou un pincement ramènent au barillet). Approche-la de la notch, qui l'attire et
  l'aspire comme du ferrofluide, double-clique sur son bord ou choisis **Rattacher à la notch**. Désactivable, et elle peut
  revenir dans la notch à chaque lancement.
- **Confidentialité** : masquer la notch des captures d'écran et du partage d'écran. Cela dépend de l'app qui capture
  l'écran.
- **Profil** : **Changer de profil…** te fait partir d'un profil (Développeur, Étudiant, Créatif ou Minimal) : la
  fenêtre montre les onglets affichés et masqués, l'ouverture et les oreilles, et ne change rien avant ta
  confirmation. Les données des onglets et les hooks ne sont jamais touchés ; les onglets masqués reviennent depuis
  **Réglages › Onglets**. Le volet nomme le profil qui correspond à tes onglets, ou « Personnalisé ».
- **Assistant de configuration** : **Relancer l'assistant de configuration** refait les étapes du premier lancement,
  en partant de tes réglages actuels.
- **Rétablir les réglages par défaut**, après confirmation. Les onglets, leurs données et les hooks ne changent pas.

## Assistant de configuration

Au premier lancement, un assistant de configuration te laisse choisir ce qui t'intéresse, en quatre courtes
étapes. **Passer** est toujours possible et ne change rien ; rien n'est écrit avant **Appliquer**.

1. **Bienvenue et profil** : ce qu'est la notch, et un profil facultatif : Développeur (Claude et Codex s'ils sont
   trouvés, presse-papiers, minuteur, notes), Étudiant (agenda, lecteur et calendrier, minuteur, notes, réglages rapides),
   Créatif (lecteur et calendrier, étagère, presse-papiers) ou Minimal (lecteur et calendrier, réglages rapides). Il
   coche les onglets, règle l'ouverture du panneau et les oreilles ; les étapes suivantes partent de lui et tout reste
   modifiable. Sans choix, rien ne change.
2. **Onglets** : une carte par onglet, coche ceux que tu veux (au moins un reste activé). La carte Claude n'est
   proposée que si Claude Code est sur le Mac, avec une option décochée pour installer les hooks de Claude Code :
   ils ajoutent les entrées d'Oriel dans `~/.claude/settings.json` (une sauvegarde horodatée est faite à
   côté avant, tes hooks existants sont conservés) et installent le script de hook dans `~/.claude/hooks/`. Sans
   Claude Code, une ligne dit où activer l'onglet Claude plus tard (**Réglages › Onglets**).
3. **Comportement** : ouverture au survol ou au clic, un raccourci clavier facultatif, et le lancement à l'ouverture
   de session.
4. **Fin** : un aperçu de ta notch avec les onglets choisis, et où retrouver tout ça (menu **…**, Réglages).

L'assistant ne demande aucune autorisation macOS (calendrier, Bluetooth…) : macOS ne la demande que lorsque tu
utilises l'onglet concerné. Il ne s'affiche qu'une fois, et pas après une mise à jour depuis une version déjà
configurée. Pour le refaire : **Réglages › Général › Relancer l'assistant de configuration**. Les hooks peuvent
aussi s'installer plus tard depuis **Réglages › Claude** ; une session déjà ouverte apparaît à son prochain message.

## Confidentialité

- Tout reste sur ton Mac. Oriel n'envoie aucune donnée sur toi ni sur tes sessions : pas de
  statistiques. Ses seules requêtes sortantes sont la recherche de mise à jour sur `api.github.com` et le
  téléchargement des nouvelles versions depuis GitHub (voir [Mises à jour](../README.fr.md#mises-à-jour)).
- L'app n'écoute que sur `127.0.0.1:47823`, sur l'interface de bouclage : elle est injoignable depuis le réseau.
- Le script de hook ne parle qu'à cette adresse locale, avec `curl`. Chaque requête porte un jeton que l'app
  génère à chaque lancement et écrit dans `~/Library/Application Support/Oriel/hook-token` (lisible par
  ton compte seulement) ; curl le lit dans ce fichier, il n'apparaît donc jamais dans la liste des processus.
  L'app refuse toute requête sans lui, avec un autre `Host` que `127.0.0.1:47823` ou avec un en-tête `Origin`
  (une page web). Dans l'autre sens, une décision ou un message de l'app porte un second secret (`hook-proof`,
  même dossier, jamais envoyé par le script) : sans lui, le script ignore la réponse. Un programme qui prend le
  port pendant que l'app est fermée (un autre compte sur un Mac partagé) ne décide donc rien.
- Réponses depuis la notch : l'app ne fait jamais que répondre à la requête d'un hook de Claude Code, après un
  clic dans la notch. Aucune route ne permet à un autre programme de décider à ta place, et il n'y a pas de
  « toujours autoriser ». Au moindre échec (app fermée, réglage coupé, délai passé), le hook rend la main au
  terminal : jamais d'autorisation par défaut.
- **Presse-papiers** : pendant que l'app tourne, l'onglet Presse-papiers vérifie le presse-papiers une fois par
  seconde, et ne lit son contenu que s'il a changé et passe les contrôles de confidentialité. Les copies marquées
  confidentielles, temporaires ou générées par un gestionnaire de mots de passe ne sont jamais enregistrées, ni
  celles faites depuis Trousseaux d'accès, Mots de passe, 1Password, Bitwarden, Dashlane ou KeePassXC (la liste
  peut être modifiée). Par défaut, l'historique reste en mémoire et disparaît à la fermeture de l'app ou à la
  désactivation de l'onglet. Si tu le gardes d'un lancement à l'autre, seuls les textes et les liens sont écrits,
  jamais les images ni les fichiers. Suspendre la capture arrête les contrôles jusqu'au prochain lancement. Un texte qui ressemble à un jeton, une clé ou un numéro de carte disparaît de l'historique au bout de 60 s (un réglage le désactive) ; cette liste est courte, ce n'est pas une garantie.
- Ce que l'app lit : les événements de hook, la fin du transcript d'une session en cours (pour détecter
  Esc), les fichiers de tâches de Claude Code, la liste des processus (pour trouver l'app hôte), le morceau en cours
  et sa pochette (Lecteur), les événements des calendriers que tu as choisi d'afficher, l'état du Wi-Fi et du
  Bluetooth, et le niveau de la batterie, et si un micro ou une caméra est utilisé (l'état seulement, jamais leur flux). Avec le quota activé : les pourcentages et heures de remise à zéro que Claude Code
  donne à sa ligne d'état (relayés, gardés en mémoire) et que Codex renvoie quand on le lui demande.
- Ce que l'app écrit : les journaux et les fichiers du jeton dans `~/Library/Application Support/Oriel/`
  (voir [Registres partagés](#registres-partagés)), et les données des onglets dans le même dossier :
  `shelf.json` (les références à tes fichiers), `notes.json`, `timer.json`, et `clipboard-history.json` seulement
  si tu gardes l'historique. Ces fichiers ne sont lisibles que par ton compte. Il y a aussi les hooks dans
  `~/.claude` quand tu le demandes, les hooks Codex (`~/.codex/hooks.json` et `~/.codex/hooks/codex-notch-hook.sh`) quand tu
  le demandes, `oriel-statusline.sh` et une copie de ta commande de ligne d'état précédente (lisible par toi seul) dans
  `~/.claude/hooks/`, et la `statusLine` de `~/.claude/settings.json`, quand tu actives le quota de Claude (`~/.codex/config.toml` n'est que lu, pour montrer l'état des hooks, jamais écrit par l'app : l'approbation des
  hooks, quand tu cliques sur **Approuver dans Codex**, est écrite par Codex lui-même, que l'app lance un instant avec un
  environnement minimal) et, pendant une mise à jour, le DMG dans
  `~/Library/Caches/io.github.slybald.oriel/updates/` (supprimé ensuite) et la nouvelle app à la place de
  l'ancienne. Les messages que tu tapes partent à la session Claude Code seulement, sans être enregistrés.

## Autorisations macOS

Oriel ne demande une autorisation que lorsque tu utilises la fonction qui en a besoin. Rien n'est demandé au
lancement.

- **Calendriers** (accès complet) : ta semaine et tes événements dans l'onglet Lecteur, et le prochain rendez-vous de
  l'onglet Agenda (avec son compte à rebours sur la notch repliée). Demandé quand tu appuies sur le bouton du
  calendrier ou sur **Autoriser l'accès au calendrier**, ou que tu actives l'option.
- **Automatisation : Calendrier** (Apple Events) : pour ouvrir un jour ou un événement dans Calendrier. macOS le
  demande la première fois.
- **Bluetooth** : pour lire l'état du Bluetooth et le couper ou le rallumer depuis Réglages rapides. Demandé quand tu
  utilises pour la première fois la tuile Bluetooth ou une scène qui la change.
- **Notifications** : pour annoncer la fin d'un minuteur. Demandé au premier minuteur lancé. Sans elles, le son et
  l'oreille « Terminé » signalent quand même la fin.
- **Coller depuis d'autres apps** (macOS 15.4 et plus récent) : pour que l'onglet Presse-papiers puisse lire ce que
  tu copies. macOS peut le demander à chaque fois, ou le bloquer. Bloqué, rien ne peut être enregistré ; l'onglet et
  les réglages renvoient vers Réglages Système.
- **Accès complet au disque** (onglet Messages, désactivé par défaut) : pour lire la base de Messages. macOS n'a pas
  de fenêtre pour ça : ajoute Oriel toi-même dans Réglages Système › Confidentialité et sécurité › Accès
  complet au disque, puis relance l'app. Sans lui, l'onglet le dit et renvoie vers Réglages Système.
- **Contacts** (onglet Messages) : pour afficher les noms des contacts au lieu des numéros. Demandé quand tu cliques
  sur **Autoriser** dans l'onglet.
- **Automatisation : Messages** (Apple Events) : pour envoyer une réponse rapide. macOS le demande au premier envoi.
- **Automatisation : Mail** (Apple Events) : pour lire les derniers mails et envoyer la réponse que tu écris. Demandé
  quand tu cliques sur **Autoriser** dans l'onglet Mail.
- **Bureau, Documents, Téléchargements** : seulement pour des outils compagnons facultatifs en ligne de commande,
  qu'Oriel peut lancer en arrière-plan (ils ne font pas partie de ce dépôt).
- Wi-Fi : le nom du réseau n'est pas lu, donc la localisation n'est pas demandée. Si macOS refuse de changer l'état
  du Wi-Fi, la tuile l'indique.
- L'économie d'énergie exige les droits administrateur (`pmset`). Le premier changement demande ton mot de passe ou
  Touch ID une fois et, dans la même fenêtre, pose une règle système limitée à l'activation et la désactivation de
  ce mode (`/etc/sudoers.d/oriel-lowpower`) ; ensuite, plus de mot de passe. Retirée par « Retirer
  l'autorisation » dans les réglages ou à la
  désinstallation.
- La vitesse fixe des ventilateurs exige root pour écrire dans le SMC. La première vitesse fixe demande ton mot de
  passe une fois et installe un petit outil (`/Library/PrivilegedHelperTools/io.github.slybald.oriel.fanctl`) et
  une règle système qui n'autorise que lui (`/etc/sudoers.d/oriel-fans`). Lire les vitesses et les températures
  ne demande rien. « Retirer l'autorisation » dans les réglages ou la désinstallation retire les deux.

## Fonctionnement

- Codex : ses hooks passent par le même serveur local (`/codex/hook`, et `/codex/permission` pour le hook `PermissionRequest`
  synchrone), avec le même jeton et la même preuve. Codex lance ce hook *avant* sa propre invite et l'attend : l'app tient
  donc une demande 4 s si sa carte n'a jamais été affichée, 60 s sinon, puis répond « pas de décision » et Codex demande
  dans le terminal (timeout du hook : 75 s).
- Chaque événement de hook est relayé par `curl` vers `http://127.0.0.1:47823/hook`, avec le PID du
  processus parent du hook et quelques variables d'environnement. Ces hooks sont déclarés `async: true` :
  aucune latence pour Claude.
- Deux autres sortes de hooks servent à « Répondre depuis la notch » :
  - `PermissionRequest` lance aussi le script en synchrone (mode `permission`, timeout de 600 s). Le dialogue
    du terminal s'affiche en même temps et reste utilisable ; la première réponse gagne. L'app tient la
    demande jusqu'à ton clic, sinon elle répond « pas de décision » : après 4 s si tu n'as pas ouvert sa carte
    dans la notch, après 590 s environ si tu l'as ouverte, dès que l'outil tourne ou que le tour avance, ou
    quand tu réponds au terminal. Réglage coupé, le hook rend la main tout de suite.
  - `SessionStart` et `Stop` lancent une attente (mode `inbox`, `asyncRewake`) : elle attend en arrière-plan
    un message tapé dans la notch, puis le remet à Claude, qui démarre un tour (3 s environ). Pendant un tour,
    le message est lu après l'action en cours. Sans attente (session ouverte avant la mise à jour des hooks,
    app relancée), le message reste en file jusqu'à la fin du tour. Taille limitée à 1 800 octets, caractères
    de contrôle retirés. Les sessions sans terminal (`claude -p`, SDK, IDE) ne reçoivent pas de message depuis la
    notch : Claude y attend la fin de ce hook avant de lire le prompt (ou avant de sortir), l'app le libère donc
    tout de suite. L'onglet Code de Claude Desktop fait exception, à la fin d'un tour seulement (`Stop` ; le
    script envoie l'identifiant de session Desktop) : le résultat du tour est déjà parti et le prompt suivant
    n'attend pas, alors que tenu sur `SessionStart` le hook retardait le premier prompt de toute l'attente (mesuré
    avec Claude Code 2.1.304). À la fermeture d'une session Desktop, SIGTERM la termine aussitôt ; fermer son
    entrée laisse Claude jusqu'à 30 s environ.
- Après une mise à jour de l'app, des hooks posés par une version précédente sont mis à jour sans rien
  demander, avec la sauvegarde horodatée habituelle de `settings.json`.
- À partir de ce PID, l'app remonte la chaîne de processus pour trouver le processus Claude (détection de
  fin de session) et l'app hôte (Terminal, iTerm2, Ghostty, VS Code, Claude Desktop…). Une session qui a
  Claude Desktop parmi ses ancêtres est une session Desktop ; le clic l'ouvre avec
  `claude://code/continue?session=local_…` (identifiant transmis par `CLAUDE_CODE_HOST_SESSION_ID`).
- Si l'app est fermée, le hook la relance au prochain `SessionStart` ou `UserPromptSubmit`.
- Une interruption par Esc ne déclenche aucun hook : pendant un tour, l'app relit la fin du transcript chaque
  seconde et repasse la session en « Prête » si elle y trouve l'interruption.
- Diagnostic : `GET http://127.0.0.1:47823/state` renvoie l'état des sessions et de la notch en JSON
  (lecture seule, local uniquement, avec le jeton :
  `curl -H @"$HOME/Library/Application Support/Oriel/hook-token" http://127.0.0.1:47823/state`).

## Registres partagés

L'app ajoute une ligne JSON par événement à deux fichiers de `~/Library/Application Support/Oriel/`, à
partir de hooks qu'elle reçoit déjà :

- `files.jsonl` : chaque fichier écrit par Claude (`PostToolUse` réussi de Write, Edit, MultiEdit,
  NotebookEdit) : `{"ts", "path", "tool", "session_id", "project", "cwd", "source"}`.
- `permissions.jsonl` : chaque demande de permission : `{"ts", "session_id", "project", "tool", "detail"}`,
  où `detail` est la 1re ligne de la commande pour Bash, le chemin du fichier pour une édition, sinon la
  description courte de l'outil, tronqué à 200 caractères.

## Limites

- Les conversations « chat » de Claude Desktop ne passent pas par les hooks : seul l'état « Claude Desktop
  ouvert / au premier plan » est affiché pour elles.
- Une session ouverte avant l'installation des hooks n'apparaît qu'à son prochain message.
- Après une permission accordée dans le terminal, la carte reste en « Attend ta permission » jusqu'à la fin
  de l'outil : aucun hook ne signale l'accord lui-même. (Accordée depuis la notch, la carte suit tout de suite.)
- Répondre depuis la notch : une session ouverte avant la mise à jour des hooks ne reçoit les réponses
  qu'après son redémarrage. Une session sans terminal autre que l'onglet Code de Claude Desktop (`claude -p`,
  SDK, IDE) ne peut pas recevoir de message : la conversation propose d'ouvrir la session. Avec Claude Desktop,
  les plans n'ont pas été vérifiés, ni la façon dont sa fenêtre montre un tour démarré depuis la notch. La
  conversation garde les 6 dernières répliques de chaque session, en mémoire seulement. Après un redémarrage de
  l'app (mise à jour, relance), une session au repos n'a plus de hook en attente jusqu'à la fin de son prochain
  tour : les hooks tenus se reconnectent seuls si l'app revient dans les 30 secondes (pas ceux lancés par un
  ancien script), sinon un message reste en file et la conversation dit qu'il partira au prochain tour de Claude,
  avec un bouton **Ouvrir**.
- Codex : un hook neuf ne tourne qu'une fois approuvé (**Approuver dans Codex**, ou **Review hooks** dans l'app ChatGPT, ou
  `/hooks` dans un terminal), et seulement dans les conversations démarrées ensuite. Modifier un hook (une mise à jour d'Oriel) fait que Codex le redemande. `codex exec` ne demande jamais d'approbation : rien n'y est tenu ; le CLI
  interactif et le moteur de l'app ChatGPT, si (mesuré avec le Codex 0.162 de l'app). La fenêtre de l'app ChatGPT elle-même
  n'a pas été pilotée ; le lien qui ouvre une conversation (`codex://threads/<id>`) vient du routage de l'app. Pas de message libre à une session en cours, pas de réponse aux questions propres de Codex (aucun hook), et
  la carte reste sur « Attend ton approbation » après une approbation donnée dans le terminal, jusqu'à la fin de l'outil.
- Jauges de quota : le chiffre de Claude n'arrive que quand une session munie du relais répond (Pro et Max, sessions de
  terminal seulement : l'onglet Code de l'app Claude n'exécute jamais la `statusLine`), et il est perdu au redémarrage de l'app jusqu'à la réponse suivante. Un `settings.json` de projet ou local
  qui impose sa propre `statusLine` contourne le relais. Le chiffre de Codex est lu à l'ouverture du panneau : il peut avoir
  quelques minutes.
- Esc pendant la réflexion, avant le moindre texte : Claude n'écrit rien dans le transcript, la carte reste en
  « Réfléchit » jusqu'au prochain événement.
- Une session `claude` lancée depuis un terminal ouvert dans Claude Desktop est classée Desktop (Claude.app
  figure parmi ses ancêtres).
- Registres : écrits seulement pendant que l'app tourne (le hook ne relance l'app qu'au début d'une session
  ou d'un tour). Pas de rotation (environ 250 octets par ligne) ; au-delà de 16 Mo, l'app ne lit que la fin
  de `files.jsonl`.
- `permissions.jsonl` contient aussi AskUserQuestion et ExitPlanMode : Claude Code les fait passer par
  `PermissionRequest`.
- Liste de tâches : les outils TaskCreate/TaskUpdate ne sont actifs par défaut que sur certains modèles.
  Sinon, `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`. Claude Code supprime les fichiers de tâches quand toute la liste
  est terminée : la barre disparaît.
- Lecteur : le morceau vient de `mediaremote-adapter`, un utilitaire open source (BSD-3-Clause) qui passe par
  `/usr/bin/perl` d'Apple, car depuis macOS 15.4 MediaRemote ne répond plus aux apps tierces. Si l'utilitaire ne
  démarre pas, l'onglet affiche « Lecture en cours indisponible » et un bouton **Réessayer**.
- Économie d'énergie : demande le mot de passe administrateur ou Touch ID une seule fois, au premier changement (ou à
  chaque changement si tu as retiré l'autorisation dans les réglages). La tuile est masquée sur les Mac qui n'ont
  pas ce mode.
- Concentration : macOS ne permet à aucune app de régler la Concentration ; la lire demande une autorisation qu'Oriel ne demande jamais. La tuile lance un
  raccourci que tu crées dans l'app Raccourcis (la tuile explique comment). L'état affiché est celui de ton dernier
  clic.
- Bluetooth utilise une API privée d'`IOBluetooth`, chargée à l'exécution. Apple peut la modifier sans prévenir.
- Wi-Fi : le nom du réseau n'est pas affiché.
- Presse-papiers : les images de plus de 5 Mo ne sont pas gardées, et l'historique garde 25, 50 ou 100 éléments. Les
  éléments épinglés s'ajoutent à ce nombre et ne sont jamais retirés.
- Notes rapides : 200 notes au plus, 100 000 caractères par note, texte brut seulement.
- Minuteur : la fin est signalée par le son et l'oreille « Terminé ». La notification demande ton autorisation.
