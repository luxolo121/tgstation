// Iris perception: token-gated read-only Topic endpoints for the admin-challenge agent.
// Token loaded from config/iris.txt (single line, no trailing whitespace).
// Entry point is iris_topic(query, addr, master), called from /world/Topic in code/game/world.dm.

GLOBAL_VAR_INIT(iris_token_cache_loaded, FALSE)
GLOBAL_VAR_INIT(iris_token_cache, "")

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

	return json_encode(list("error" = "unknown_endpoint"))

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
	var/list/out = list()
	out["round_id"] = text2num(GLOB.round_id) || 0

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
	out["phase"] = state_str

	var/round_start = SSticker ? SSticker.round_start_time : 0
	out["round_duration_ds"] = round_start ? (world.time - round_start) : 0

	out["players_total"] = length(GLOB.clients)
	out["players_alive"] = length(GLOB.alive_player_list)
	out["admins_online"] = length(GLOB.admins)

	var/seclvl = "unknown"
	if(SSsecurity_level && SSsecurity_level.initialized && SSsecurity_level.current_security_level)
		seclvl = SSsecurity_level.current_security_level.name
	out["security_level"] = seclvl

	var/list/shuttle_info = null
	if(SSshuttle && SSshuttle.emergency)
		shuttle_info = list(
			"mode" = SSshuttle.emergency.mode,
			"time_left_ds" = SSshuttle.emergency.timeLeft(1),
		)
	out["shuttle"] = shuttle_info

	out["comms_blackout"] = FALSE

	out["lod"] = input["lod"] || "standard"

	return json_encode(out)

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
		var/slot_id = "[M.get_slot_by_item(worn)]"
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
			/obj/structure/catwalk,
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
