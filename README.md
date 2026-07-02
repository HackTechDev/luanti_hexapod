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
│   └── hexapod_v3_node.png        # texture du hexapod
└── README.md
```
