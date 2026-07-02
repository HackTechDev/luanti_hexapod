-- hexapod_v3
-- Fournit une entite "hexapod_v3:pod" pilotable au clavier de facon continue
-- et fluide (Haut/Bas avancent ou reculent, Gauche/Droite pivotent), avec une
-- camera "troisieme personne" : le joueur n'est jamais colle sur le node, il
-- l'observe depuis l'exterieur. Sa camera reste en permanence centree sur le
-- node et le suit lors de ses deplacements, tout en gardant le controle
-- libre du regard (souris) ; en revanche il perd son propre deplacement
-- (ZQSD/fleches, saut, gravite) tant qu'il pilote le hexapod.
--
-- Note technique : la camera n'est PAS deplacee via des appels repetes a
-- `player:set_pos()`. La position d'un joueur est en partie predite en
-- local par le client puis corrigee par le serveur : des `set_pos()`
-- frequents produisent donc des a-coups visibles. On deplace a la place une
-- entite Lua invisible ("camera_rig"), correctement interpolee par le
-- client (comme n'importe quelle entite, y compris le hexapod lui-meme), et
-- on y attache le joueur : il herite ainsi d'un mouvement fluide.

hexapod_v3 = {}

-- Vitesses de deplacement du hexapod
hexapod_v3.forward_speed = 4          -- noeuds par seconde
hexapod_v3.turn_speed = math.rad(90)  -- radians par seconde

-- Distance a laquelle la camera est maintenue derriere le regard du joueur,
-- de sorte que le hexapod reste toujours exactement au centre de la vue,
-- quelle que soit la direction observee.
hexapod_v3.camera_distance = 6

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
-- vue du joueur qui le pilote. La rig est une entite Lua normale : le
-- client l'interpole en douceur entre deux mises a jour, ce qui rend le
-- suivi fluide.
function hexapod_v3.update_camera(self, player)
	local look_dir = player:get_look_dir()
	local pod_pos = self.object:get_pos()
	local target = hexapod_v3.compute_camera_pos(pod_pos, look_dir, player)
	self.camera_rig:set_pos(target)
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

minetest.register_entity("hexapod_v3:pod", {
	initial_properties = {
		visual = "cube",
		visual_size = { x = 1, y = 1, z = 1 },
		textures = {
			"hexapod_v3_node.png", "hexapod_v3_node.png",
			"hexapod_v3_node.png", "hexapod_v3_node.png",
			"hexapod_v3_node.png", "hexapod_v3_node.png",
		},
		collisionbox = { -0.5, -0.5, -0.5, 0.5, 0.5, 0.5 },
		physical = true,
		collide_with_objects = true,
		pointable = true,
		static_save = true,
	},

	driver = nil,
	camera_rig = nil,

	on_activate = function(self)
		self.object:set_acceleration({ x = 0, y = 0, z = 0 })
		hexapod_v3.pods[self] = true
	end,

	on_deactivate = function(self)
		if self.driver and self.driver:is_player() then
			hexapod_v3.stop_driving(self, self.driver)
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
		if not driver or not driver:is_player() then
			self.driver = nil
			return
		end

		local ctrl = driver:get_player_control()
		local yaw = self.object:get_yaw()

		if ctrl.left then
			yaw = yaw + hexapod_v3.turn_speed * dtime
		end
		if ctrl.right then
			yaw = yaw - hexapod_v3.turn_speed * dtime
		end
		self.object:set_yaw(yaw)

		local dir = minetest.yaw_to_dir(yaw)
		local vel = { x = 0, y = 0, z = 0 }
		if ctrl.up then
			vel = vector.multiply(dir, hexapod_v3.forward_speed)
		elseif ctrl.down then
			vel = vector.multiply(dir, -hexapod_v3.forward_speed)
		end
		self.object:set_velocity(vel)

		hexapod_v3.update_camera(self, driver)
	end,
})

minetest.register_craftitem("hexapod_v3:pod", {
	description = "Hexapod (camera exterieure a la troisieme personne)",
	inventory_image = "hexapod_v3_node.png",
	on_place = function(itemstack, placer, pointed_thing)
		if pointed_thing.type ~= "node" then
			return itemstack
		end

		local pos = vector.add(pointed_thing.above, { x = 0, y = 0.5, z = 0 })
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
