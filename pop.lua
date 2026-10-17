_addon.name = 'pop'
_addon.author = 'Mithrael@Quezacoatl'
_addon.version = '0.0.1'
_addon.command = 'pop'

require('logger')
local config = require('config')
local packets = require('packets')

local defaults = {
    -- Seconds between widescan attempts while the target has not been found.
    delay = 5,
    -- Seconds to wait for the server to finish sending a widescan list before giving up.
    timeout = 5,
    -- WAV file in the addon's sounds/ directory to play when a mob is tracked. Empty disables.
    sound = 'found.wav',
    -- When true, no sound is played. Set with //pop mute and //pop unmute.
    muted = false,
    -- When true, a found mob is widescan-tracked, targeted and its status
    -- reported. When false, the addon only scans and announces the find.
    track = true,
    -- When true, once a found mob is gone (dead or despawned) the whole search
    -- starts over for the same list of mobs. When false, the search is done.
    loop = false,
}
local settings = config.load(defaults)

local function play_found_sound()
    if settings.muted or settings.sound == '' then
        return
    end
    local path = windower.addon_path .. 'sounds/' .. settings.sound
    if windower.file_exists(path) then
        windower.play_sound(path)
    else
        warning('Sound file not found: %s':format(path))
    end
end

local help_text = [[pop usage:
    //pop 0x<index>   - Widescan for the mob with the given hex index and track it, e.g. //pop 0x00f8
    //pop <name>      - Widescan for the mob by name and track it, e.g. //pop "Valkurm Emperor"
                        Wildcards are supported, e.g. //pop valkurm* or //pop *emperor
                        Quote names containing spaces.
    //pop <a> <b> ... - Track the first of several mobs found, checked in the order given,
                        e.g. //pop "Valkurm Emperor" 0x00f8 *hare
                        Scanning repeats every <delay> seconds until a mob is found or stopped.
    //pop delay [n]   - Show or set the seconds between scans.
    //pop timeout [n] - Show or set the seconds to wait for a scan to complete.
    //pop track [on|off] - Show or set whether a found mob is tracked, targeted and
                        monitored (on), or only announced (off).
    //pop loop [on|off] - Show or set whether, after a found mob dies or despawns,
                        the search restarts for the same list (on) or finishes (off).
    //pop mute        - Silence the sound played when a mob is found.
    //pop unmute      - Restore the sound played when a mob is found.
    //pop stop        - Stop searching/tracking.
    //pop help        - Show this text.

Once a mob is tracked, its distance, HP and claim status are reported whenever they
change, and it is targeted (when in range) every <delay> seconds until //pop stop.]]

-- Mobs reported by the server during the current widescan (incoming 0x0F4).
local scan_list = {}
-- Coroutine running the search-and-track routine for the current request.
local tracker
-- The signal the tracker last yielded ('scan' or 'retry'), used to ignore
-- widescan lists that arrive while it is not waiting for one.
local awaiting
-- Incremented per scan request so stale timeouts can be ignored.
local scan_serial = 0
-- Index of the mob currently being tracked, and its last position reported
-- by the widescan track packet (incoming 0x0F5), which works at any range.
local tracked_index
local tracked_pos

--------------------------------------------------------------------------------
-- Search and track routine (runs inside a coroutine)
--
-- The routine yields one of two signals:
--   'scan'  - a widescan was requested; resume when the result list is complete
--   'retry' - wait settings.delay, then resume (rescan, or re-check the tracked mob)
-- It is resumed with 'results' when the list arrived, or 'timeout' if it did not.
--------------------------------------------------------------------------------

-- A query is either {index = <number>} or {name = <lowercase wildcard pattern>}.
local function describe(query)
    if query.index then
        return '0x%04X':format(query.index)
    end
    return query.name
end

local function matches(query, mob, name)
    if query.index then
        return mob.Index == query.index
    end
    return windower.wc_match(name:lower(), query.name)
end

-- Ask the server for a fresh widescan. If we are already tracking something,
-- stop tracking first so the server will accept a new scan request.
local function request_scan()
    if windower.ffxi.wide_scan_get_tracking_info() then
        windower.ffxi.wide_scan_stop_tracking()
    end
    scan_serial = scan_serial + 1
    packets.inject(packets.new('outgoing', 0x0F4, {['Flags'] = 1}))
    return scan_serial
end

local function find_matches(query)
    local mob_list = windower.ffxi.get_mob_list()
    local found = {}
    for _, mob in ipairs(scan_list) do
        local name = mob_list[mob.Index] or mob.Name or '?'
        if matches(query, mob, name) then
            found[#found + 1] = {Index = mob.Index, Name = name}
        end
    end
    return found
end

local function describe_all(queries)
    local parts = {}
    for i, query in ipairs(queries) do
        parts[i] = describe(query)
    end
    return table.concat(parts, ', ')
end

-- Check each query, in order, against the current scan results. Returns the
-- tracked mob, or nil plus `true` when the search is over anyway (ambiguous).
local function track_first_match(queries)
    for _, query in ipairs(queries) do
        local found = find_matches(query)

        if #found == 1 then
            if settings.track then
                log('Tracking: %s [0x%04X]':format(found[1].Name, found[1].Index))
                tracked_index = found[1].Index
                tracked_pos = nil
                windower.ffxi.wide_scan_track_index(found[1].Index)
            else
                log('Found: %s [0x%04X]':format(found[1].Name, found[1].Index))
            end
            play_found_sound()
            return found[1]
        elseif #found > 1 then
            log('Multiple matches for %s; retry with an index:':format(describe(query)))
            table.sort(found, function(a, b)
                return a.Index < b.Index
            end)
            for _, mob in ipairs(found) do
                log('- %-16s [0x%04X]':format(mob.Name, mob.Index))
            end
            return nil, true
        end
    end
    return nil, false
end

--------------------------------------------------------------------------------
-- Tracked mob monitoring
--------------------------------------------------------------------------------

-- Whether the mob's entity reports it dead. The client keeps stale data for
-- unloaded entities, so a dead reading is only trusted while the entity is
-- loaded or once this monitor has seen the mob alive.
local function is_dead(mob, seen_alive)
    local dead = mob.hpp == 0 or mob.status == 2 or mob.status == 3
    return dead and (mob.valid_target or seen_alive) or false
end

-- Distance in yalms from the player to the tracked mob. Prefers the position
-- from the widescan track packet, which the server sends at any range; falls
-- back to the client entity when loaded.
local function distance_to(mob)
    local me = windower.ffxi.get_mob_by_target('me')
    if me and tracked_pos then
        local dx, dy, dz = tracked_pos.x - me.x, tracked_pos.y - me.y, tracked_pos.z - me.z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    if mob and mob.valid_target then
        return math.sqrt(mob.distance)
    end
    return nil
end

local function claim_text(mob)
    if mob.claim_id == 0 then
        return 'Unclaimed'
    end
    local me = windower.ffxi.get_player()
    if me and mob.claim_id == me.id then
        return 'Claimed by you'
    end
    local claimer = windower.ffxi.get_mob_by_id(mob.claim_id)
    return 'Claimed by %s':format(claimer and claimer.name or 'ID %d':format(mob.claim_id))
end

-- One-line status for the tracked mob. Only changes in this string are logged.
local function status_line(index, name, seen_alive)
    local mob = windower.ffxi.get_mob_by_index(index)
    local distance = distance_to(mob)
    local parts = {}

    parts[#parts + 1] = distance and '%d yalms':format(distance + 0.5) or 'distance unknown'

    if mob and is_dead(mob, seen_alive) then
        parts[#parts + 1] = 'HP 0% (dead)'
    elseif mob and mob.valid_target then
        parts[#parts + 1] = 'HP %d%%':format(mob.hpp)
        parts[#parts + 1] = claim_text(mob)
    else
        parts[#parts + 1] = 'out of range'
    end

    return '%s: %s':format(name, table.concat(parts, ' | '))
end

-- Make the client target the mob by injecting the Lock Target packet the
-- server would send. Only possible while the entity is loaded client-side.
local function target_mob(index)
    local mob = windower.ffxi.get_mob_by_index(index)
    if not mob or not mob.valid_target or is_dead(mob) then
        return
    end
    local current = windower.ffxi.get_mob_by_target('t')
    if current and current.index == index then
        return
    end
    local me = windower.ffxi.get_mob_by_target('me')
    if not me then
        return
    end
    packets.inject(packets.new('incoming', 0x058, {
        ['Player'] = me.id,
        ['Target'] = mob.id,
        ['Player Index'] = me.index,
    }))
end

-- Runs inside the tracker coroutine after a mob has been tracked: report
-- changes and (re)target it every settings.delay seconds until it dies or
-- tracking is stopped.
local function end_tracking(reason)
    log(reason)
    tracked_index = nil
    tracked_pos = nil
    windower.ffxi.wide_scan_stop_tracking()
end

-- Returns when the mob dies or the client drops the widescan track (the mob
-- died or despawned out of entity range, or the track was otherwise lost).
local function monitor(mob)
    local last_line
    local seen_alive = false
    -- The host may not report the track until the server acknowledges it, so
    -- a missing track only counts as "ended" once it has been seen active.
    local seen_tracking = false

    while true do
        local entity = windower.ffxi.get_mob_by_index(mob.Index)
        if entity and entity.valid_target and entity.hpp > 0 then
            seen_alive = true
        end

        local line = status_line(mob.Index, mob.Name, seen_alive)
        if line ~= last_line then
            log(line)
            last_line = line
        end

        if entity and is_dead(entity, seen_alive) then
            end_tracking('%s has died; tracking stopped.':format(mob.Name))
            return
        end

        if windower.ffxi.wide_scan_get_tracking_info() then
            seen_tracking = true
        elseif seen_tracking then
            end_tracking('Lost track of %s (dead, despawned or out of range).':format(mob.Name))
            return
        end

        target_mob(mob.Index)
        coroutine.yield('retry')
    end
end

local function in_scan(index)
    for _, mob in ipairs(scan_list) do
        if mob.Index == index then
            return true
        end
    end
    return false
end

-- Track-off counterpart of monitor: rescan every settings.delay seconds and
-- return once the mob has left the widescan results (dead or despawned).
-- Returns false if a scan timed out, so the caller stops.
local function watch(mob)
    log('Waiting for %s to die or despawn.':format(mob.Name))
    while true do
        coroutine.yield('retry')
        request_scan()
        if coroutine.yield('scan') == 'timeout' then
            error('Scan timed out after %g seconds.':format(settings.timeout))
            return false
        end
        if not in_scan(mob.Index) then
            log('%s is gone (dead or despawned).':format(mob.Name))
            return true
        end
    end
end

-- `queries` is a priority-ordered list; each scan is checked against every
-- query before waiting and scanning again. Once a found mob is gone (its track
-- ends, or it leaves the scan results), the search either finishes or, with
-- settings.loop, starts over for the same list.
local function search_and_track(queries)
    log('Searching for %s...':format(describe_all(queries)))
    local announced_wait = false

    while true do
        request_scan()
        local outcome = coroutine.yield('scan')

        if outcome == 'timeout' then
            error('Scan timed out after %g seconds.':format(settings.timeout))
            return
        end

        local mob, done = track_first_match(queries)
        if mob then
            local gone
            if settings.track then
                monitor(mob)
                gone = true
            else
                gone = watch(mob)
            end
            if not gone or not settings.loop then
                return
            end
            log('Looping: searching for %s again in %gs.':format(describe_all(queries), settings.delay))
            announced_wait = false
        elseif done then
            return
        elseif not announced_wait then
            local what = #queries == 1 and describe(queries[1]) or 'None of the targets'
            log('%s not up yet; rescanning every %gs until found. //pop stop to cancel.':format(what, settings.delay))
            announced_wait = true
        end

        coroutine.yield('retry')
    end
end

--------------------------------------------------------------------------------
-- Coroutine driver
--------------------------------------------------------------------------------

-- Resume the current tracker and act on what it yields. `co` identifies the
-- tracker the caller intends to resume so stale timers resume nothing.
local function resume_tracker(co, ...)
    if not co or co ~= tracker or coroutine.status(co) ~= 'suspended' then
        return
    end

    local ok, signal = coroutine.resume(co, ...)
    if not ok then
        tracker = nil
        error(signal)
        return
    end
    awaiting = signal

    if coroutine.status(co) == 'dead' then
        tracker = nil
    elseif signal == 'scan' then
        local serial = scan_serial
        coroutine.schedule(function()
            if serial == scan_serial then
                resume_tracker(co, 'timeout')
            end
        end, settings.timeout)
    elseif signal == 'retry' then
        coroutine.schedule(function()
            resume_tracker(co)
        end, settings.delay)
    end
end

local function start_tracking(queries)
    if tracker then
        log('Replacing the search in progress.')
    end
    tracked_index = nil
    tracked_pos = nil
    tracker = coroutine.create(search_and_track)
    resume_tracker(tracker, queries)
end

local function stop_tracking()
    tracker = nil
    tracked_index = nil
    tracked_pos = nil
    windower.ffxi.wide_scan_stop_tracking()
end

--------------------------------------------------------------------------------
-- Packet handling
--------------------------------------------------------------------------------

local scan_marks = {
    -- Start of a widescan list: reset the accumulator.
    [1] = function()
        scan_list = {}
    end,
    -- End of a widescan list: hand the results to the waiting routine.
    [2] = function()
        -- Only a tracker waiting on a scan cares; a manual widescan while
        -- monitoring must not resume it early and double up its timers.
        if awaiting ~= 'scan' then
            return
        end
        -- Bump the serial so the pending timeout for this scan is ignored.
        scan_serial = scan_serial + 1
        resume_tracker(tracker, 'results')
    end,
}

windower.register_event('incoming chunk', function(id, data, modified, injected, blocked)
    if injected or not tracker then
        return
    end

    if id == 0x0F4 then
        local mob = packets.parse('incoming', data)
        -- Type 0 is "Other" (not a friendly or enemy), e.g. a player; skip it.
        if mob.Type ~= 0 then
            scan_list[#scan_list + 1] = mob
        end
    elseif id == 0x0F5 then
        local update = packets.parse('incoming', data)
        if update.Status == 1 and update.Index == tracked_index then
            -- Packet order is X, Z, Y with Z the height; Windower's mob
            -- tables use x, y horizontal and z vertical.
            tracked_pos = {x = update.X, y = update.Y, z = update.Z}
        end
    elseif id == 0x0F6 then
        local mark = packets.parse('incoming', data)
        local handler = scan_marks[mark.Type]
        if handler then
            handler()
        end
    end
end)

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function parse_index(arg)
    if not arg then
        return nil
    end
    -- The 0x prefix is required so hex-looking names (e.g. "beef") are not mistaken for indices.
    local hex = arg:lower():match('^0x(%x+)$')
    local index = hex and tonumber(hex, 16)
    if not index or index <= 0 or index > 0xFFFF then
        return nil
    end
    return index
end

local bool_words = {
    on = true, ['true'] = true, yes = true, ['1'] = true,
    off = false, ['false'] = false, no = false, ['0'] = false,
}

-- Returns true/false for a recognised word, nil otherwise.
local function parse_bool(word)
    return bool_words[word:lower()]
end

-- Boolean settings adjustable from the command line: key -> description.
local bool_settings = {
    track = 'Tracking after a find',
    loop = 'Looping after a track ends',
}

-- Show the setting, or set and save it when a value is given.
local function show_or_set_bool(key, value)
    if value then
        local flag = parse_bool(value)
        if flag == nil then
            error('%s expects on/off (or true/false, yes/no, 1/0).':format(key))
            return
        end
        settings[key] = flag
        config.save(settings)
    end
    log('%s: %s':format(bool_settings[key], settings[key] and 'on' or 'off'))
end

-- Numeric settings adjustable from the command line: key -> description.
local numeric_settings = {
    delay = 'Delay between scans',
    timeout = 'Scan timeout',
}

-- Show the setting, or set and save it when a value is given.
local function show_or_set(key, value)
    if value then
        local number = tonumber(value)
        if not number or number <= 0 then
            error('%s must be a positive number of seconds.':format(numeric_settings[key]))
            return
        end
        settings[key] = number
        config.save(settings)
    end
    log('%s: %gs':format(numeric_settings[key], settings[key]))
end

windower.register_event('addon command', function(...)
    local args = {...}
    local cmd = args[1] and args[1]:lower() or 'help'

    if cmd == 'help' then
        print(help_text)
    elseif cmd == 'stop' or cmd == 'end' then
        stop_tracking()
        log('Stopped.')
    elseif numeric_settings[cmd] then
        show_or_set(cmd, args[2])
    elseif bool_settings[cmd] then
        show_or_set_bool(cmd, args[2])
    elseif cmd == 'mute' or cmd == 'unmute' then
        settings.muted = cmd == 'mute'
        config.save(settings)
        log(settings.muted and 'Sound muted.' or 'Sound unmuted.')
    else
        -- Each remaining argument is a target, in priority order. An argument with
        -- the 0x prefix is an index; anything else is a (wildcard) name. Names
        -- with spaces must be quoted so the command parser keeps them together.
        local queries = {}
        for i, arg in ipairs(args) do
            local index = parse_index(arg)
            queries[i] = index and {index = index} or {name = arg:lower()}
        end
        start_tracking(queries)
    end
end)

windower.register_event('unload', function()
    tracker = nil
end)
