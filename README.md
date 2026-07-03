# hexapod_v3

Mod Luanti (Minetest) qui ajoute un hexapod pilotable au clavier de facon
**continue et fluide**, observe depuis une **camera exterieure a la
troisieme personne**, contrairement a :

- `hexapod_v1` : deplacement pas a pas via un formspec ;
- `hexapod_v2` : deplacement continu, mais le joueur est *attache* sur le
  hexapod (camera a la premiere personne, "dans" le node).

## Fonctionnement

- Le mod ajoute un objet `hexapod_v3:pod` (une entite en forme de cube, pas
  un node de la carte, pour un deplacement fluide hors grille voxel).
- Un clic droit sur un bloc pose l'item `hexapod_v3:pod` qui fait apparaitre
  l'entite pilotable a cet endroit.
- Un clic droit sur l'entite prend les commandes. Un second clic droit du
  meme joueur les relache.

### Pilotage du hexapod

Tant que les touches de deplacement du joueur restent enfoncees, le hexapod
bouge en continu (vitesse proportionnelle au temps ecoule, mise a jour a
chaque pas de simulation) :

- **Haut** : avance dans la direction actuellement regardee par le hexapod.
- **Bas** : recule.
- **Gauche** : pivote vers la gauche (rotation sur place).
- **Droite** : pivote vers la droite (rotation sur place).

La face avant du cube (celle dans laquelle il avance avec **Haut**) porte une
texture distincte (`hexapod_v3_node_front.png`, fond orange avec un chevron)
pour qu'on puisse voir d'un coup d'oeil, de l'exterieur, dans quel sens le
hexapod est oriente.

### Roues

Deux petites entites (`hexapod_v3:wheel`) sont **attachees** (`set_attach`)
de part et d'autre du hexapod : la **roue droite** (`self.wheel_right`) et
la **roue gauche** (`self.wheel_left`). L'attachement les colle rigidement
a son corps (position et cap) sans le moindre decalage, meme en mouvement.
Elles tournent sur elles-memes proportionnellement a sa vitesse : vers
l'avant quand il avance, vers l'arriere quand il recule, immobiles a
l'arret ou pendant un simple pivot sur place. Les distances/tailles se
reglent via `hexapod_v3.wheel_offset`, `hexapod_v3.wheel_radius` (utilise
pour convertir la vitesse lineaire en vitesse de rotation) et
`hexapod_v3.wheel_size`.

**Pourquoi l'attachement plutot que `move_to()` (comme la camera) ?**
`move_to()` fait "rattraper" une position cible par interpolation cote
client : quand cette cible bouge en continu (le hexapod en mouvement), le
suiveur reste toujours legerement en retard, ce qui donnait des roues
visiblement decalees vers l'arriere. Un objet **attache**, lui, est colle
a la position/rotation *courante* du parent a chaque image (cf. section
"Attachments" de `lua_api.md`), sans latence. La contrepartie : un objet
attache ignore les appels a `set_rotation()` (sa rotation est entierement
dictee par le parent + l'offset donne a `set_attach`) ; on fait donc
tourner les roues en rappelant `set_attach` a chaque pas avec une
rotation mise a jour (position laterale inchangee).

### Train arriere

Une rangee de `hexapod_v3.tail_count` nodes decoratifs (`hexapod_v3:tail_segment`,
memes textures que le corps) forme le **train arriere** (`self.tail_segments`),
**attachee** a la queue leu leu derriere le hexapod (le long de l'axe -Z,
colle a la face arriere), un peu comme un petit train. Purement statique :
un seul `set_attach` par segment a la creation suffit, ces segments ne
tournant pas sur eux-memes (contrairement aux roues) -- ils suivent la
position et le cap du hexapod sans latence grace a l'attachement, comme
les roues. Reglable via `hexapod_v3.tail_count` et `hexapod_v3.tail_size`.

### Pattes

`hexapod_v3.leg_pair_count` paires de pattes symetriques (gauche/droite,
3 par defaut -- un hexapod ayant 6 pattes) sont **attachees**, une paire
tous les `hexapod_v3.leg_pair_spacing` segments du train (2 par defaut),
en partant de celui immediatement derriere la tete
(`hexapod_v3.tail_segments[1]`, `[3]`, `[5]`, ...) : avec ces valeurs par
defaut, un segment du train reste donc libre entre deux paires de pattes
plutot que d'etre colle a la precedente. Chaque patte est une chaine de
6 nodes, **tous de la meme taille que les nodes du corps**
(`hexapod_v3.tail_size`), en forme de **L** sous son flanc d'attache :

```
[Hanche]
[Femur][Femur][Genou]
              [Tibia]
              [Tibia]
```

La **hanche** reste collee au flanc du corps. Le premier node du
**femur** est colle directement sous la hanche (meme colonne, un cran
plus bas), puis le femur continue a l'horizontale (il s'eloigne du corps
sur le cote, a hauteur constante) jusqu'au **genou**, a son extremite. Le
**tibia** repart alors du genou a la verticale, sous lui, en descendant
jusqu'au sol. Chaque transition ne change qu'un seul axe a la fois
(jamais `x` et `y` en meme temps), pour que les nodes restent toujours
colles face contre face -- un decalage simultane en diagonale laisserait
un vide de la taille d'un node entre deux nodes, qui ne se toucheraient
plus que par une arete. Les deux nodes de liaison portent donc chacun un
nom anatomique : la hanche relie le corps au femur, et le genou relie le
femur au tibia. Tous deux utilisent l'entite `hexapod_v3:leg_joint` avec
une texture distincte (`hexapod_v3_joint.png`, gris avec un rivet
central) pour bien marquer les articulations, alors que le femur et le
tibia reprennent la texture du corps (`hexapod_v3:leg_part`).

