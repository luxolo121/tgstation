// Iris perception: token-gated read-only Topic endpoints for the admin-challenge agent.
// Token loaded from config/iris.txt (single line, no trailing whitespace).
// Entry point is iris_topic(query, addr, master), called from /world/Topic in code/game/world.dm.

GLOBAL_VAR_INIT(iris_token_cache_loaded, FALSE)
GLOBAL_VAR_INIT(iris_token_cache, "")

GLOBAL_VAR_INIT(iris_areas_index_round, null)
GLOBAL_LIST_EMPTY(iris_areas_index_cache)

/proc/iris_get_token()
	if(!GLOB.iris_token_cache_loaded)
		GLOB.iris_token_cache_loaded = TRUE
		if(fexists("config/iris.txt"))
			var/raw = trim(file2text("config/iris.txt"))
			GLOB.iris_token_cache = raw
	return GLOB.iris_token_cache

/proc/iris_unauthorized()
	return json_encode(list("error" = "unauthorized"))

/proc/iris_topic(query, addr, master)
	var/list/input = params2list(query)
	var/expected = iris_get_token()
	if(!expected || input["token"] != expected)
		return iris_unauthorized()

	if("iris_world" in input)
		return iris_world_snapshot(input)
	if("iris_players" in input)
		return iris_players_endpoint(input)
	if("iris_player" in input)
		return iris_player_endpoint(input)
	if("iris_area" in input)
		return iris_area_endpoint(input)
	if("iris_tiles" in input)
		return iris_tiles_endpoint(input)
	if("iris_areas_index" in input)
		return iris_areas_index_endpoint(input)
	if("iris_exec_lua" in input)
		return iris_exec_lua_endpoint(input, addr)

	return json_encode(list("error" = "unknown_endpoint"))

// --- action: exec lua --------------------------------------------------------
// Token-gated runtime scripting via the dreamluau bridge. Mirrors the admin
// "Run Lua" verb but reachable from anywhere Topic can reach us. Returns the
// raw load_script result as JSON (status, return/message, name, slept).

GLOBAL_DATUM(iris_lua_state, /datum/lua_state)
GLOBAL_VAR_INIT(iris_exec_logged, FALSE)

/proc/iris_get_lua_state()
#ifdef DISABLE_DREAMLUAU
	return null
#else
	if(!SSlua || !SSlua.initialized)
		return null
	if(!GLOB.iris_lua_state)
		GLOB.iris_lua_state = new /datum/lua_state("iris_perception")
		SSlua.states += GLOB.iris_lua_state
	return GLOB.iris_lua_state
#endif

/proc/iris_exec_audit(addr, script, list/result)
	// Always write one JSONL line per call to data/logs/<round>/iris_exec.log.json.
	// Using rustg_file_append because the log subsystem may not have a category for us.
	var/list/entry = list(
		"ts" = ISOtime(),
		"addr" = addr,
		"script_len" = length(script),
		"script_head" = copytext(script, 1, 200),
		"status" = result?["status"],
		"return_summary" = result?["status"] == "error" \
			? copytext("[result["message"]]", 1, 240) \
			: copytext("[result["return_values"]]", 1, 240)
	)
	var/path = "[GLOB.log_directory]/iris_exec.log.json"
	rustg_file_append("[json_encode(entry)]\n", path)

/proc/iris_exec_lua_endpoint(list/input, addr)
	var/script = input["script"]
	if(!script)
		return iris_envelope("iris_exec_lua", "standard", null, error = "missing 'script' query parameter")
	var/datum/lua_state/state = iris_get_lua_state()
	if(!state)
		return iris_envelope("iris_exec_lua", "standard", null, error = "lua state unavailable (DISABLE_DREAMLUAU or SSlua not initialized)")

	var/list/result = state.load_script(script)
	// `chunk` echoes the source back — drop to keep responses small.
	if(islist(result))
		result -= "chunk"

	iris_exec_audit(addr, script, result)

	return iris_envelope("iris_exec_lua", "standard", result)

