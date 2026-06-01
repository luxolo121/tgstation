// Iris perception: token-gated read-only Topic endpoints for the admin-challenge agent.
// Token loaded from config/iris.txt (single line, no trailing whitespace).
// TODO: future endpoints — ?iris_players, ?iris_area
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

	// Dispatch — only ?iris_world for now.
	if("iris_world" in input)
		return iris_world_snapshot(input)

	return json_encode(list("error" = "unknown_endpoint"))

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