Comme le train, c'est purement statique : chaque node est attache une
fois pour toutes (`hexapod_v3.spawn_leg_part`) directement au node
"hanche" qui lui correspond (`hexapod_v3.spawn_legs` parcourt les
segments du train espaces de `leg_pair_spacing`), avec un decalage
calcule piece par piece (`hexapod_v3.spawn_leg`) : vertical (`y`) pour
descendre de la hanche au premier node de femur puis pour le tibia sous
le genou, lateral (`x`) pour le reste du femur, chaque pas valant
exactement `hexapod_v3.tail_size` pour que les nodes restent colles les
uns aux autres. Le nombre de nodes du femur et du tibia se regle via
`hexapod_v3.leg_segment_height` (2 par defaut).

**Hauteur de pose.** Le premier node de femur (1 cran) puis le tibia
(`hexapod_v3.leg_segment_height` crans) contribuent a la chute verticale
des pattes sous le corps -- le reste du femur, horizontal, n'y ajoute
rien -- pour un total de `hexapod_v3.leg_drop` noeuds (calcule
automatiquement a partir de `leg_segment_height` et `tail_size`). Le
`on_place` de l'item en tient compte pour poser le hexapod plus haut que
son seul corps ne le demanderait, afin que les pattes ne s'enfoncent pas
dans le sol au lieu de rester visibles au-dessus.

### Sons

Deux sons en boucle (fonction generique `hexapod_v3.set_looping_sound`),
tous deux attaches a l'entite (`object = self.object`, donc positionnes et
suivis automatiquement par le moteur audio) :

- Un son de **moteur** (`sounds/hexapod_v3_engine.ogg`, boucle synthetisee
  de 0,4 s) joue tant que le hexapod avance (touche **Haut**), et stoppe
  des qu'il ne va plus vers l'avant (arret, marche arriere ou pivot seul).
  Reglable via `hexapod_v3.engine_sound_gain` et
  `hexapod_v3.engine_sound_max_hear_distance`.
- Un son de **direction** (`sounds/hexapod_v3_turn.ogg`, boucle synthetisee
  de 0,3 s, plus aigu que le moteur) joue tant que le hexapod pivote
  (**Gauche** ou **Droite**), y compris en meme temps que le son de moteur
  s'il avance/recule en tournant. Reglable via `hexapod_v3.turn_sound_gain`
  et `hexapod_v3.turn_sound_max_hear_distance`.

### Camera a la troisieme personne

Des que le joueur prend les commandes :