/proc/iris_slot_name(slot_id)
	switch(slot_id)
		if(ITEM_SLOT_BACK)        return "back"
		if(ITEM_SLOT_NECK)        return "neck"
		if(ITEM_SLOT_HEAD)        return "head"
		if(ITEM_SLOT_MASK)        return "mask"
		if(ITEM_SLOT_EYES)        return "eyes"
		if(ITEM_SLOT_EARS)        return "ears"
		if(ITEM_SLOT_OCLOTHING)   return "suit"
		if(ITEM_SLOT_ICLOTHING)   return "uniform"
		if(ITEM_SLOT_GLOVES)      return "gloves"
		if(ITEM_SLOT_FEET)        return "shoes"
		if(ITEM_SLOT_ID)          return "id"
		if(ITEM_SLOT_BELT)        return "belt"
		if(ITEM_SLOT_LPOCKET)     return "pocket_left"
		if(ITEM_SLOT_RPOCKET)     return "pocket_right"
		if(ITEM_SLOT_SUITSTORE)   return "suit_storage"
		if(ITEM_SLOT_HANDS)       return "hands"
		if(ITEM_SLOT_HANDCUFFED)  return "handcuffed"
		if(ITEM_SLOT_LEGCUFFED)   return "legcuffed"
		if(ITEM_SLOT_DEX_STORAGE) return "dex_storage"
	return "slot_[slot_id]"

// --- envelope + lod helpers --------------------------------------------------

/proc/iris_lod(list/input)
	var/raw = input?["lod"]
	switch(raw)
		if("brief", "standard", "detailed")
			return raw
	return "standard"

/proc/iris_envelope(endpoint, lod, data, error = null)
	return json_encode(list(
		"endpoint" = endpoint,
		"lod" = lod,
		"generated_at_ds" = world.time,
		"data" = data,
		"error" = error,
	))

/proc/iris_world_snapshot(list/input)
	var/lod = iris_lod(input)
	var/list/data = list()
	data["round_id"] = text2num(GLOB.round_id) || 0

	var/state_str = "lobby"
	if(SSticker)
		switch(SSticker.current_state)
			if(GAME_STATE_STARTUP, GAME_STATE_PREGAME)
				state_str = "lobby"
			if(GAME_STATE_SETTING_UP)
				state_str = "setting_up"
			if(GAME_STATE_PLAYING)
				state_str = "playing"
			if(GAME_STATE_FINISHED)
				state_str = "finished"
	data["phase"] = state_str

	var/round_start = SSticker ? SSticker.round_start_time : 0
	data["round_duration_ds"] = round_start ? (world.time - round_start) : 0

	data["players_total"] = length(GLOB.clients)
	data["players_alive"] = length(GLOB.alive_player_list)
	data["admins_online"] = length(GLOB.admins)

	var/seclvl = "unknown"
	if(SSsecurity_level && SSsecurity_level.initialized && SSsecurity_level.current_security_level)
		seclvl = SSsecurity_level.current_security_level.name
	data["security_level"] = seclvl

	var/list/shuttle_info = null
	if(SSshuttle && SSshuttle.emergency)
		shuttle_info = list(
			"mode" = SSshuttle.emergency.mode,
			"time_left_ds" = SSshuttle.emergency.timeLeft(1),
		)
	data["shuttle"] = shuttle_info

	data["comms_blackout"] = FALSE

	var/list/station_zs = list()
	if(SSmapping)
		for(var/z in SSmapping.levels_by_trait(ZTRAIT_STATION))
			station_zs += z
	data["station_z_levels"] = station_zs

	if(lod != "brief")
		var/list/sm_out = list()
		for(var/obj/machinery/power/supermatter_crystal/sm as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/power/supermatter_crystal))
			var/turf/ST = get_turf(sm)
			var/area/SA = get_area(sm)
			var/datum/gas_mixture/gm = sm.return_air()
			sm_out += list(list(
				"name" = sm.name,
				"x" = ST ? ST.x : null,
				"y" = ST ? ST.y : null,
				"z" = ST ? ST.z : null,
				"area_name" = SA ? SA.name : null,
				"integrity_percent" = round(sm.get_integrity_percent(), 0.1),
				"internal_energy" = sm.internal_energy,
				"temperature_k" = gm ? gm.return_temperature() : null,
				"delaminating" = (sm.final_countdown || sm.damage >= sm.explosion_point) ? TRUE : FALSE,
			))
		data["supermatter"] = sm_out

	return iris_envelope("iris_world", lod, data)

// --- shared payload helpers --------------------------------------------------

