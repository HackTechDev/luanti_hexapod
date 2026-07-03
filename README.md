# hexapod_v3

Mod Luanti (Minetest) qui ajoute un hexapod pilotable au clavier de façon
**continue et fluide**, observé depuis une **caméra extérieure à la
troisième personne**, contrairement à :

- `hexapod_v1` : déplacement pas à pas via un formspec ;
- `hexapod_v2` : déplacement continu, mais le joueur est *attaché* sur le
  hexapod (caméra à la première personne, "dans" le node).

## Fonctionnement

- Le mod ajoute un objet `hexapod_v3:pod` (une entité en forme de cube, pas
  un node de la carte, pour un déplacement fluide hors grille voxel).
- Un clic droit sur un bloc pose l'item `hexapod_v3:pod` qui fait apparaître
  l'entité pilotable à cet endroit.
- Un clic droit sur l'entité prend les commandes. Un second clic droit du
  même joueur les relâche.

### Pilotage du hexapod

Tant que les touches de déplacement du joueur restent enfoncées, le hexapod
bouge en continu (vitesse proportionnelle au temps écoulé, mise à jour à
chaque pas de simulation) :

- **Haut** : avance dans la direction actuellement regardée par le hexapod.
- **Bas** : recule.
- **Gauche** : pivote vers la gauche (rotation sur place).
- **Droite** : pivote vers la droite (rotation sur place).

La face avant du cube (celle dans laquelle il avance avec **Haut**) porte une
texture distincte (`hexapod_v3_node_front.png`, fond orange avec un chevron)
pour qu'on puisse voir d'un coup d'œil, de l'extérieur, dans quel sens le
hexapod est orienté.

### Gravité

Le hexapod subit une gravité constante (`hexapod_v3.gravity`, en
nœuds/s², même grandeur que la gravité par défaut de Minetest) et tombe
donc normalement s'il se retrouve en l'air (bord d'une falaise, saut d'un
bloc...) ; étant `physical = true`, le moteur arrête de lui-même sa chute
au contact du sol. Le pilotage (touches Haut/Bas, caméra) ne contrôle que
le déplacement horizontal : la composante verticale de la vitesse
(chute) est toujours préservée telle quelle, y compris pendant qu'on le
pilote ou juste après avoir relâché les commandes, pour qu'il continue
de tomber normalement plutôt que de rester figé en l'air.

La boîte de collision du hexapod (`collisionbox`) s'étend vers le bas
jusqu'à la pointe des pattes (`hexapod_v3.leg_drop` sous le centre du
corps), et non pas seulement autour du corps : sans ça, la chute
s'arrêterait dès que le corps touche le sol, laissant les pattes
s'enfoncer dedans. Note pour les tests : cette propriété n'est lue qu'à
la création d'un hexapod (`on_activate`) -- un hexapod déjà posé avant
une modification du mod garde son ancienne boîte de collision tant qu'il
n'est pas reposé ou que le monde n'est pas rechargé.

### Roues

Deux petites entités (`hexapod_v3:wheel`) sont **attachées** (`set_attach`)
de part et d'autre du hexapod : la **roue droite** (`self.wheel_right`) et
la **roue gauche** (`self.wheel_left`). L'attachement les colle rigidement
à son corps (position et cap) sans le moindre décalage, même en mouvement.
Elles tournent sur elles-mêmes proportionnellement à sa vitesse : vers
l'avant quand il avance, vers l'arrière quand il recule, immobiles à
l'arrêt ou pendant un simple pivot sur place. Les distances/tailles se
règlent via `hexapod_v3.wheel_offset`, `hexapod_v3.wheel_radius` (utilisé
pour convertir la vitesse linéaire en vitesse de rotation) et
`hexapod_v3.wheel_size`.

