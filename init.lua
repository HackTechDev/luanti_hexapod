-- hexapod_v3
-- Fournit une entite "hexapod_v3:pod" pilotable au clavier de facon continue
-- et fluide (Haut/Bas avancent ou reculent, Gauche/Droite pivotent), avec une
-- camera "troisieme personne" : le joueur n'est jamais colle sur le node, il
-- l'observe depuis l'exterieur. Sa camera reste en permanence centree sur le
-- node et le suit lors de ses deplacements, tout en gardant le controle
-- libre du regard (souris) ; en revanche il perd son propre deplacement
-- (ZQSD/fleches, saut, gravite) tant qu'il pilote le hexapod.
--
-- Note technique : la camera n'est ni le joueur teleporte a chaque pas, ni
-- une entite deplacee via `set_pos()` (les deux forcent une correction de
-- position sans interpolation cote client, donc des a-coups). On deplace
-- une entite Lua invisible ("camera_rig") via `move_to(pos, true)`, l'API
-- prevue par le moteur pour un suivi visuellement fluide, et on y attache
-- le joueur : sa vue herite alors de ce mouvement interpole.

hexapod_v3 = {}

-- Vitesses de deplacement du hexapod
hexapod_v3.forward_speed = 4          -- noeuds par seconde
hexapod_v3.turn_speed = math.rad(90)  -- radians par seconde