/// Build a description of one mob slot useful for ?iris_players / ?iris_player.
/// `lod` ∈ "brief" | "standard" | "detailed".
/proc/iris_mob_payload(client/C, lod)
	var/list/out = list()
	out["ckey"] = C ? C.ckey : null
	out["name"] = C ? C.key : null
	var/mob/M = C?.mob
	if(!M)
		out["alive"] = FALSE
		out["area_name"] = null
		return out

	out["name"] = M.name || C.key
	var/area/A = get_area(M)
	out["area_name"] = A ? A.name : null
	var/turf/T = get_turf(M)
	out["x"] = T ? T.x : null
	out["y"] = T ? T.y : null
	out["z"] = T ? T.z : null
	out["alive"] = isliving(M) && M.stat != DEAD

	var/role = "unknown"
	if(M.mind?.assigned_role?.title)
		role = M.mind.assigned_role.title
	else if(isobserver(M))
		role = "ghost"
	out["role"] = role

	if(lod == "brief")
		return out

	out["mob_type"] = "[M.type]"
	out["intent"] = null
	out["stat"] = "unknown"
	if(isliving(M))
		var/mob/living/L = M
		out["health"] = L.health
		out["max_health"] = L.maxHealth
		switch(L.stat)
			if(CONSCIOUS) out["stat"] = "conscious"
			if(SOFT_CRIT) out["stat"] = "soft_crit"
			if(UNCONSCIOUS) out["stat"] = "unconscious"
			if(HARD_CRIT) out["stat"] = "hard_crit"
			if(DEAD) out["stat"] = "dead"
		out["intent"] = L.combat_mode ? "harm" : "help"
		out["mob_size"] = L.mob_size
		out["on_fire"] = L.on_fire ? TRUE : FALSE
		out["in_crit"] = (L.stat == SOFT_CRIT || L.stat == HARD_CRIT)
	else
		out["health"] = null
		out["max_health"] = null
		out["mob_size"] = null
		out["on_fire"] = FALSE
		out["in_crit"] = FALSE

	var/obj/item/l_hand = M.get_item_for_held_index(1)
	var/obj/item/r_hand = M.get_item_for_held_index(2)
	out["held_left"] = l_hand ? l_hand.name : null
	out["held_right"] = r_hand ? r_hand.name : null

	// nearby_mob_count: living mobs around the mob, excluding self, radius 7.
	var/nearby = 0
	if(T)
		for(var/mob/living/other in oview(7, M))
			nearby++
	out["nearby_mob_count"] = nearby

	if(lod != "detailed")
		return out

	// --- detailed -----------------------------------------------------------
	var/list/equipped = list()
	for(var/obj/item/worn in M.get_equipped_items(INCLUDE_HELD|INCLUDE_POCKETS|INCLUDE_ABSTRACT))
		var/slot_id = iris_slot_name(M.get_slot_by_item(worn))
		equipped[slot_id] = list("name" = worn.name, "type" = "[worn.type]")
	out["equipped"] = equipped

	if(iscarbon(M))
		var/mob/living/carbon/cmob = M
		out["bleeding"] = cmob.is_bleeding() ? TRUE : FALSE
	else
		out["bleeding"] = FALSE
	if(isliving(M))
		var/mob/living/L = M
		out["blood_volume"] = L.blood_volume
		out["body_temperature"] = L.bodytemperature
		out["oxyloss"] = L.oxyloss
		out["toxloss"] = L.toxloss
		out["fireloss"] = L.fireloss
		out["bruteloss"] = L.bruteloss
	else
		out["blood_volume"] = null
		out["body_temperature"] = null
		out["oxyloss"] = null
		out["toxloss"] = null
		out["fireloss"] = null
		out["bruteloss"] = null

	var/list/antags = list()
	if(M.mind?.antag_datums)
		for(var/datum/antagonist/ag in M.mind.antag_datums)
			antags += ag.name
	out["antag_datums"] = antags

	// Radio frequency, if any.
	var/freq = null
	for(var/obj/item/radio/R in M.contents)
		freq = R.get_frequency()
		break
	if(isnull(freq))
		for(var/obj/item/radio/R in M.get_equipped_items(INCLUDE_HELD))
			freq = R.get_frequency()
			break
	out["comms_freq"] = freq

	return out

/proc/iris_players_endpoint(list/input)
	var/lod = iris_lod(input)
	var/list/data = list()
	for(var/client/C in GLOB.clients)
		if(!C)
			continue
		data += list(iris_mob_payload(C, lod))
	return iris_envelope("iris_players", lod, data)