- Il **n'est plus positionne sur le node** : il est attache a une entite
  invisible ("camera_rig") repositionnee a chaque pas de simulation pour
  rester a distance fixe (`hexapod_v3.camera_distance`, 6 noeuds par
  defaut) derriere son propre regard, de sorte que le hexapod reste
  **exactement au centre de sa vue**, comme une camera satellite qui orbite
  autour de lui.
- Il **garde le controle libre de la souris** : en tournant la tete, il
  change la direction depuis laquelle il observe le hexapod (il peut ainsi
  tourner librement tout autour), le hexapod restant toujours centre.
- Il **perd son propre deplacement** pendant le pilotage (vitesse de marche,
  saut et gravite mis a zero via `set_physics_override`, et position figee
  par l'attache), afin que ses touches de direction ne servent qu'a
  controler le hexapod et non a le faire marcher lui-meme. Sa physique
  d'origine est restauree des qu'il relache les commandes (ou s'il se
  deconnecte pendant le pilotage).
- La camera **suit le hexapod en permanence** lors de ses deplacements et
  rotations, puisqu'elle est recalculee a chaque pas a partir de la
  position courante du node.

**Pourquoi une entite intermediaire plutot que deplacer directement le
joueur ?** Cote moteur, `ObjectRef:set_pos()` teleporte l'objet et force un
envoi immediat de sa position au client **sans interpolation**
(`LuaEntitySAO::setPos` appelle `sendPosition(false, true)`) : l'appeler a
chaque pas de simulation, que ce soit sur le joueur ou sur une entite,
produit donc des a-coups constants. La bonne API pour un suivi continu est
`ObjectRef:move_to(pos, true)`, concue par le moteur pour des "transitions
visuellement fluides" (l'entite est interpolee normalement entre deux
positions envoyees). On deplace donc une entite Lua invisible
("camera_rig", sans collision) via `move_to`, et on y attache le joueur :
sa vue herite de ce mouvement interpole.

### A propos des touches "flechees"

Luanti n'expose aux mods que l'etat des touches deja associees aux actions
de deplacement du joueur (`up`/`down`/`left`/`right`), quelles que soient les
touches physiques choisies dans **Parametres > Touches**. Par defaut, ce
sont Z/Q/S/D (ou W/A/S/D en QWERTY). Pour piloter le hexapod avec les
fleches directionnelles du clavier, il suffit de rebinder ces 4 actions sur
les fleches Haut/Bas/Gauche/Droite dans le menu des touches ; le mod suit
alors exactement ces touches.

## Installation

1. Copier le dossier `hexapod_v3` dans le repertoire `mods` du monde (ou
   dans le dossier `mods` global de Luanti).
2. Activer le mod dans la fenetre "Configurer le monde" du menu principal,
   ou ajouter la ligne suivante dans `world.mt` :

   ```
   load_mod_hexapod_v3 = true
   ```

## Utilisation

1. Obtenir l'item `hexapod_v3:pod` (inventaire creatif ou
   `/giveme hexapod_v3:pod`).
2. Le poser quelque part : l'entite pilotable apparait.
3. Faire un clic droit dessus pour prendre les commandes : la camera se
   place automatiquement en vue exterieure, centree sur le hexapod.
4. Utiliser les touches de deplacement (fleches, si rebindees comme
   explique ci-dessus) pour avancer, reculer et pivoter, et la souris pour
   regarder librement autour du hexapod.
5. Refaire un clic droit dessus pour lacher les commandes et retrouver son
   propre deplacement.

## Structure du mod

```
hexapod_v3/
├── init.lua                       # entite, item de pose, logique de pilotage et de camera
├── mod.conf                       # declaration du mod
├── textures/
│   ├── hexapod_v3_node.png        # texture des faces du hexapod
│   ├── hexapod_v3_node_front.png  # texture de la face avant
│   ├── hexapod_v3_wheel.png       # texture des roues
│   └── hexapod_v3_joint.png       # texture des nodes de jointure des pattes
├── sounds/
│   ├── hexapod_v3_engine.ogg      # son de moteur (boucle)
│   └── hexapod_v3_turn.ogg        # son de direction (boucle)
└── README.md
```