-- Gravite (noeuds/s^2, valeur habituelle de Minetest) appliquee en
-- permanence au hexapod pour qu'il tombe s'il se retrouve en l'air
-- (falaise, saut d'un bloc...). Le hexapod etant `physical = true`, le
-- moteur arrete de lui-meme la chute au contact du sol.
hexapod_v3.gravity = 9.81

-- Distance a laquelle la camera est maintenue derriere le regard du joueur,
-- de sorte que le hexapod reste toujours exactement au centre de la vue,
-- quelle que soit la direction observee.
hexapod_v3.camera_distance = 6

-- "Roues" decoratives : deux petites entites placees de part et d'autre du
-- hexapod, qui tournent sur elles-memes quand il avance ou recule.
hexapod_v3.wheel_offset = 0.65  -- distance au centre du hexapod, en noeuds
hexapod_v3.wheel_radius = 0.3   -- rayon utilise pour convertir vitesse -> vitesse de rotation
hexapod_v3.wheel_size = 0.35    -- taille visuelle des roues

-- Son de "moteur" joue en boucle tant que le hexapod avance (touche Haut).
hexapod_v3.engine_sound = "hexapod_v3_engine"
hexapod_v3.engine_sound_gain = 0.5
hexapod_v3.engine_sound_max_hear_distance = 16

-- Son de "direction" joue en boucle tant que le hexapod pivote (Gauche/Droite).
hexapod_v3.turn_sound = "hexapod_v3_turn"
hexapod_v3.turn_sound_gain = 0.4
hexapod_v3.turn_sound_max_hear_distance = 16

-- Petit "train" de nodes decoratifs attaches en ligne, a la queue leu leu,
-- derriere le hexapod (memes textures que le corps).
hexapod_v3.tail_count = 7
hexapod_v3.tail_size = 1  -- taille visuelle de chaque segment, en noeuds

-- Pattes (gauche/droite), une paire par segment "hanche" du train, en
-- partant de celui immediatement derriere la tete. Chaine "en L" : corps ->
-- hanche -> femur (horizontal, s'eloigne du corps) -> genou -> tibia
-- (vertical, descend jusqu'au sol). Chaque piece est un node de la meme
-- taille que ceux du corps (`hexapod_v3.tail_size`).
hexapod_v3.leg_pair_count = 3       -- un hexapod a 6 pattes, donc 3 paires
hexapod_v3.leg_pair_spacing = 3     -- ecart (en segments du train) entre deux hanches -> 2 segments vides entre deux paires de pattes
hexapod_v3.leg_femur_height = 2     -- nombre de noeuds du femur (horizontal)
hexapod_v3.leg_tibia_height = 3     -- nombre de noeuds du tibia (vertical, colle sur la face avant du genou)

-- Demarche "tripode" (comme un vrai hexapode) : les 6 pattes sont reparties
-- en 2 groupes de 3 qui alternent balancement (patte levee, avance) et appui
-- (patte au sol, recule) -- voir `hexapod_v3.update_legs`. La hanche ne peut
-- tourner qu'a l'horizontale (elle entraine tout le femur+tibia avec elle,
-- balayage avant/arriere) ; le genou ne peut tourner qu'a la verticale (il
-- n'entraine que le tibia, levee/pose du pied).
hexapod_v3.leg_hip_swing_deg = 25    -- amplitude du balayage horizontal de la hanche
hexapod_v3.leg_knee_lift_deg = 35    -- amplitude de la levee verticale du genou
hexapod_v3.leg_gait_speed = math.pi * 2  -- vitesse de la phase de marche, en radians/seconde (1 cycle/s par defaut)

-- Distance verticale entre le centre du corps et le point le plus bas des
-- pattes, utilisee pour poser le hexapod assez haut pour que ses pattes ne
-- s'enfoncent pas dans le sol (voir le `on_place` de l'item plus bas).
-- Avec la chaine "en L" (cf. `hexapod_v3.spawn_leg`), le premier node du
-- femur est colle directement sous la hanche (1 cran) ; le premier node de
-- tibia est sur la face avant du genou, a la meme hauteur que lui (0 cran
-- vertical) ; seuls les `leg_tibia_height - 1` nodes de tibia suivants
-- descendent, plus une demi-taille de node pour atteindre la face basse du
-- dernier node de tibia.
hexapod_v3.leg_drop = hexapod_v3.tail_size * (hexapod_v3.leg_tibia_height + 0.5)

-- Distance horizontale maximale entre le centre d'une hanche et le bout de
-- la patte (genou), utilisee pour dimensionner les "relais" de collision
-- des pattes (voir hexapod_v3.leg_collider plus bas).
hexapod_v3.leg_reach = hexapod_v3.tail_size * (hexapod_v3.leg_femur_height + 1) + hexapod_v3.tail_size / 2

-- Decalage local en Z (par rapport au centre du corps) de chacune des
-- hanches, calcule avec la meme formule que `hexapod_v3.spawn_tail` (pour
-- l'offset des segments du train) et `hexapod_v3.spawn_legs` (pour
-- l'indice de segment de chaque paire de pattes).
hexapod_v3.leg_relay_z = {}
for i = 1, hexapod_v3.leg_pair_count do
	local segment_index = 1 + (i - 1) * hexapod_v3.leg_pair_spacing
	hexapod_v3.leg_relay_z[i] =
		-(0.5 + hexapod_v3.tail_size / 2 + (segment_index - 1) * hexapod_v3.tail_size)
end

-- Decalage local {x, z} (par rapport au centre du corps) de chaque relais
-- de collision : une entite n'est prise en compte pour la collision
-- joueur/objet que si le joueur se trouve a moins d'environ 3,4 noeuds de
-- sa position PROPRE (limite du moteur, cf.
-- `ActiveObjectMgr::getActiveObjects`). Un relais centre sur la hanche
-- (x=0) et large de `hexapod_v3.leg_reach` (3.5) place le bout de patte
-- tout juste a la limite de cette portee -- observe en jeu : le dessus de
-- la patte bloque (le joueur, debout dessus, est proche de la hanche) mais
-- pas les flancs (le joueur, au niveau du pied, est a ~leg_reach de la
-- hanche).
--
-- D'ou, PAR PAIRE de pattes, TROIS relais (donc 9 au total), tous avec la
-- meme petite boite (hexapod_v3.leg_collider_half) pour rester bien en
-- deca de la limite du moteur, quel que soit le point teste :
--  - un au centre (x=0), sur la hanche/colonne vertebrale -- sans lui, le
--    dessus du corps pres d'une hanche n'est plus couvert du tout (essaye
--    en jeu avec uniquement les deux relais de pattes ci-dessous : plus
--    aucune collision au-dessus du robot dans cette zone) ;
--  - un a droite et un a gauche (x = +-hexapod_v3.leg_reach), directement
--    sur le pied de chaque patte.
hexapod_v3.leg_collider_half = 2
hexapod_v3.leg_relay_offsets = {}
for _, z_center in ipairs(hexapod_v3.leg_relay_z) do
	table.insert(hexapod_v3.leg_relay_offsets, { x = 0, z = z_center })
	for _, side in ipairs({ 1, -1 }) do
		table.insert(hexapod_v3.leg_relay_offsets, { x = side * hexapod_v3.leg_reach, z = z_center })
	end
end

-- Ensemble des hexapods actifs (cle = luaentity), utilise pour detacher
-- proprement un joueur qui se deconnecte pendant qu'il pilote.
hexapod_v3.pods = {}

-- Physique (vitesse, saut, gravite) sauvegardee par joueur pendant qu'il
-- pilote, pour la restaurer telle quelle a la fin.
hexapod_v3.saved_physics = {}

-- Calcule la position (position du pied du joueur) a laquelle la camera
-- doit se trouver pour que `pod_pos` soit exactement au centre de la vue,
-- a distance fixe, selon la direction actuellement regardee par le joueur.
function hexapod_v3.compute_camera_pos(pod_pos, look_dir, player)
	local eye_pos = vector.subtract(pod_pos, vector.multiply(look_dir, hexapod_v3.camera_distance))

	local props = player:get_properties()
	local eye_height = (props and props.eye_height) or 1.625
	eye_pos.y = eye_pos.y - eye_height

	return eye_pos
end

-- Deplace la rig-camera du hexapod pour que celui-ci reste centre dans la
-- vue du joueur qui le pilote.
--
-- Important : on n'utilise PAS `set_pos()` a chaque pas. Cote moteur,
-- `ObjectRef:set_pos()` teleporte l'entite ET force un envoi immediat de sa
-- position au client SANS interpolation (voir `LuaEntitySAO::setPos`, qui
-- appelle `sendPosition(false, true)` -- le premier `false` desactive
-- l'interpolation cote client) : appeler ca a chaque pas de simulation
-- produit donc des a-coups constants. `move_to(pos, true)` est concu par le
-- moteur precisement pour des "transitions visuellement fluides" : la
-- position cible est mise a jour en continu et le client interpole
-- normalement entre deux positions envoyees.
function hexapod_v3.update_camera(self, player)
	local look_dir = player:get_look_dir()
	local pod_pos = self.object:get_pos()
	local target = hexapod_v3.compute_camera_pos(pod_pos, look_dir, player)
	self.camera_rig:move_to(target, true)
end

-- Attache une roue au flanc (droit ou gauche) du hexapod : `side` = 1 pour
-- la roue droite, -1 pour la roue gauche.
--
-- Contrairement a la camera (qui doit suivre un joueur avec un regard
-- libre, donc etre positionnee independamment), les roues doivent rester
-- rigoureusement collees au corps du hexapod : utiliser `move_to()` comme
-- pour la camera provoquerait un decalage constant vers l'arriere des que
-- le hexapod bouge, puisque cette methode fait "rattraper" une cible en
-- mouvement par interpolation (donc toujours legerement en retard). Le
-- veritable attachement moteur (`set_attach`), lui, colle la roue a la
-- position/rotation *courante* du parent a chaque image, sans latence.
--
-- Note : la position passee a `set_attach` doit etre multipliee par 10 par
-- rapport aux coordonnees monde (cf. section "Attachments" de lua_api.md).
function hexapod_v3.attach_wheel(wheel, pod_object, side)
	wheel:set_attach(pod_object, "",
		{ x = side * hexapod_v3.wheel_offset * 10, y = 0, z = 0 },
		{ x = 0, y = 0, z = 0 })
end

-- Cree et attache, a la queue leu leu derriere le hexapod, le "train
-- arriere" : une rangee de `hexapod_v3.tail_count` segments (le premier
-- colle a la face arriere -Z, puis un par un le long de -Z). Purement
-- decoratif et statique : un seul `set_attach` par segment suffit, pas
-- besoin de le rappeler a chaque pas (contrairement aux roues, ces
-- segments ne tournent pas sur eux-memes).
function hexapod_v3.spawn_tail(self)
	self.tail_segments = {}
	local pod_object = self.object
	local pod_pos = pod_object:get_pos()

	for i = 1, hexapod_v3.tail_count do
		local segment = minetest.add_entity(pod_pos, "hexapod_v3:tail_segment")
		local offset_z = -(0.5 + hexapod_v3.tail_size / 2 + (i - 1) * hexapod_v3.tail_size)
		segment:set_attach(pod_object, "", { x = 0, y = 0, z = offset_z * 10 }, { x = 0, y = 0, z = 0 })
		table.insert(self.tail_segments, segment)
	end
end

-- Cree une piece de patte (`entity_name` : segment ou jointure), attachee
-- a `parent_object` avec un decalage local `offset` ({x,y,z}, en noeuds).
-- Meme taille que les nodes du corps (`hexapod_v3.tail_size`).
function hexapod_v3.spawn_leg_part(entity_name, parent_object, parent_pos, offset, rotation)
	local part = minetest.add_entity(parent_pos, entity_name)
	part:set_attach(parent_object, "",
		{ x = offset.x * 10, y = offset.y * 10, z = offset.z * 10 },
		rotation or { x = 0, y = 0, z = 0 })
	return part
end

-- Construit une patte complete "en L" (hanche -> femur horizontal -> genou
-- -> tibia vertical), suspendue sous le flanc (`side` = 1 pour droite, -1
-- pour gauche) du segment "hanche" qui sert de parent a la patte, et
-- assignee au groupe de demarche `group` (1 ou 2, cf. `hexapod_v3.update_legs`).
-- Chaque piece est un node de la meme taille que le corps
-- (`hexapod_v3.tail_size`). Les deux nodes de jointure -- la **hanche**
-- (corps<->femur) et le **genou** (femur<->tibia) -- utilisent une
-- entite/texture distincte (`hexapod_v3:leg_joint`) de celle des segments
-- de femur/tibia (`hexapod_v3:leg_part`, texture du corps).
--
-- Forme de la patte au repos (side = 1, vue de profil x/y, x vers la
-- droite = s'eloigne du corps, y vers le bas) :
--   y=0    [Hanche]
--   y=-s   [Femur][Femur]...[Genou]
--   y=-2s..                      [Tibia]  <- vu de face (z), decale vers l'avant
--   ...                          [Tibia]
-- Le premier node du femur est colle directement sous la hanche (meme
-- `x`, un cran plus bas) ; le femur continue ensuite a l'horizontale
-- (`x` avance, `y` fixe) jusqu'au genou. Le premier node de tibia est
-- colle sur la face AVANT du genou (`z` avance d'un cran vers +Z, la
-- direction du regard du hexapod -- meme `x`, meme `y`) ; les nodes de
-- tibia suivants repartent de la a la verticale (`z` fixe, `y` descend).
-- Chaque transition ne change qu'un seul axe a la fois, pour que les
-- nodes restent colles face contre face (un decalage simultane sur deux
-- axes laisserait un vide de la taille d'un node entre deux nodes, qui ne
-- se toucheraient plus que par une arete).
--
-- Contrairement au train, chaque piece est desormais attachee a la
-- PRECEDENTE (et non plus toutes directement a la hanche du train) : une
-- vraie chaine articulee, ou faire pivoter un parent entraine tout ce qui
-- lui est attache en dessous.
--
-- La hanche elle-meme NE DOIT PAS bouger : c'est un node invisible
-- ("hexapod_v3:leg_pivot", taille nulle), colle exactement a sa position
-- (decalage nul), qui sert de pivot au femur. Sa `rotation` est reanimee
-- a chaque pas par `hexapod_v3.update_legs` (comme les roues) : faire
-- tourner ce pivot (axe Y, horizontal) balaie tout le femur+genou+tibia
-- d'un bloc, la hanche restant parfaitement immobile. Le genou, lui,
-- sert directement de pivot pour le tibia (axe X, vertical). Hanche,
-- femur et tibia eux-memes ne tournent jamais (rotation toujours nulle),
-- ils suivent passivement leur pivot.
function hexapod_v3.spawn_leg(self, hip_object, side, group)
	local s = hexapod_v3.tail_size
	local hip_pos = hip_object:get_pos()

	local hanche_offset = { x = side * s, y = 0, z = 0 }  -- s/2 (flanc de la hanche) + s/2 (flanc de la piece)
	local hanche = hexapod_v3.spawn_leg_part("hexapod_v3:leg_joint", hip_object, hip_pos, hanche_offset)
	table.insert(self.leg_parts, hanche)

	-- Pivot de hanche : colle exactement sur la hanche (decalage nul),
	-- immobile au repos ; seule sa rotation sera animee.
	local hip_pivot = hexapod_v3.spawn_leg_part("hexapod_v3:leg_pivot", hanche, hip_pos, { x = 0, y = 0, z = 0 })
	table.insert(self.leg_parts, hip_pivot)

	-- Premier node de femur : colle directement sous le pivot de hanche
	-- (meme x, dans son repere local -- donc sous la hanche au repos).
	local first_femur = hexapod_v3.spawn_leg_part("hexapod_v3:leg_part", hip_pivot, hip_pos, { x = 0, y = -s, z = 0 })
	table.insert(self.leg_parts, first_femur)

	-- Nodes de femur suivants : a l'horizontale, chaines les uns aux
	-- autres, a la meme hauteur.
	local femur_end = first_femur
	for _ = 2, hexapod_v3.leg_femur_height do
		femur_end = hexapod_v3.spawn_leg_part("hexapod_v3:leg_part", femur_end, hip_pos, { x = side * s, y = 0, z = 0 })
		table.insert(self.leg_parts, femur_end)
	end

	local genou_offset = { x = side * s, y = 0, z = 0 }
	local genou = hexapod_v3.spawn_leg_part("hexapod_v3:leg_joint", femur_end, hip_pos, genou_offset)
	table.insert(self.leg_parts, genou)

	-- Premier node de tibia : colle sur la face avant du genou (meme x, y,
	-- dans le repere local du genou).
	local first_tibia = hexapod_v3.spawn_leg_part("hexapod_v3:leg_part", genou, hip_pos, { x = 0, y = 0, z = s })
	table.insert(self.leg_parts, first_tibia)

	-- Nodes de tibia suivants : a la verticale, chaines les uns aux
	-- autres, sous le premier.
	local tibia_end = first_tibia
	for _ = 2, hexapod_v3.leg_tibia_height do
		tibia_end = hexapod_v3.spawn_leg_part("hexapod_v3:leg_part", tibia_end, hip_pos, { x = 0, y = -s, z = 0 })
		table.insert(self.leg_parts, tibia_end)
	end

	table.insert(self.legs, {
		hip_pivot = hip_pivot,
		hip_pivot_parent = hanche,
		genou = genou,
		genou_parent = femur_end,
		genou_offset = genou_offset,
		group = group,
	})
end

-- Construit les `hexapod_v3.leg_pair_count` paires de pattes (gauche et
-- droite, symetriques), une paire tous les `hexapod_v3.leg_pair_spacing`
-- segments du train, en partant de celui immediatement derriere la tete
-- (hexapod_v3.tail_segments[1], [1 + spacing], [1 + 2*spacing], ...).
-- Avec les valeurs par defaut (spacing = 3), deux segments du train
-- restent donc libres entre deux paires de pattes plutot que d'etre
-- colles a la precedente.
--
-- Chaque patte est assignee a l'un des deux groupes de la demarche
-- tripode (cf. `hexapod_v3.update_legs`) en alternant paire par paire et
-- cote par cote, de sorte que deux pattes voisines (meme paire, ou meme
-- cote sur deux paires consecutives) ne soient jamais dans le meme
-- groupe -- motif classique avant-droite/milieu-gauche/arriere-droite
-- contre avant-gauche/milieu-droite/arriere-gauche.
function hexapod_v3.spawn_legs(self)
	self.leg_parts = {}
	self.legs = {}
	for i = 1, hexapod_v3.leg_pair_count do
		local segment_index = 1 + (i - 1) * hexapod_v3.leg_pair_spacing
		local hip_object = self.tail_segments[segment_index]
		if not hip_object then
			break
		end
		hexapod_v3.spawn_leg(self, hip_object, 1, (i % 2 == 0) and 1 or 2)   -- droite
		hexapod_v3.spawn_leg(self, hip_object, -1, (i % 2 == 0) and 2 or 1)  -- gauche
	end
end

-- Fait tourner les roues autour de leur axe (rotation.x, en degres)
-- proportionnellement a la vitesse d'avancement signee du hexapod
-- (positive en marche avant, negative en marche arriere, nulle a l'arret
-- ou lors d'un simple pivot sur place).
--
-- Etant attachees, on ne peut pas animer leur rotation via `set_rotation`
-- (ignore sur un objet attache, cf. lua_api.md) : il faut rappeler
-- `set_attach` avec la nouvelle rotation. Seule la rotation change a
-- chaque appel, la position (l'offset lateral) reste fixe.
function hexapod_v3.update_wheels(self, dtime, signed_speed)
	if not self.wheel_right or not self.wheel_left then
		return
	end

	local angular_speed_deg = -math.deg(signed_speed / hexapod_v3.wheel_radius)
	self.wheel_spin_deg = (self.wheel_spin_deg + angular_speed_deg * dtime) % 360

	local rotation = { x = self.wheel_spin_deg, y = 0, z = 0 }
	self.wheel_right:set_attach(self.object, "",
		{ x = hexapod_v3.wheel_offset * 10, y = 0, z = 0 }, rotation)
	self.wheel_left:set_attach(self.object, "",
		{ x = -hexapod_v3.wheel_offset * 10, y = 0, z = 0 }, rotation)
end

-- Anime la demarche "tripode" des pattes : les deux groupes (1 et 2, cf.
-- `hexapod_v3.spawn_legs`) sont en opposition de phase (dephasage de pi),
-- de sorte que lorsque l'un est en balancement (patte levee, avance),
-- l'autre est en appui (patte au sol, recule), et inversement.
--
-- Le pivot de hanche et le genou etant attaches (donc `set_rotation()`
-- est ignore, comme pour les roues), on reanime leur rotation en
-- rappelant `set_attach` a chaque pas avec le meme decalage de position
-- mais une nouvelle rotation :
-- - pivot de hanche (decalage nul, colle sur la hanche) : rotation.y
--   (horizontale) = balayage avant/arriere de toute la patte
--   (femur+genou+tibia, qui lui sont tous attaches en cascade), la hanche
--   elle-meme restant immobile ;
-- - genou : rotation.x (verticale) = levee/pose du tibia seul. La levee
--   n'a lieu que sur la moitie "avant" du cycle (sin > 0, phase de
--   balancement) ; le genou reste a plat (0) pendant la moitie "arriere"
--   (phase d'appui), pour que la patte pousse au sol sans se relever.
function hexapod_v3.update_legs(self, dtime, moving)
	if not self.legs then
		return
	end

	if moving then
		self.leg_phase = (self.leg_phase + hexapod_v3.leg_gait_speed * dtime) % (2 * math.pi)
	end

	for _, leg in ipairs(self.legs) do
		local phase = self.leg_phase + (leg.group == 1 and 0 or math.pi)
		local hip_deg = hexapod_v3.leg_hip_swing_deg * math.sin(phase)
		local knee_deg = hexapod_v3.leg_knee_lift_deg * math.max(0, math.sin(phase))

		leg.hip_pivot:set_attach(leg.hip_pivot_parent, "",
			{ x = 0, y = 0, z = 0 },
			{ x = 0, y = hip_deg, z = 0 })
		leg.genou:set_attach(leg.genou_parent, "",
			{ x = leg.genou_offset.x * 10, y = leg.genou_offset.y * 10, z = leg.genou_offset.z * 10 },
			{ x = knee_deg, y = 0, z = 0 })
	end
end

-- Demarre/arrete un son en boucle attache au hexapod selon une condition
-- booleenne (`active`), en se souvenant de son handle dans le champ
-- `self[handle_field]` pour pouvoir l'arreter plus tard. Utilise pour le
-- son de moteur (avance) et le son de direction (pivote). Le son est
-- positionne sur l'entite (`object = self.object`) : le moteur audio du
-- client le repositionne lui-meme a chaque image tant qu'il joue, pas
-- besoin de le relancer pour le faire suivre le hexapod.
function hexapod_v3.set_looping_sound(self, handle_field, active, sound_name, gain, max_hear_distance)
	if active and not self[handle_field] then
		self[handle_field] = minetest.sound_play(sound_name, {
			object = self.object,
			gain = gain,
			max_hear_distance = max_hear_distance,
			loop = true,
		})
	elseif not active and self[handle_field] then
		minetest.sound_stop(self[handle_field])
		self[handle_field] = nil
	end
end

-- Joue le son de moteur tant que le hexapod avance (signed_speed
-- strictement positif), et l'arrete des qu'il ne va plus vers l'avant
-- (arret, marche arriere ou pivot).
function hexapod_v3.update_engine_sound(self, signed_speed)
	hexapod_v3.set_looping_sound(self, "engine_sound_handle", signed_speed > 0,
		hexapod_v3.engine_sound, hexapod_v3.engine_sound_gain,
		hexapod_v3.engine_sound_max_hear_distance)
end

-- Joue le son de direction tant que le hexapod pivote (Gauche ou Droite),
-- que ce soit sur place ou en avancant/reculant en meme temps.
function hexapod_v3.update_turn_sound(self, turning)
	hexapod_v3.set_looping_sound(self, "turn_sound_handle", turning,
		hexapod_v3.turn_sound, hexapod_v3.turn_sound_gain,
		hexapod_v3.turn_sound_max_hear_distance)
end

function hexapod_v3.start_driving(self, player)
	local name = player:get_player_name()
	self.driver = player
	hexapod_v3.saved_physics[name] = player:get_physics_override()
	player:set_physics_override({ speed = 0, jump = 0, gravity = 0 })

	local look_dir = player:get_look_dir()
	local pod_pos = self.object:get_pos()
	local target = hexapod_v3.compute_camera_pos(pod_pos, look_dir, player)
	self.camera_rig = minetest.add_entity(target, "hexapod_v3:camera_rig")
	player:set_attach(self.camera_rig, "", { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 })

	minetest.chat_send_player(name,
		"[Hexapod] Vous prenez les commandes du hexapod. Clic droit pour descendre.")
end

function hexapod_v3.stop_driving(self, player)
	local name = player:get_player_name()
	local saved = hexapod_v3.saved_physics[name]
	if saved then
		player:set_physics_override(saved)
		hexapod_v3.saved_physics[name] = nil
	end
	if self.driver == player then
		self.driver = nil
	end
	player:set_detach()
	if self.camera_rig then
		self.camera_rig:remove()
		self.camera_rig = nil
	end
	-- Arrete le deplacement horizontal, mais preserve la vitesse verticale
	-- courante (chute en cours due a hexapod_v3.gravity) : relacher les
	-- commandes en l'air ne doit pas interrompre la chute.
	local vel = self.object:get_velocity()
	self.object:set_velocity({ x = 0, y = vel.y, z = 0 })

	minetest.chat_send_player(name, "[Hexapod] Vous quittez le hexapod.")
end

-- Entite invisible (taille nulle) qui sert de support de camera : le
-- joueur qui pilote un hexapod y est attache, et c'est elle qu'on deplace
-- chaque pas de simulation pour suivre le hexapod. Etant une entite comme
-- une autre, le client l'interpole en douceur entre deux positions.
minetest.register_entity("hexapod_v3:camera_rig", {
	initial_properties = {
		visual = "cube",
		visual_size = { x = 0, y = 0, z = 0 },
		physical = false,
		collide_with_objects = false,
		collisionbox = { 0, 0, 0, 0, 0, 0 },
		pointable = false,
		static_save = false,
		textures = {},
	},
})

-- Roue decorative attachee de part et d'autre du hexapod : roue droite ou
-- roue gauche selon le cote (voir `hexapod_v3.update_wheels`).
minetest.register_entity("hexapod_v3:wheel", {
	initial_properties = {
		visual = "cube",
		visual_size = { x = hexapod_v3.wheel_size, y = hexapod_v3.wheel_size, z = hexapod_v3.wheel_size },
		textures = {
			"hexapod_v3_wheel.png", "hexapod_v3_wheel.png",
			"hexapod_v3_wheel.png", "hexapod_v3_wheel.png",
			"hexapod_v3_wheel.png", "hexapod_v3_wheel.png",
		},
		physical = false,
		collide_with_objects = false,
		collisionbox = { 0, 0, 0, 0, 0, 0 },
		pointable = false,
		static_save = false,
	},
})

-- Segment decoratif statique du "train arriere" attache derriere le
-- hexapod (voir `hexapod_v3.spawn_tail`). Memes textures que le corps du
-- hexapod.
minetest.register_entity("hexapod_v3:tail_segment", {
	initial_properties = {
		visual = "cube",
		visual_size = { x = hexapod_v3.tail_size, y = hexapod_v3.tail_size, z = hexapod_v3.tail_size },
		textures = {
			"hexapod_v3_node.png", "hexapod_v3_node.png",
			"hexapod_v3_node.png", "hexapod_v3_node.png",
			"hexapod_v3_node.png", "hexapod_v3_node.png",
		},
		physical = false,
		collide_with_objects = false,
		collisionbox = { 0, 0, 0, 0, 0, 0 },
		pointable = false,
		static_save = false,
	},
})

-- Segment de femur/tibia (voir `hexapod_v3.spawn_leg`), texture du corps.
-- Meme taille que les nodes du corps (`hexapod_v3.tail_size`).
minetest.register_entity("hexapod_v3:leg_part", {
	initial_properties = {
		visual = "cube",
		visual_size = { x = hexapod_v3.tail_size, y = hexapod_v3.tail_size, z = hexapod_v3.tail_size },
		textures = {
			"hexapod_v3_node.png", "hexapod_v3_node.png",
			"hexapod_v3_node.png", "hexapod_v3_node.png",
			"hexapod_v3_node.png", "hexapod_v3_node.png",
		},
		physical = false,
		collide_with_objects = false,
		collisionbox = { 0, 0, 0, 0, 0, 0 },
		pointable = false,
		static_save = false,
	},
})

-- Node de jointure (corps<->femur et femur<->tibia, voir
-- `hexapod_v3.spawn_leg`), texture distincte du corps pour marquer les
-- articulations. Meme taille que les nodes du corps (`hexapod_v3.tail_size`).
minetest.register_entity("hexapod_v3:leg_joint", {
	initial_properties = {
		visual = "cube",
		visual_size = { x = hexapod_v3.tail_size, y = hexapod_v3.tail_size, z = hexapod_v3.tail_size },
		textures = {
			"hexapod_v3_joint.png", "hexapod_v3_joint.png",
			"hexapod_v3_joint.png", "hexapod_v3_joint.png",
			"hexapod_v3_joint.png", "hexapod_v3_joint.png",
		},
		physical = false,
		collide_with_objects = false,
		collisionbox = { 0, 0, 0, 0, 0, 0 },
		pointable = false,
		static_save = false,
	},
})

-- Pivot invisible de hanche (voir `hexapod_v3.spawn_leg`) : colle sans
-- decalage sur la hanche, seule sa rotation est animee
-- (`hexapod_v3.update_legs`) -- la hanche elle-meme ne bouge donc jamais.
--
-- Important : `visual_size` ne doit PAS etre nul ({0,0,0}). Le femur (et
-- tout le reste de la patte) est chaine en veritable enfant de ce pivot
-- (cf. `hexapod_v3.spawn_leg`) : une echelle nulle sur le parent se
-- propage multiplicativement a tous ses descendants dans le graphe de
-- scene, ce qui les rendrait tous invisibles (taille nulle) quelle que
-- soit leur propre `visual_size`. On utilise donc une taille normale
-- (comme les autres pieces), et -- avec une taille non nulle, des
-- textures vides affichent un cube "texture manquante" au lieu de rien
-- (contrairement a `hexapod_v3:camera_rig`, invisible seulement parce que
-- sa taille est nulle) -- une texture reellement transparente
-- (`hexapod_v3_invisible.png`, alpha nul) pour le rendre invisible sans
-- toucher a son echelle.
minetest.register_entity("hexapod_v3:leg_pivot", {
	initial_properties = {
		visual = "cube",
		visual_size = { x = hexapod_v3.tail_size, y = hexapod_v3.tail_size, z = hexapod_v3.tail_size },
		physical = false,
		collide_with_objects = false,
		collisionbox = { 0, 0, 0, 0, 0, 0 },
		pointable = false,
		static_save = false,
		textures = {
			"hexapod_v3_invisible.png", "hexapod_v3_invisible.png",
			"hexapod_v3_invisible.png", "hexapod_v3_invisible.png",
			"hexapod_v3_invisible.png", "hexapod_v3_invisible.png",
		},
	},
})

-- Relais de collision d'une patte (voir hexapod_v3.leg_relay_offsets) :
-- une entite independante (PAS attachee : un objet attache n'a, cote
-- serveur, pas d'autre position que celle de son parent, cf.
-- LuaEntitySAO::step), repositionnee chaque pas exactement sur le pied de
-- la patte (hexapod_v3.on_step). `pointable = true` est essentiel : sans
-- lui la collision joueur/objet ne se declenche jamais ici, meme avec
-- `physical = true` et `collide_with_objects = true` (verifie en jeu par
-- A/B : une entite de test par ailleurs identique, mais `pointable =
-- false`, ne bloquait jamais le joueur).
--
-- `pointable = true` rend en revanche l'objet cliquable, avec une
-- `selectionbox` qui recopie par defaut la `collisionbox`. D'ou la
-- `selectionbox` explicite, nulle, ci-dessous : sans elle, un clic droit
-- pres d'un relais viserait ce dernier plutot que le sol (empechant de
-- poser un autre hexapod a proximite) ou plutot que le corps du hexapod
-- (empechant de le piloter).
--
-- La collisionbox est carree (meme etendue en X et en Z,
-- hexapod_v3.leg_collider_half) : le moteur ne fait jamais tourner une
-- collisionbox avec le yaw d'une entite (elle reste toujours alignee sur
-- les axes du monde) -- une boite carree reste donc valable quelle que
-- soit l'orientation du hexapod, puisque l'origine du relais, elle, suit
-- deja la rotation (voir hexapod_v3.leg_relay_offsets).
--
-- Verticalement, la boite est CENTREE sur l'origine du relais (et non
-- calee sur celle-ci comme un simple bas/haut) : l'origine suivie par le
-- moteur pour la portee de ~3,4 noeuds (cf. plus haut) est la POSITION du
-- relais lui-meme (hexapod_v3.on_step la place a hauteur du corps -
-- hexapod_v3.leg_drop / 2, soit le milieu de la patte, PAS a hauteur du
-- corps) -- sinon, marcher au ras du sol contre le pied
-- (a hexapod_v3.leg_drop sous le corps) met le joueur hors de portee de
-- cette origine, meme si il est bien a l'interieur de la boite (verifie
-- en jeu : ca bloquait par-dessus, pres du corps, mais pas de face, au
-- niveau du pied).
minetest.register_entity("hexapod_v3:leg_collider", {
	initial_properties = {
		visual = "cube",
		visual_size = {
			x = 2 * hexapod_v3.leg_collider_half,
			y = 1 + hexapod_v3.leg_drop,
			z = 2 * hexapod_v3.leg_collider_half,
		},
		textures = {
			"hexapod_v3_invisible.png", "hexapod_v3_invisible.png",
			"hexapod_v3_invisible.png", "hexapod_v3_invisible.png",
			"hexapod_v3_invisible.png", "hexapod_v3_invisible.png",
		},
		collisionbox = {
			-hexapod_v3.leg_collider_half, -(1 + hexapod_v3.leg_drop) / 2, -hexapod_v3.leg_collider_half,
			hexapod_v3.leg_collider_half, (1 + hexapod_v3.leg_drop) / 2, hexapod_v3.leg_collider_half,
		},
		selectionbox = { 0, 0, 0, 0, 0, 0 },
		physical = true,
		collide_with_objects = true,
		pointable = true,
		static_save = false,
	},
})

minetest.register_entity("hexapod_v3:pod", {
	initial_properties = {
		visual = "cube",
		visual_size = { x = 1, y = 1, z = 1 },
		-- Ordre des faces d'un visual "cube" (identique aux tiles des nodes) :
		-- +Y (haut), -Y (bas), +X, -X, +Z, -Z. Comme `minetest.yaw_to_dir(0)`
		-- vaut (0,0,1), la face +Z est celle qui pointe dans la direction
		-- d'avancee a yaw=0 : c'est donc elle qui recoit la texture "avant".
		textures = {
			"hexapod_v3_node.png", "hexapod_v3_node.png",
			"hexapod_v3_node.png", "hexapod_v3_node.png",
			"hexapod_v3_node_front.png", "hexapod_v3_node.png",
		},
		-- Etendue vers le bas jusqu'a la pointe des pattes (hexapod_v3.leg_drop
		-- sous le centre du corps) : sans ca, la gravite arrete la chute des
		-- que le CORPS touche le sol, laissant les pattes s'enfoncer dedans.
		-- La collision des pattes elles-memes (X/Z) est geree separement par
		-- des relais independants, voir "hexapod_v3:leg_collider" plus haut :
		-- une collisionbox geante ici, centree sur le corps, ne fonctionnerait
		-- pas au-dela d'environ 3,4 noeuds de distance (limite du moteur).
		collisionbox = { -0.5, -(0.5 + hexapod_v3.leg_drop), -0.5, 0.5, 0.5, 0.5 },
		physical = true,
		collide_with_objects = true,
		pointable = true,
		static_save = true,
	},

	driver = nil,
	camera_rig = nil,
	wheel_right = nil,  -- roue droite
	wheel_left = nil,   -- roue gauche
	wheel_spin_deg = 0,
	engine_sound_handle = nil,
	turn_sound_handle = nil,
	tail_segments = nil,  -- segments du "train arriere"
	leg_parts = nil,
	legs = nil,        -- pivots (hanche/genou) de chaque patte, pour la demarche
	leg_phase = 0,
	leg_colliders = nil,  -- relais de collision des pattes (voir hexapod_v3:leg_collider)

	on_activate = function(self)
		self.object:set_acceleration({ x = 0, y = -hexapod_v3.gravity, z = 0 })
		hexapod_v3.pods[self] = true

		local pos = self.object:get_pos()
		self.wheel_right = minetest.add_entity(pos, "hexapod_v3:wheel")  -- roue droite
		self.wheel_left = minetest.add_entity(pos, "hexapod_v3:wheel")   -- roue gauche
		hexapod_v3.attach_wheel(self.wheel_right, self.object, 1)
		hexapod_v3.attach_wheel(self.wheel_left, self.object, -1)

		hexapod_v3.spawn_tail(self)  -- train arriere
		hexapod_v3.spawn_legs(self)

		-- Relais de collision des pattes : PAS attaches (`set_attach`), car
		-- un objet attache n'a, cote serveur, pas d'autre position que celle
		-- de son parent (cf. LuaEntitySAO::step) -- juste repositionnes
		-- chaque pas sur chaque pied (voir on_step), en tenant compte du
		-- yaw courant.
		self.leg_colliders = {}
		for _, offset in ipairs(hexapod_v3.leg_relay_offsets) do
			table.insert(self.leg_colliders,
				minetest.add_entity(
					vector.add(pos, { x = offset.x, y = -hexapod_v3.leg_drop / 2, z = offset.z }),
					"hexapod_v3:leg_collider"))
		end
	end,

	on_deactivate = function(self)
		if self.driver and self.driver:is_player() then
			hexapod_v3.stop_driving(self, self.driver)
		end
		if self.wheel_right then
			self.wheel_right:remove()
			self.wheel_right = nil
		end
		if self.wheel_left then
			self.wheel_left:remove()
			self.wheel_left = nil
		end
		if self.engine_sound_handle then
			minetest.sound_stop(self.engine_sound_handle)
			self.engine_sound_handle = nil
		end
		if self.turn_sound_handle then
			minetest.sound_stop(self.turn_sound_handle)
			self.turn_sound_handle = nil
		end
		if self.tail_segments then
			for _, segment in ipairs(self.tail_segments) do
				segment:remove()
			end
			self.tail_segments = nil
		end
		if self.leg_parts then
			for _, part in ipairs(self.leg_parts) do
				part:remove()
			end
			self.leg_parts = nil
		end
		self.legs = nil
		if self.leg_colliders then
			for _, collider in ipairs(self.leg_colliders) do
				collider:remove()
			end
			self.leg_colliders = nil
		end
		hexapod_v3.pods[self] = nil
	end,

	on_rightclick = function(self, clicker)
		if not clicker or not clicker:is_player() then
			return
		end

		if self.driver then
			if self.driver == clicker then
				hexapod_v3.stop_driving(self, clicker)
			else
				minetest.chat_send_player(clicker:get_player_name(),
					"[Hexapod] Ce hexapod est deja pilote par quelqu'un d'autre.")
			end
			return
		end

		hexapod_v3.start_driving(self, clicker)
	end,

	on_step = function(self, dtime)
		local driver = self.driver
		local signed_speed = 0
		local turning = false

		if driver and driver:is_player() then
			local ctrl = driver:get_player_control()
			local yaw = self.object:get_yaw()

			if ctrl.left then
				yaw = yaw + hexapod_v3.turn_speed * dtime
				turning = true
			end
			if ctrl.right then
				yaw = yaw - hexapod_v3.turn_speed * dtime
				turning = true
			end
			self.object:set_yaw(yaw)

			-- On ne pilote que le deplacement horizontal : la composante
			-- verticale de la vitesse (chute due a hexapod_v3.gravity, ou
			-- reaction du moteur au contact du sol) est preservee telle
			-- quelle, pour que le hexapod continue de tomber normalement
			-- meme pendant qu'on le pilote (par exemple s'il marche jusqu'au
			-- bord d'une falaise).
			local dir = minetest.yaw_to_dir(yaw)
			local vel = { x = 0, y = self.object:get_velocity().y, z = 0 }
			if ctrl.up then
				local horizontal = vector.multiply(dir, hexapod_v3.forward_speed)
				vel.x, vel.z = horizontal.x, horizontal.z
				signed_speed = hexapod_v3.forward_speed
			elseif ctrl.down then
				local horizontal = vector.multiply(dir, -hexapod_v3.forward_speed)
				vel.x, vel.z = horizontal.x, horizontal.z
				signed_speed = -hexapod_v3.forward_speed
			end
			self.object:set_velocity(vel)

			hexapod_v3.update_camera(self, driver)
		else
			self.driver = nil
		end

		-- Les relais de collision des pattes suivent la position ET le yaw
		-- du corps (leur decalage local {x, z} est tourne en consequence)
		-- via `set_pos` (pas `move_to`, pour ne pas trainer derriere le
		-- corps). "avant" = minetest.yaw_to_dir(yaw) ; "droite" = son
		-- perpendiculaire (verifie a yaw=0 : (1,0,0), coherent avec `side`
		-- = 1 = droite utilise ailleurs, cf. hexapod_v3.attach_wheel).
		--
		-- Le decalage vertical (-hexapod_v3.leg_drop / 2) place l'origine
		-- du relais au milieu de sa propre boite (et non a hauteur du
		-- corps) : voir le commentaire sur hexapod_v3:leg_collider plus
		-- haut.
		if self.leg_colliders then
			local pod_pos = self.object:get_pos()
			local yaw = self.object:get_yaw()
			local forward = minetest.yaw_to_dir(yaw)
			local right = { x = math.cos(yaw), y = 0, z = math.sin(yaw) }
			for i, collider in ipairs(self.leg_colliders) do
				local offset = hexapod_v3.leg_relay_offsets[i]
				local world_offset = vector.add(
					vector.multiply(right, offset.x),
					vector.multiply(forward, offset.z))
				world_offset.y = -hexapod_v3.leg_drop / 2
				collider:set_pos(vector.add(pod_pos, world_offset))
			end
		end

		-- Les roues suivent le hexapod en permanence (meme non pilote), et ne
		-- tournent que lorsqu'il se deplace effectivement (signed_speed ~= 0).
		hexapod_v3.update_wheels(self, dtime, signed_speed)
		hexapod_v3.update_engine_sound(self, signed_speed)
		hexapod_v3.update_turn_sound(self, turning)
		hexapod_v3.update_legs(self, dtime, signed_speed ~= 0 or turning)
	end,
})

minetest.register_craftitem("hexapod_v3:pod", {
	description = "Hexapod (camera exterieure a la troisieme personne)",
	inventory_image = "hexapod_v3_node.png",
	on_place = function(itemstack, placer, pointed_thing)
		if pointed_thing.type ~= "node" then
			return itemstack
		end

		-- +0.5 pose le corps au ras du sol ; +leg_drop remonte en plus le
		-- corps de la longueur des pattes, pour qu'elles ne s'enfoncent pas
		-- dans le terrain (elles pendent sous le corps, voir hexapod_v3.spawn_leg).
		local pos = vector.add(pointed_thing.above, { x = 0, y = 0.5 + hexapod_v3.leg_drop, z = 0 })
		minetest.add_entity(pos, "hexapod_v3:pod")

		if not minetest.settings:get_bool("creative_mode") then
			itemstack:take_item()
		end
		return itemstack
	end,
})

minetest.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	for pod in pairs(hexapod_v3.pods) do
		if pod.driver == player then
			pod.driver = nil
			if pod.camera_rig then
				pod.camera_rig:remove()
				pod.camera_rig = nil
			end
		end
	end
	hexapod_v3.saved_physics[name] = nil
end)