/proc/iris_player_endpoint(list/input)
	var/lod = iris_lod(input)
	var/ckey_raw = input["ckey"]
	if(!ckey_raw)
		return iris_envelope("iris_player", lod, null, list("code" = "bad_request", "detail" = "missing ckey"))
	var/needle = ckey(ckey_raw)
	var/client/C = GLOB.directory[needle]
	if(!C)
		return iris_envelope("iris_player", lod, null, list("code" = "not_found", "ckey" = needle))

	var/list/data = iris_mob_payload(C, lod)
	var/mob/M = C.mob
	var/turf/T = get_turf(M)

	if(T)
		// tile_under
		var/area/A = get_area(T)
		data["tile_under"] = list(
			"turf_type" = "[T.type]",
			"area_name" = A ? A.name : null,
			"x" = T.x, "y" = T.y, "z" = T.z,
		)

		// surroundings: mobs within radius 7
		var/list/surr = list()
		for(var/mob/other in oview(7, M))
			var/turf/OT = get_turf(other)
			if(!OT)
				continue
			surr += list(list(
				"name" = other.name,
				"type" = "[other.type]",
				"distance" = get_dist(T, OT),
				"alive" = isliving(other) && other.stat != DEAD,
				"x" = OT.x - T.x,
				"y" = OT.y - T.y,
				"z" = OT.z - T.z,
			))
		data["surroundings"] = surr

		// nearby_items: notable atoms on tiles within radius 2.
		var/list/notable = list()
		var/list/boring_paths = typecacheof(list(
			/turf/open/floor,
			/turf/closed/wall,
			/obj/machinery/door/airlock,
			/obj/structure/girder,
			/obj/structure/lattice,
			/obj/structure/grille,
			/obj/structure/cable,
			/obj/effect/decal,
			/obj/effect/landmark,
		))
		for(var/turf/scan in range(2, T))
			for(var/atom/movable/AM in scan.contents)
				if(boring_paths[AM.type])
					continue
				if(istype(AM, /mob))
					continue
				if(istype(AM, /obj/effect/turf_decal))
					continue
				notable += list(list(
					"name" = AM.name,
					"type" = "[AM.type]",
					"x" = scan.x - T.x,
					"y" = scan.y - T.y,
					"z" = scan.z - T.z,
				))
				if(length(notable) >= 64)
					break
			if(length(notable) >= 64)
				break
		data["nearby_items"] = notable
	else
		data["tile_under"] = null
		data["surroundings"] = list()
		data["nearby_items"] = list()

	if(lod == "brief")
		// brief drill-downs skip the bulky context fields
		data -= "surroundings"
		data -= "nearby_items"

	return iris_envelope("iris_player", lod, data)

// --- area endpoint -----------------------------------------------------------

/// Returns assoc list with atmos summary for an area: avg temperature (K),
/// pressure (kPa), oxygen %, plasma %. Computed over open turfs in the area.
/// Returns null if the area has no open turfs.
/proc/iris_area_atmos(area/A)
	if(!istype(A))
		return null
	var/total = 0
	var/temp_sum = 0
	var/pressure_sum = 0
	var/o2_sum = 0
	var/plasma_sum = 0
	for(var/turf/open/T in A)
		var/datum/gas_mixture/gm = T.return_air()
		if(!gm)
			continue
		total++
		temp_sum += gm.return_temperature()
		pressure_sum += gm.return_pressure()
		var/moles = gm.total_moles()
		if(moles > 0 && gm.gases)
			if(gm.gases[GAS_O2])
				o2_sum += gm.gases[GAS_O2][MOLES] / moles
			if(gm.gases[GAS_PLASMA])
				plasma_sum += gm.gases[GAS_PLASMA][MOLES] / moles
	if(!total)
		return null
	return list(
		"avg_temp_k" = round(temp_sum / total, 0.01),
		"avg_pressure_kpa" = round(pressure_sum / total, 0.01),
		"oxygen_frac" = round(o2_sum / total, 0.001),
		"plasma_frac" = round(plasma_sum / total, 0.001),
		"sampled_turfs" = total,
	)

