-- h264-seek-swdecode.lua
--
-- H.264: decode in software while seeking, hardware the rest of the time.
--
-- Why: ffmpeg's h264 decoder calls ff_get_format() after every flush, which
-- tears down and rebuilds the hwaccel context (hwaccel_uninit/hwaccel_init).
-- HEVC does not do this. On AMD the rebuild is expensive, so scrubbing the
-- seekbar on H.264 stutters, while software decoding seeks cleanly.
-- Upstream: ffmpeg #20760 / ffmpeg 21290, mpv #17136.
--
-- Behaviour: when a seek starts, hwdec drops to "no"; ~1s after playback
-- restarts it is put back to whatever was configured (usually auto-safe).
-- Non-H.264 files are left completely alone.
--
-- Note: changing hwdec mid-playback makes mpv restart the decoder, which it
-- reports as a seek. Without suppression that feeds back into this script and
-- oscillates once per second, so every change opens a short ignore window.

local mp = require 'mp'

local RESTORE_DELAY = 1.0
local SELF_CHANGE_GRACE = 0.6

-- Captured lazily: at script load the config may not be applied yet, so the
-- runtime value can still be the built-in default ("no").
local default_hwdec = nil
local timer = nil
local in_seek = false
local started = false
local ignore_seeks_until = 0

local function log(msg)
    mp.log("v", "h264-seek-swdecode: " .. msg)
end

local function ensure_default()
    if default_hwdec == nil then
        local v = mp.get_property("hwdec")
        if v and v ~= "no" then
            default_hwdec = v
        end
    end
    return default_hwdec or "auto-safe"
end

local function is_h264()
    for _, track in ipairs(mp.get_property_native("track-list") or {}) do
        if track.type == "video" and track.codec == "h264" then
            return true
        end
    end
    return false
end

local function cancel_timer()
    if timer then
        timer:kill()
        timer = nil
    end
end

local function set_hwdec(value, why)
    local current = mp.get_property("hwdec")
    if current == value then return end
    ignore_seeks_until = mp.get_time() + SELF_CHANGE_GRACE
    log(why .. ": hwdec " .. tostring(current) .. " -> " .. value)
    mp.set_property("hwdec", value)
end

local function use_software()
    if not is_h264() then return end
    set_hwdec("no", "seek")
end

local function use_hardware()
    timer = nil
    if not is_h264() then
        in_seek = false
        return
    end
    -- Still paused: keep software decode, the pause observer retries on resume.
    if mp.get_property_native("pause") then return end
    set_hwdec(ensure_default(), "restored")
    in_seek = false
end

local function schedule_restore()
    cancel_timer()
    timer = mp.add_timeout(RESTORE_DELAY, use_hardware)
end

local function on_seek(why)
    if not started or not is_h264() then return end
    if mp.get_time() < ignore_seeks_until then return end
    in_seek = true
    cancel_timer()
    use_software(why)
end

mp.register_event("seek", function() on_seek() end)

mp.observe_property("seeking", "bool", function(_, seeking)
    if seeking then on_seek() end
end)

-- Seek finished, picture is up: give it a moment, then go back to hardware.
mp.register_event("playback-restart", function()
    started = true
    if not is_h264() or not in_seek then return end
    schedule_restore()
end)

-- New file: remember the configured default and start on it.
mp.register_event("file-loaded", function()
    cancel_timer()
    in_seek = false
    started = false
    ensure_default()
    set_hwdec(default_hwdec, "new file")
end)

-- If the user seeks and then leaves it paused, don't rebuild the decoder while
-- paused; restore once playback resumes.
mp.observe_property("pause", "bool", function(_, paused)
    if not paused and in_seek then
        schedule_restore()
    end
end)
