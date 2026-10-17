_addon.name = 'pop'
_addon.author = 'Mithrael@Quezacoatl'
_addon.version = '0.0.1'
_addon.command = 'pop'

require('logger')
local config = require('config')
local packets = require('packets')
local texts = require('texts')

local defaults = {
    -- Seconds between widescans while searching, and before a looped search restarts.
    scan_delay = 5,
    -- Seconds between checks of a found mob: the status report and targeting
    -- while tracked, and the rescans that wait for it to die or despawn.
    status_delay = 1,
    -- Seconds to wait for the server to finish sending a widescan list before giving up.
    timeout = 5,
    -- Sound played when a mob is found. `enabled` is set with //pop alert on|off;
    -- `file` is a WAV in the addon's sounds/ directory (empty disables).
    alert = {enabled = true, file = 'found.wav'},
    -- When true, a found mob is widescan-tracked and its distance, HP and
    -- claim status reported. When false, the addon only scans and announces
    -- the find, then rescans until the mob is gone.
    track = true,
    -- How the found mob is targeted (while in range) on each status check
    -- until it is gone. Independent of track.
    --   'off'     - never
    --   'packet'  - inject the client-side Lock Target packet (exact entity)
    --   'command' - send the game's /target <name> command
    target = 'off',
    -- When true, once a found mob is gone (dead or despawned) the whole search
    -- starts over for the same list of mobs. When false, the search is done.
    loop = true,
    -- Whether the on-screen timer is shown at all. Set with //pop timer on|off.
    show_timer = true,
    -- On-screen timer counting up from the start of a search until a mob is
    -- found. Drag it to move it; the position is saved. A negative position
    -- means "not placed yet": centered horizontally, a third of the way down.
    timer = {
        pos = {x = -1, y = -1},
        text = {size = 16, font = 'Consolas', red = 255, green = 255, blue = 255, alpha = 255},
        bg = {red = 0, green = 0, blue = 0, alpha = 128, visible = true},
        flags = {draggable = true, bold = true},
        padding = 4,
    },
    -- Behavior of the timer when an expected pop time was given
    -- (//pop <targets> <seconds>).
    countdown = {
        -- Beep played once per second during the alert window. `enabled` is
        -- set with //pop countdown on|off.
        sound = {enabled = true, file = 'countdown.wav'},
        -- Seconds remaining at which the warn and alert colors take over.
        thresholds = {warn = 15, alert = 5},
        -- Timer colors: warn, then alert, then late at or after the expected time.
        colors = {
            warn = {red = 255, green = 220, blue = 0, alpha = 255},
            alert = {red = 255, green = 140, blue = 0, alpha = 255},
            late = {red = 255, green = 60, blue = 60, alpha = 255},
        },
    },
    -- Color of the frozen timer after a find.
    found_color = {red = 80, green = 160, blue = 255, alpha = 255},
}
local settings = config.load(defaults)

--------------------------------------------------------------------------------
-- On-screen timer
--------------------------------------------------------------------------------

local timer_text = texts.new('${elapsed}', settings.timer, settings)
-- os.time() when the current search started; nil when the timer is hidden.
local timer_started
-- True while the timer is counting; false once frozen at the find time.
local timer_running = false
-- Last whole second rendered, to avoid rewriting the text every frame.
local timer_shown
-- Seconds until the pop is expected, if the user gave one; nil otherwise.
local timer_expected

-- Play a sound block of the form {enabled = bool, file = 'name.wav'}.
local function play_sound(sound)
    if not sound.enabled or not sound.file or sound.file == '' then
        return
    end
    local file = sound.file
    local path = windower.addon_path .. 'sounds/' .. file
    if windower.file_exists(path) then
        windower.play_sound(path)
    else
        warning('Sound file not found: %s':format(path))
    end
end

local function format_elapsed(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor(seconds % 3600 / 60)
    local s = seconds % 60
    if h > 0 then
        return '%d:%02d:%02d':format(h, m, s)
    end
    return '%02d:%02d':format(m, s)
end

-- Set the text color without touching the saved settings, so the configured
-- color survives a settings save made while the timer is recolored.
local timer_color
local function set_timer_color(color)
    if color == timer_color then
        return
    end
    timer_color = color
    windower.text.set_color(timer_text._name, color.alpha or settings.timer.text.alpha, color.red, color.green, color.blue)
end

-- Color for the running timer given seconds remaining (nil when no expectation):
-- the configured text color, then warn, alert, and late as the thresholds pass.
local function countdown_color(remaining)
    local c = settings.countdown
    if not remaining or remaining > c.thresholds.warn then
        return settings.timer.text
    elseif remaining > c.thresholds.alert then
        return c.colors.warn
    elseif remaining > 0 then
        return c.colors.alert
    end
    return c.colors.late
end

local function render_timer(seconds)
    timer_shown = seconds
    if timer_expected then
        timer_text.elapsed = '%s / %s':format(format_elapsed(seconds), format_elapsed(timer_expected))
    else
        timer_text.elapsed = format_elapsed(seconds)
    end
end

-- Place the timer centered horizontally, a third of the way down the screen,
-- unless the user has already dragged it somewhere (position saved).
local function place_timer()
    if settings.timer.pos.x >= 0 and settings.timer.pos.y >= 0 then
        return
    end
    local screen = windower.get_windower_settings()
    local width = timer_text:extents()
    timer_text:pos(math.floor(screen.x_res / 2 - width / 2), math.floor(screen.y_res / 3))
end

-- Seconds the frozen (found) time stays on screen before hiding.
local FOUND_DISPLAY_SECONDS = 5
-- Bumped on every start/freeze so a stale hide timer does nothing.
local timer_serial = 0

-- Start counting from zero. `expected` is the seconds until the pop is
-- expected, or nil for a plain count-up.
local function timer_start(expected)
    timer_serial = timer_serial + 1
    timer_started = os.time()
    timer_expected = expected
    timer_running = true
    render_timer(0)
    set_timer_color(countdown_color(expected))
    if settings.show_timer then
        place_timer()
        timer_text:show()
    end
end

-- Show or hide the timer immediately, if a search is active, to match the setting.
local function timer_apply_visibility()
    if settings.show_timer and timer_started then
        place_timer()
        timer_text:show()
    else
        timer_text:hide()
    end
end

-- Forget the saved position so the timer is auto-centered again.
local function timer_reset_position()
    settings.timer.pos.x = -1
    settings.timer.pos.y = -1
    config.save(settings)
    if timer_started and settings.show_timer then
        place_timer()
    end
end

-- Stop counting, turn blue, and hide after FOUND_DISPLAY_SECONDS.
local function timer_freeze()
    if timer_started then
        render_timer(os.time() - timer_started)
    end
    timer_running = false
    set_timer_color(settings.found_color)

    timer_serial = timer_serial + 1
    local serial = timer_serial
    coroutine.schedule(function()
        if serial == timer_serial then
            timer_text:hide()
        end
    end, FOUND_DISPLAY_SECONDS)
end

local function timer_hide()
    timer_running = false
    timer_started = nil
    timer_text:hide()
end

windower.register_event('prerender', function()
    if not timer_running then
        return
    end
    local seconds = os.time() - timer_started
    if seconds == timer_shown then
        return
    end
    render_timer(seconds)

    if timer_expected then
        local remaining = timer_expected - seconds
        set_timer_color(countdown_color(remaining))
        -- One beep per second through the alert window. Nothing once the
        -- pop is late (remaining <= 0); a find stops the timer, so nothing
        -- on or after the second the mob popped either.
        local c = settings.countdown
        if remaining > 0 and remaining <= c.thresholds.alert then
            play_sound(c.sound)
        end
    end
end)

local function play_found_sound()
    play_sound(settings.alert)
end

local help_text = [[pop usage:
  //pop <mob1> [<mob2> ... <mobN>] [countdown]
    mob: a 0x-prefixed hex index (0x00f8) or a name; names take * wildcards and need
         quotes if they contain spaces. Several mobs are checked in order; first found wins.
    countdown: expected seconds until the pop. The timer changes color as it nears and
         beeps through the last few seconds.
  //pop stop              Stop searching, tracking and targeting.
  //pop help              Show this text.
Settings (name alone shows the value; add a value to set it):
  scan_delay <n>          Seconds between widescans while searching (default 5).
  status_delay <n>        Seconds between checks of a found mob (default 1).
  timeout <n>             Seconds to wait for a widescan before giving up (default 5).
  track on|off            Widescan-track the found mob and report distance/HP/claim.
  target off|packet|command  Target the mob in range: lock-on packet, or /target.
  loop on|off             Search again after the found mob dies or despawns.
  timer on|off|reset      Show the on-screen timer; reset re-centers it.
  alert on|off            Chime when a mob is found.
  countdown on|off        Beep through the last seconds before an expected pop.]]

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
--   'retry', seconds - wait that long, then resume (rescan, or re-check the tracked mob)
-- It is resumed with 'results' when the list arrived, or 'timeout' if it did not.
--------------------------------------------------------------------------------

-- 'Name [0xIIII]' for a table with Name and Index fields.
local function label(mob)
    return '%s [0x%04X]':format(mob.Name, mob.Index)
end

-- A query is either {index = <number>} or {name = <lowercase wildcard pattern>}.
-- Once the other half of the mob's identity is known (the name of an index, or
-- the index of a name), it is stored in query.known = {Index, Name} and every
-- message about the query shows both instead of what the user typed.
local function describe(query)
    if query.known then
        return label(query.known)
    elseif query.index then
        return '0x%04X':format(query.index)
    end
    return query.name
end

local function learn(query, index, name)
    if not query.known and name and name ~= '?' then
        query.known = {Index = index, Name = name}
    end
end

-- Name index queries from the client's entity table, which carries the names
-- of the zone's mobs whether or not they are spawned or in range.
local function resolve_indices(queries)
    local mob_list
    for _, query in ipairs(queries) do
        if query.index and not query.known then
            mob_list = mob_list or windower.ffxi.get_mob_list()
            local name = mob_list[query.index]
            if name and name ~= '' then
                learn(query, query.index, name)
            end
        end
    end
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
            learn(query, found[1].Index, found[1].Name)
            if settings.track then
                log('Tracking: %s':format(label(found[1])))
                tracked_index = found[1].Index
                tracked_pos = nil
                windower.ffxi.wide_scan_track_index(found[1].Index)
            else
                log('Found: %s':format(label(found[1])))
            end
            timer_freeze()
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
            timer_hide()
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
local function status_line(found, seen_alive)
    local index = found.Index
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

    return '%s: %s':format(label(found), table.concat(parts, ' | '))
end

-- Make the client target the mob by injecting the Lock Target packet the
-- server would send. Only possible while the entity is loaded client-side.
local function target_mob(index)
    if settings.target == 'off' then
        return
    end
    local mob = windower.ffxi.get_mob_by_index(index)
    if not mob or not mob.valid_target or is_dead(mob) then
        return
    end
    local current = windower.ffxi.get_mob_by_target('t')
    if current and current.index == index then
        return
    end

    if settings.target == 'command' then
        windower.send_command('input /target %s':format(mob.name))
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

local function end_tracking(reason)
    log(reason)
    tracked_index = nil
    tracked_pos = nil
    windower.ffxi.wide_scan_stop_tracking()
end

-- Runs inside the tracker coroutine after a mob has been widescan-tracked:
-- report status changes (and target it, if enabled) every settings.status_delay
-- seconds. Returns when the mob dies or the client drops the track (the mob
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

        local line = status_line(mob, seen_alive)
        if line ~= last_line then
            log(line)
            last_line = line
        end

        if entity and is_dead(entity, seen_alive) then
            end_tracking('%s has died; tracking stopped.':format(label(mob)))
            return
        end

        if windower.ffxi.wide_scan_get_tracking_info() then
            seen_tracking = true
        elseif seen_tracking then
            end_tracking('Lost track of %s (dead, despawned or out of range).':format(label(mob)))
            return
        end

        target_mob(mob.Index)
        coroutine.yield('retry', settings.status_delay)
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

-- Track-off counterpart of monitor: rescan every settings.status_delay seconds
-- and return once the mob has left the widescan results (dead or despawned).
-- Returns false if a scan timed out, so the caller stops. With `quiet`, logs
-- nothing (used to wait out a corpse after the monitor already reported it).
local function watch(mob, quiet)
    if not quiet then
        log('Waiting for %s to die or despawn.':format(label(mob)))
    end
    while true do
        coroutine.yield('retry', settings.status_delay)
        request_scan()
        if coroutine.yield('scan') == 'timeout' then
            error('Scan timed out after %g seconds.':format(settings.timeout))
            return false
        end
        if not in_scan(mob.Index) then
            if not quiet then
                log('%s is gone (dead or despawned).':format(label(mob)))
            end
            return true
        end
        target_mob(mob.Index)
    end
end

-- `queries` is a priority-ordered list; each scan is checked against every
-- query before waiting and scanning again. Once a found mob is gone (its track
-- ends, or it leaves the scan results), the search either finishes or, with
-- settings.loop, starts over for the same list.
local function search_and_track(queries)
    resolve_indices(queries)
    log('Searching for %s...':format(describe_all(queries)))
    local announced_wait = false
    -- True for the first scan of a search and of each looped restart, so
    -- those scan immediately instead of waiting scan_delay.
    local scan_now = true

    while true do
        if not scan_now then
            coroutine.yield('retry', settings.scan_delay)
        end
        scan_now = false

        request_scan()
        local outcome = coroutine.yield('scan')

        if outcome == 'timeout' then
            error('Scan timed out after %g seconds.':format(settings.timeout))
            timer_hide()
            return
        end

        -- The entity table may have filled in since the last try.
        resolve_indices(queries)
        local mob, done = track_first_match(queries)
        if mob then
            local gone
            if settings.track then
                monitor(mob)
                -- A dead mob stays in widescan results until its corpse
                -- despawns; wait for that or the restarted search would
                -- find and alert on it again.
                gone = not settings.loop or watch(mob, true)
            else
                gone = watch(mob)
            end
            if not gone then
                timer_hide()
                return
            elseif not settings.loop then
                return
            end
            log('Looping: searching for %s again.':format(describe_all(queries)))
            timer_start(queries.expected)
            announced_wait = false
            scan_now = true
        elseif done then
            return
        elseif not announced_wait then
            local what = #queries == 1 and describe(queries[1]) or 'None of the targets'
            log('%s not up yet; rescanning every %gs until found. //pop stop to cancel.':format(what, settings.scan_delay))
            announced_wait = true
        end
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

    local ok, signal, wait = coroutine.resume(co, ...)
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
        end, wait)
    end
end

local function start_tracking(queries)
    if tracker then
        log('Replacing the search in progress.')
    end
    tracked_index = nil
    tracked_pos = nil
    timer_start(queries.expected)
    tracker = coroutine.create(search_and_track)
    resume_tracker(tracker, queries)
end

local function stop_tracking()
    tracker = nil
    tracked_index = nil
    tracked_pos = nil
    timer_hide()
    windower.ffxi.wide_scan_stop_tracking()
end

-- Widescan state does not survive a zone change, so neither does ours.
windower.register_event('zone change', function()
    if tracker then
        stop_tracking()
        log('Zoned; stopped.')
    end
end)

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
-- Boolean settings adjustable from the command line:
-- command -> {description, path of keys into settings}.
local bool_settings = {
    track = {'Tracking after a find', {'track'}},
    loop = {'Looping after a find is gone', {'loop'}},
    alert = {'Sound on a find', {'alert', 'enabled'}},
    countdown = {'Countdown beeps before an expected pop', {'countdown', 'sound', 'enabled'}},
}

-- Returns the table holding the setting and the key within it.
local function resolve(path)
    local t = settings
    for i = 1, #path - 1 do
        t = t[path[i]]
    end
    return t, path[#path]
end

-- Show the setting, or set and save it when a value is given.
local function show_or_set_bool(cmd, value)
    local description, path = unpack(bool_settings[cmd])
    local t, key = resolve(path)
    if value then
        local flag = parse_bool(value)
        if flag == nil then
            error('%s expects on/off (or true/false, yes/no, 1/0).':format(cmd))
            return
        end
        t[key] = flag
        config.save(settings)
    end
    log('%s: %s':format(description, t[key] and 'on' or 'off'))
end

-- Multiple-choice settings: key -> {description, allowed values in order}.
local choice_settings = {
    target = {'Targeting after a find', {'off', 'packet', 'command'}},
}

-- Show the setting, or set and save it when a value is given.
local function show_or_set_choice(key, value)
    local description, choices = unpack(choice_settings[key])
    if value then
        value = value:lower()
        local valid = false
        for _, choice in ipairs(choices) do
            valid = valid or choice == value
        end
        if not valid then
            error('%s expects one of: %s':format(key, table.concat(choices, ', ')))
            return
        end
        settings[key] = value
        config.save(settings)
    end
    log('%s: %s':format(description, settings[key]))
end

-- Numeric settings adjustable from the command line: key -> description.
local numeric_settings = {
    scan_delay = 'Delay between widescans',
    status_delay = 'Delay between status checks',
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
        -- One add_to_chat per line; the chat log does not render embedded newlines.
        for line in help_text:gmatch('[^\n]+') do
            windower.add_to_chat(207, line)
        end
    elseif cmd == 'stop' or cmd == 'end' then
        stop_tracking()
        log('Stopped.')
    elseif numeric_settings[cmd] then
        show_or_set(cmd, args[2])
    elseif bool_settings[cmd] then
        show_or_set_bool(cmd, args[2])
    elseif choice_settings[cmd] then
        show_or_set_choice(cmd, args[2])
    elseif cmd == 'timer' then
        local value = args[2] and args[2]:lower()
        if value == 'reset' then
            timer_reset_position()
            log('Timer position reset.')
        elseif value then
            local flag = parse_bool(value)
            if flag == nil then
                error('timer expects on, off or reset.')
                return
            end
            settings.show_timer = flag
            config.save(settings)
            timer_apply_visibility()
        end
        log('Timer: %s':format(settings.show_timer and 'on' or 'off'))
    else
        -- A trailing whole number is the expected seconds until the pop, used
        -- by the on-screen timer for its countdown colors and beeps.
        local expected
        if #args > 1 and args[#args]:match('^%d+$') then
            expected = tonumber(table.remove(args))
            if expected <= 0 then
                error('Expected pop time must be a positive number of seconds.')
                return
            end
        end

        -- Each remaining argument is a target, in priority order. An argument with
        -- the 0x prefix is an index; anything else is a (wildcard) name. Names
        -- with spaces must be quoted so the command parser keeps them together.
        local queries = {expected = expected}
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