/proc/iris_area_endpoint(list/input)
	var/lod = iris_lod(input)
	var/needle_raw = input["name"]
	if(!needle_raw)
		return iris_envelope("iris_area", lod, null, list("code" = "bad_request", "detail" = "missing name"))
	var/needle = lowertext(needle_raw)

	var/list/matches = list()
	for(var/area/candidate as anything in GLOB.areas)
		if(!candidate.name)
			continue
		if(findtext(lowertext(candidate.name), needle))
			matches += candidate

	if(!length(matches))
		return iris_envelope("iris_area", lod, null, list("code" = "not_found", "name" = needle_raw))
	if(length(matches) > 1)
		var/list/match_names = list()
		for(var/area/candidate as anything in matches)
			match_names += candidate.name
		return iris_envelope("iris_area", lod, null, list("code" = "ambiguous", "matches" = match_names))

	var/area/A = matches[1]
	var/list/data = list()
	data["name"] = A.name
	data["type"] = "[A.type]"

	var/mob_count = 0
	var/player_count = 0
	var/ghost_count = 0
	var/npc_count = 0
	var/breach = FALSE
	for(var/turf/T in A)
		if(!breach && isspaceturf(T))
			breach = TRUE
		for(var/mob/M in T.contents)
			mob_count++
			if(isobserver(M))
				ghost_count++
			else if(M.client)
				player_count++
			else
				npc_count++
	data["mob_count"] = mob_count
	data["has_power"] = A.powered(AREA_USAGE_EQUIP) ? TRUE : FALSE
	data["breach"] = breach
	data["fire"] = A.fire ? TRUE : FALSE

	if(lod == "brief")
		return iris_envelope("iris_area", lod, data)

	data["player_count"] = player_count
	data["ghost_count"] = ghost_count
	data["npc_count"] = npc_count
	data["atmos_summary"] = iris_area_atmos(A)
	var/list/apc_info = null
	if(A.apc)
		apc_info = list(
			"cell_charge" = A.apc.cell ? A.apc.cell.charge : null,
			"cell_max" = A.apc.cell ? A.apc.cell.maxcharge : null,
			"operating" = A.apc.operating ? TRUE : FALSE,
		)
	data["apc_status"] = apc_info
	data["lights_on"] = A.lightswitch ? TRUE : FALSE

	if(lod != "detailed")
		return iris_envelope("iris_area", lod, data)

	// detailed: per-tile rundown of non-floor/non-wall atoms + adjacency
	var/list/items = list()
	var/list/boring_paths = typecacheof(list(
		/turf/open/floor,
		/turf/closed/wall,
		/obj/effect/turf_decal,
	))
	var/turf_count = 0
	var/list/adj_names = list()
	for(var/turf/T in A)
		turf_count++
		for(var/atom/movable/AM in T.contents)
			if(boring_paths[AM.type])
				continue
			items += list(list(
				"name" = AM.name,
				"type" = "[AM.type]",
				"x" = T.x, "y" = T.y, "z" = T.z,
			))
		// edge detection: check N/E/S/W neighbours only
		for(var/dir in list(NORTH, SOUTH, EAST, WEST))
			var/turf/N = get_step(T, dir)
			if(!N)
				continue
			var/area/NA = N.loc
			if(!istype(NA) || NA == A)
				continue
			adj_names[NA.name] = TRUE
	data["turf_count"] = turf_count
	data["items"] = items
	var/list/dep_list = list()
	for(var/n in adj_names)
		dep_list += n
	data["departures"] = dep_list

	return iris_envelope("iris_area", lod, data)

// --- tiles endpoint ----------------------------------------------------------