**Pourquoi l'attachement plutôt que `move_to()` (comme la caméra) ?**
`move_to()` fait "rattraper" une position cible par interpolation côté
client : quand cette cible bouge en continu (le hexapod en mouvement), le
suiveur reste toujours légèrement en retard, ce qui donnait des roues
visiblement décalées vers l'arrière. Un objet **attaché**, lui, est collé
à la position/rotation *courante* du parent à chaque image (cf. section
"Attachments" de `lua_api.md`), sans latence. La contrepartie : un objet
attaché ignore les appels à `set_rotation()` (sa rotation est entièrement
dictée par le parent + l'offset donné à `set_attach`) ; on fait donc
tourner les roues en rappelant `set_attach` à chaque pas avec une
rotation mise à jour (position latérale inchangée).

### Train arrière

Une rangée de `hexapod_v3.tail_count` nodes décoratifs (`hexapod_v3:tail_segment`,
mêmes textures que le corps) forme le **train arrière** (`self.tail_segments`),
**attachée** à la queue leu leu derrière le hexapod (le long de l'axe -Z,
collée à la face arrière), un peu comme un petit train. Purement statique :
un seul `set_attach` par segment à la création suffit, ces segments ne
tournant pas sur eux-mêmes (contrairement aux roues) -- ils suivent la
position et le cap du hexapod sans latence grâce à l'attachement, comme
les roues. Réglable via `hexapod_v3.tail_count` et `hexapod_v3.tail_size`.

### Pattes

`hexapod_v3.leg_pair_count` paires de pattes symétriques (gauche/droite,
3 par défaut -- un hexapod ayant 6 pattes) sont **attachées**, une paire
tous les `hexapod_v3.leg_pair_spacing` segments du train (3 par défaut),
en partant de celui immédiatement derrière la tête
(`hexapod_v3.tail_segments[1]`, `[4]`, `[7]`, ...) : avec ces valeurs par
défaut, deux segments du train restent donc libres entre deux paires de
pattes plutôt que d'être collées à la précédente. Chaque patte est une
chaîne de 7 nodes (1 hanche + 2 fémur + 1 genou + 3 tibia par défaut),
**tous de la même taille que les nodes du corps** (`hexapod_v3.tail_size`),
en forme de **L** sous son flanc d'attache, le tibia repartant ensuite
vers l'avant :

```
Vue de profil (x/y) :          Vue de dessus (x/z) :
[Hanche]                       [Hanche][Femur][Femur][Genou]
[Femur][Femur][Genou]                                [Tibia]
              [Tibia]
              [Tibia]
              [Tibia]
```

La **hanche** reste collée au flanc du corps. Le premier node du
**fémur** est collé directement sous la hanche (même colonne, un cran
plus bas), puis le fémur continue à l'horizontale (il s'éloigne du corps
sur le côté, à hauteur constante) jusqu'au **genou**, à son extrémité. Le
premier node du **tibia** est alors collé sur la face **avant** du genou
(`+Z`, la direction du regard du hexapod -- même hauteur, même côté), et
les nodes de tibia suivants repartent de là à la verticale, en
descendant jusqu'au sol. Chaque transition ne change qu'un seul axe à la
fois (jamais deux en même temps), pour que les nodes restent toujours
collés face contre face -- un décalage simultané sur deux axes laisserait
un vide de la taille d'un node entre deux nodes, qui ne se toucheraient
plus que par une arête. Les deux nodes de liaison portent donc chacun un
nom anatomique : la hanche relie le corps au fémur, et le genou relie le
fémur au tibia. Tous deux utilisent l'entité `hexapod_v3:leg_joint` avec
une texture distincte (`hexapod_v3_joint.png`, gris avec un rivet
central) pour bien marquer les articulations, alors que le fémur et le
tibia reprennent la texture du corps (`hexapod_v3:leg_part`).

Contrairement au train, chaque pièce de patte n'est pas attachée
directement au node "hanche" du train, mais **à la pièce précédente**
(`hexapod_v3.spawn_leg`) : la hanche au node du train, un pivot invisible
(voir "Démarche des pattes" plus bas) collé sur la hanche, le premier
fémur à ce pivot, le fémur suivant au premier, le genou au dernier
fémur, le premier tibia au genou, le tibia suivant au premier, etc.
Cette vraie chaîne articulée est ce qui permet la démarche animée (voir
plus bas) : faire pivoter un maillon entraîne avec lui tout ce qui lui
est attaché en aval. Chaque décalage (`hexapod_v3.spawn_leg_part`) vaut
exactement `hexapod_v3.tail_size` pour que les nodes restent collés les
uns aux autres au repos : vertical (`y`) pour descendre de la hanche au
premier node de fémur puis pour le tibia sous le genou, latéral (`x`)
pour le reste du fémur, avant (`z`) pour le premier node de tibia. Le
nombre de nodes du fémur et du tibia se règle indépendamment via
`hexapod_v3.leg_femur_height` (2 par défaut) et
`hexapod_v3.leg_tibia_height` (3 par défaut).

