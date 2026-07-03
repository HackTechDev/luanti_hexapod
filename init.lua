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
hexapod_v3.tail_count = 5
hexapod_v3.tail_size = 1  -- taille visuelle de chaque segment, en noeuds

-- Pattes (gauche/droite), une paire par segment "hanche" du train, en
-- partant de celui immediatement derriere la tete. Chaine "en L" : corps ->
-- hanche -> femur (horizontal, s'eloigne du corps) -> genou -> tibia
-- (vertical, descend jusqu'au sol). Chaque piece est un node de la meme
-- taille que ceux du corps (`hexapod_v3.tail_size`).
hexapod_v3.leg_pair_count = 3       -- un hexapod a 6 pattes, donc 3 paires
hexapod_v3.leg_pair_spacing = 2     -- ecart (en segments du train) entre deux hanches -> 1 segment vide entre deux paires de pattes
hexapod_v3.leg_segment_height = 2  -- nombre de noeuds du femur (horizontal) et du tibia (vertical)

-- Distance verticale entre le centre du corps et le point le plus bas des
-- pattes, utilisee pour poser le hexapod assez haut pour que ses pattes ne
-- s'enfoncent pas dans le sol (voir le `on_place` de l'item plus bas).
-- Avec la chaine "en L" (cf. `hexapod_v3.spawn_leg`), le premier node du
-- femur est colle directement sous la hanche (1 cran), puis le tibia
-- descend de `leg_segment_height` crans supplementaires sous le genou,
-- plus une demi-taille de node pour atteindre la face basse du dernier
-- node de tibia.
hexapod_v3.leg_drop = hexapod_v3.tail_size * (1.5 + hexapod_v3.leg_segment_height)

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
-- Meme taille que les nodes du corps (`hexapod_v3.tail_size`). Statique
-- comme le train : un seul `set_attach` suffit.
function hexapod_v3.spawn_leg_part(entity_name, parent_object, parent_pos, offset)
	local part = minetest.add_entity(parent_pos, entity_name)
	part:set_attach(parent_object, "",
		{ x = offset.x * 10, y = offset.y * 10, z = offset.z * 10 },
		{ x = 0, y = 0, z = 0 })
	return part
end

-- Construit une patte complete "en L" (hanche -> femur horizontal -> genou
-- -> tibia vertical), suspendue sous le flanc (`side` = 1 pour droite, -1
-- pour gauche) du segment "hanche" qui sert de parent a toutes les pieces.
-- Chaque piece est un node de la meme taille que le corps
-- (`hexapod_v3.tail_size`). Les deux nodes de jointure -- la **hanche**
-- (corps<->femur) et le **genou** (femur<->tibia) -- utilisent une
-- entite/texture distincte (`hexapod_v3:leg_joint`) de celle des segments
-- de femur/tibia (`hexapod_v3:leg_part`, texture du corps).
--
-- Forme de la patte (side = 1, vue de profil, x vers la droite = s'eloigne
-- du corps, y vers le bas) :
--   y=0    [Hanche]
--   y=-s   [Femur][Femur]...[Genou]
--   y=-2s..                      [Tibia]
--   ...                          [Tibia]
-- Le premier node du femur est colle directement sous la hanche (meme
-- `x`, un cran plus bas) ; le femur continue ensuite a l'horizontale
-- (`x` avance, `y` fixe) jusqu'au genou. Le tibia repart de la a la
-- verticale, sous le genou (`x` fixe, `y` descend). Chaque transition ne
-- change qu'un seul axe a la fois, pour que les nodes restent colles face
-- contre face (un decalage simultane en `x` et en `y` laisserait un vide
-- de la taille d'un node entre deux nodes, qui ne se toucheraient plus
-- que par une arete).
function hexapod_v3.spawn_leg(self, hip_object, side)
	local s = hexapod_v3.tail_size
	local hip_pos = hip_object:get_pos()

	local x = side * s  -- s/2 (flanc de la hanche) + s/2 (flanc de la piece)
	local y = 0
	local hanche = hexapod_v3.spawn_leg_part("hexapod_v3:leg_joint", hip_object, hip_pos, { x = x, y = y, z = 0 })
	table.insert(self.leg_parts, hanche)

	-- Premier node de femur : colle directement sous la hanche (meme x).
	y = y - s
	local first_femur = hexapod_v3.spawn_leg_part("hexapod_v3:leg_part", hip_object, hip_pos, { x = x, y = y, z = 0 })
	table.insert(self.leg_parts, first_femur)

	-- Nodes de femur suivants : a l'horizontale, a la meme hauteur.
	for _ = 2, hexapod_v3.leg_segment_height do
		x = x + side * s
		local part = hexapod_v3.spawn_leg_part("hexapod_v3:leg_part", hip_object, hip_pos, { x = x, y = y, z = 0 })
		table.insert(self.leg_parts, part)
	end

	x = x + side * s
	local genou = hexapod_v3.spawn_leg_part("hexapod_v3:leg_joint", hip_object, hip_pos, { x = x, y = y, z = 0 })
	table.insert(self.leg_parts, genou)

	for _ = 1, hexapod_v3.leg_segment_height do
		y = y - s
		local part = hexapod_v3.spawn_leg_part("hexapod_v3:leg_part", hip_object, hip_pos, { x = x, y = y, z = 0 })
		table.insert(self.leg_parts, part)
	end
end

-- Construit les `hexapod_v3.leg_pair_count` paires de pattes (gauche et
-- droite, symetriques), une paire tous les `hexapod_v3.leg_pair_spacing`
-- segments du train, en partant de celui immediatement derriere la tete
-- (hexapod_v3.tail_segments[1], [1 + spacing], [1 + 2*spacing], ...).
-- Avec les valeurs par defaut (spacing = 2), un segment du train reste
-- donc libre entre deux paires de pattes plutot que d'etre colle a la
-- precedente.
function hexapod_v3.spawn_legs(self)
	self.leg_parts = {}
	for i = 1, hexapod_v3.leg_pair_count do
		local segment_index = 1 + (i - 1) * hexapod_v3.leg_pair_spacing
		local hip_object = self.tail_segments[segment_index]
		if not hip_object then
			break
		end
		hexapod_v3.spawn_leg(self, hip_object, 1)   -- droite
		hexapod_v3.spawn_leg(self, hip_object, -1)  -- gauche
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
	self.object:set_velocity({ x = 0, y = 0, z = 0 })
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
		collisionbox = { -0.5, -0.5, -0.5, 0.5, 0.5, 0.5 },
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

	on_activate = function(self)
		self.object:set_acceleration({ x = 0, y = 0, z = 0 })
		hexapod_v3.pods[self] = true

		local pos = self.object:get_pos()
		self.wheel_right = minetest.add_entity(pos, "hexapod_v3:wheel")  -- roue droite
		self.wheel_left = minetest.add_entity(pos, "hexapod_v3:wheel")   -- roue gauche
		hexapod_v3.attach_wheel(self.wheel_right, self.object, 1)
		hexapod_v3.attach_wheel(self.wheel_left, self.object, -1)

		hexapod_v3.spawn_tail(self)  -- train arriere
		hexapod_v3.spawn_legs(self)
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

			local dir = minetest.yaw_to_dir(yaw)
			local vel = { x = 0, y = 0, z = 0 }
			if ctrl.up then
				vel = vector.multiply(dir, hexapod_v3.forward_speed)
				signed_speed = hexapod_v3.forward_speed
			elseif ctrl.down then
				vel = vector.multiply(dir, -hexapod_v3.forward_speed)
				signed_speed = -hexapod_v3.forward_speed
			end
			self.object:set_velocity(vel)

			hexapod_v3.update_camera(self, driver)
		else
			self.driver = nil
		end

		-- Les roues suivent le hexapod en permanence (meme non pilote), et ne
		-- tournent que lorsqu'il se deplace effectivement (signed_speed ~= 0).
		hexapod_v3.update_wheels(self, dtime, signed_speed)
		hexapod_v3.update_engine_sound(self, signed_speed)
		hexapod_v3.update_turn_sound(self, turning)
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