/proc/iris_tiles_endpoint(list/input)
	var/lod = iris_lod(input)
	var/center_raw = input["center"]
	var/radius_raw = input["radius"]
	if(!center_raw)
		return iris_envelope("iris_tiles", lod, null, list("code" = "bad_request", "detail" = "missing center"))
	var/list/parts = splittext(center_raw, ",")
	if(length(parts) < 3)
		return iris_envelope("iris_tiles", lod, null, list("code" = "bad_request", "detail" = "center must be x,y,z"))
	var/cx = text2num(parts[1])
	var/cy = text2num(parts[2])
	var/cz = text2num(parts[3])
	if(isnull(cx) || isnull(cy) || isnull(cz))
		return iris_envelope("iris_tiles", lod, null, list("code" = "bad_request", "detail" = "non-numeric center"))
	var/radius = text2num(radius_raw)
	if(isnull(radius))
		radius = 3
	radius = round(radius)
	if(radius < 0)
		radius = 0
	if(radius > 15)
		return iris_envelope("iris_tiles", lod, null, list("code" = "bad_request", "detail" = "radius > 15"))

	var/list/boring_paths = typecacheof(list(
		/obj/machinery/door/airlock,
		/obj/structure/girder,
		/obj/structure/lattice,
		/obj/effect/turf_decal,
	))

	var/list/tiles = list()
	for(var/dx in -radius to radius)
		for(var/dy in -radius to radius)
			var/turf/T = locate(cx + dx, cy + dy, cz)
			if(!T)
				continue
			var/list/tile = list()
			tile["x"] = T.x
			tile["y"] = T.y
			tile["z"] = T.z
			tile["turf_type"] = "[T.type]"
			var/area/A = get_area(T)
			tile["area_name"] = A ? A.name : null
			var/mc = 0
			var/fire = FALSE
			for(var/atom/movable/AM in T.contents)
				if(ismob(AM))
					mc++
				if(istype(AM, /obj/effect/hotspot))
					fire = TRUE
			tile["mob_count"] = mc
			tile["has_fire"] = fire
			tile["light_level"] = T.get_lumcount()
			if(lod != "brief")
				var/list/notable = list()
				for(var/atom/movable/AM in T.contents)
					if(boring_paths[AM.type])
						continue
					notable += "[AM.type]"
				tile["notable_items"] = notable
			if(lod == "detailed")
				var/list/full = list("[T.type]")
				for(var/atom/movable/AM in T.contents)
					full += "[AM.type]"
				tile["content_types"] = full
			tiles += list(tile)

	return iris_envelope("iris_tiles", lod, list(
		"center" = list("x" = cx, "y" = cy, "z" = cz),
		"radius" = radius,
		"tiles" = tiles,
	))

// --- areas_index endpoint ----------------------------------------------------

/proc/iris_areas_index_endpoint(list/input)
	var/lod = iris_lod(input)
	var/force = input["force"]
	var/round_key = text2num(GLOB.round_id) || 0
	if(!force && GLOB.iris_areas_index_round == round_key && length(GLOB.iris_areas_index_cache))
		var/list/cached = GLOB.iris_areas_index_cache.Copy()
		cached["cached"] = TRUE
		return iris_envelope("iris_areas_index", lod, cached)

	var/started = world.time
	var/list/result = list()

	for(var/area/A as anything in GLOB.areas)
		if(!istype(A))
			continue
		// Per-z bounding boxes: key = "[z]" -> list(z, xmin, ymin, xmax, ymax, turf_count)
		var/list/per_z = list()
		var/list/edge_turfs = list()
		for(var/turf/T in A)
			var/z_key = "[T.z]"
			var/list/box = per_z[z_key]
			if(!box)
				per_z[z_key] = list(T.z, T.x, T.y, T.x, T.y, 1)
			else
				if(T.x < box[2]) box[2] = T.x
				if(T.y < box[3]) box[3] = T.y
				if(T.x > box[4]) box[4] = T.x
				if(T.y > box[5]) box[5] = T.y
				box[6]++
			// Cheap sample: every third turf becomes a candidate for adjacency.
			if(!(box && box[6] % 3))
				edge_turfs += T
		var/list/boxes_out = list()
		var/total_turfs = 0
		for(var/k in per_z)
			var/list/box = per_z[k]
			total_turfs += box[6]
			boxes_out += list(list(
				"z" = box[1],
				"x_min" = box[2], "y_min" = box[3],
				"x_max" = box[4], "y_max" = box[5],
				"turf_count" = box[6],
			))

		var/list/adj_set = list()
		for(var/turf/T as anything in edge_turfs)
			for(var/dir in list(NORTH, SOUTH, EAST, WEST))
				var/turf/N = get_step(T, dir)
				if(!N)
					continue
				var/area/NA = N.loc
				if(!istype(NA) || NA == A || !NA.name)
					continue
				adj_set[NA.name] = TRUE
		var/list/adj_out = list()
		for(var/n in adj_set)
			adj_out += n

		result += list(list(
			"name" = A.name,
			"type" = "[A.type]",
			"turf_count" = total_turfs,
			"bounding_boxes" = boxes_out,
			"adjacency" = adj_out,
		))

	var/list/payload = list(
		"areas" = result,
		"generated_in_ds" = world.time - started,
	)
	GLOB.iris_areas_index_round = round_key
	GLOB.iris_areas_index_cache = payload.Copy()
	payload["cached"] = FALSE
	return iris_envelope("iris_areas_index", lod, payload)