**Hauteur de pose.** Le premier node de fémur (1 cran) puis les
`hexapod_v3.leg_tibia_height - 1` nodes de tibia qui descendent (le
premier node de tibia, collé sur la face avant du genou, ne descend pas)
contribuent à la chute verticale des pattes sous le corps -- le reste du
fémur, horizontal, n'y ajoute rien -- pour un total de
`hexapod_v3.leg_drop` nœuds (calculé automatiquement à partir de
`leg_tibia_height` et `tail_size`). Le `on_place` de l'item en tient
compte pour poser le hexapod plus haut que son seul corps ne le
demanderait, afin que les pattes ne s'enfoncent pas dans le sol au lieu
de rester visibles au-dessus.

### Démarche des pattes

Tant que le hexapod se déplace ou pivote, ses 6 pattes marchent selon une
**démarche tripode** (comme un vrai hexapode) : elles sont réparties en 2
groupes de 3 (`hexapod_v3.spawn_legs`, motif
avant-droite/milieu-gauche/arrière-droite contre
avant-gauche/milieu-droite/arrière-gauche) qui alternent en opposition de
phase -- quand l'un balance (patte levée, avance), l'autre est en appui
(patte au sol, recule) --, exactement comme sur un vrai hexapode qui garde
toujours au moins 3 pattes au sol.

Chaque patte n'a que 2 degrés de liberté, conformément à la contrainte
demandée -- et surtout, **la hanche elle-même ne bouge jamais** : seul le
fémur (et ce qui suit) pivote autour d'elle. Pour cela, un node invisible
("hexapod_v3:leg_pivot", taille nulle) est collé exactement sur la hanche
(décalage nul) et c'est LUI qui pivote, pas la hanche elle-même :

- le **pivot de hanche** ne peut tourner qu'à l'**horizontale** (axe
  `Y`) : cette rotation entraîne tout le reste de la patte (fémur + genou
  + tibia, qui lui sont attachés en cascade) et fait donc balancer la
  patte entière vers l'avant ou l'arrière, la hanche restant
  parfaitement immobile ;
- le **genou** ne peut tourner qu'à la **verticale** (axe `X`) : cette
  rotation n'entraîne que le tibia, et sert à lever le pied pendant le
  balancement (`max(0, sin(phase))`, donc uniquement sur la moitié
  "avant" du cycle) puis à le reposer bien à plat pendant l'appui.

La hanche, le fémur et le tibia eux-mêmes ne tournent jamais : ce sont
des maillons passifs qui suivent leur pivot (le pivot de hanche pour le
fémur, le genou pour le tibia). Comme pour les roues, la rotation d'un
objet attaché étant ignorée par `set_rotation()`, elle est réanimée à
chaque pas en rappelant `set_attach` avec le même décalage de position
(toujours nul pour le pivot de hanche) mais un nouvel angle
(`hexapod_v3.update_legs`).

Réglable via `hexapod_v3.leg_hip_swing_deg` (amplitude du balayage de la
hanche, 25° par défaut), `hexapod_v3.leg_knee_lift_deg` (amplitude de la
levée du genou, 35° par défaut) et `hexapod_v3.leg_gait_speed` (vitesse
de la phase de marche, 1 cycle/seconde par défaut). La phase de marche
n'avance que si le hexapod se déplace ou pivote effectivement ; à l'arrêt,
les pattes se figent dans leur dernière position.

### Sons

Deux sons en boucle (fonction générique `hexapod_v3.set_looping_sound`),
tous deux attachés à l'entité (`object = self.object`, donc positionnés et
suivis automatiquement par le moteur audio) :

- Un son de **moteur** (`sounds/hexapod_v3_engine.ogg`, boucle synthétisée
  de 0,4 s) joue tant que le hexapod avance (touche **Haut**), et stoppe
  dès qu'il ne va plus vers l'avant (arrêt, marche arrière ou pivot seul).
  Réglable via `hexapod_v3.engine_sound_gain` et
  `hexapod_v3.engine_sound_max_hear_distance`.
- Un son de **direction** (`sounds/hexapod_v3_turn.ogg`, boucle synthétisée
  de 0,3 s, plus aigu que le moteur) joue tant que le hexapod pivote
  (**Gauche** ou **Droite**), y compris en même temps que le son de moteur
  s'il avance/recule en tournant. Réglable via `hexapod_v3.turn_sound_gain`
  et `hexapod_v3.turn_sound_max_hear_distance`.

### Caméra à la troisième personne

Dès que le joueur prend les commandes :

- Il **n'est plus positionné sur le node** : il est attaché à une entité
  invisible ("camera_rig") repositionnée à chaque pas de simulation pour
  rester à distance fixe (`hexapod_v3.camera_distance`, 6 nœuds par
  défaut) derrière son propre regard, de sorte que le hexapod reste
  **exactement au centre de sa vue**, comme une caméra satellite qui orbite
  autour de lui.
- Il **garde le contrôle libre de la souris** : en tournant la tête, il
  change la direction depuis laquelle il observe le hexapod (il peut ainsi
  tourner librement tout autour), le hexapod restant toujours centré.
- Il **perd son propre déplacement** pendant le pilotage (vitesse de marche,
  saut et gravité mis à zéro via `set_physics_override`, et position figée
  par l'attache), afin que ses touches de direction ne servent qu'à
  contrôler le hexapod et non à le faire marcher lui-même. Sa physique
  d'origine est restaurée dès qu'il relâche les commandes (ou s'il se
  déconnecte pendant le pilotage).
- La caméra **suit le hexapod en permanence** lors de ses déplacements et
  rotations, puisqu'elle est recalculée à chaque pas à partir de la
  position courante du node.

**Pourquoi une entité intermédiaire plutôt que déplacer directement le
joueur ?** Côté moteur, `ObjectRef:set_pos()` téléporte l'objet et force un
envoi immédiat de sa position au client **sans interpolation**
(`LuaEntitySAO::setPos` appelle `sendPosition(false, true)`) : l'appeler à
chaque pas de simulation, que ce soit sur le joueur ou sur une entité,
produit donc des à-coups constants. La bonne API pour un suivi continu est
`ObjectRef:move_to(pos, true)`, conçue par le moteur pour des "transitions
visuellement fluides" (l'entité est interpolée normalement entre deux
positions envoyées). On déplace donc une entité Lua invisible
("camera_rig", sans collision) via `move_to`, et on y attache le joueur :
sa vue hérite de ce mouvement interpolé.

### À propos des touches "fléchées"

Luanti n'expose aux mods que l'état des touches déjà associées aux actions
de déplacement du joueur (`up`/`down`/`left`/`right`), quelles que soient les
touches physiques choisies dans **Paramètres > Touches**. Par défaut, ce
sont Z/Q/S/D (ou W/A/S/D en QWERTY). Pour piloter le hexapod avec les
flèches directionnelles du clavier, il suffit de rebinder ces 4 actions sur
les flèches Haut/Bas/Gauche/Droite dans le menu des touches ; le mod suit
alors exactement ces touches.

## Installation

1. Copier le dossier `hexapod_v3` dans le répertoire `mods` du monde (ou
   dans le dossier `mods` global de Luanti).
2. Activer le mod dans la fenêtre "Configurer le monde" du menu principal,
   ou ajouter la ligne suivante dans `world.mt` :

   ```
   load_mod_hexapod_v3 = true
   ```

## Utilisation

1. Obtenir l'item `hexapod_v3:pod` (inventaire créatif ou
   `/giveme hexapod_v3:pod`).
2. Le poser quelque part : l'entité pilotable apparaît.
3. Faire un clic droit dessus pour prendre les commandes : la caméra se
   place automatiquement en vue extérieure, centrée sur le hexapod.
4. Utiliser les touches de déplacement (flèches, si rebindées comme
   expliqué ci-dessus) pour avancer, reculer et pivoter, et la souris pour
   regarder librement autour du hexapod.
5. Refaire un clic droit dessus pour lâcher les commandes et retrouver son
   propre déplacement.

## Structure du mod

```
hexapod_v3/
├── init.lua                       # entité, item de pose, logique de pilotage et de caméra
├── mod.conf                       # déclaration du mod
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
