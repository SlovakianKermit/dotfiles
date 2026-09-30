local mp = require 'mp'
local utils = require 'mp.utils'

local state_file = mp.command_native({ "expand-path", "~~/window-state.json" })

local function read_state()
    local f = io.open(state_file, "r")
    if not f then
        return {}
    end
    local data = f:read("*a")
    f:close()
    local ok, t = pcall(utils.parse_json, data)
    if ok and type(t) == "table" then
        return t
    end
    return {}
end

local function write_state(t)
    local f = io.open(state_file, "w")
    if f then
        f:write(utils.format_json(t))
        f:close()
    end
end

local previous = read_state()
local cache = {
    fullscreen = false,
    maximized = false,
    scale = previous.scale,
}

mp.observe_property("fullscreen", "bool", function(_, v)
    if v ~= nil then
        cache.fullscreen = v
    end
end)
mp.observe_property("window-maximized", "bool", function(_, v)
    if v ~= nil then
        cache.maximized = v
    end
end)
mp.observe_property("current-window-scale", "number", function(_, v)
    if v and v > 0
        and not mp.get_property_native("fullscreen")
        and not mp.get_property_native("window-maximized") then
        cache.scale = v
    end
end)

local function save_state()
    local s = {
        fullscreen = cache.fullscreen,
        maximized = cache.maximized,
    }
    if not cache.fullscreen and not cache.maximized and cache.scale and cache.scale > 0 then
        s.scale = cache.scale
    end
    write_state(s)
end

local restored = false

local function restore_state()
    if restored then
        return
    end
    restored = true
    local s = previous
    if s.fullscreen then
        mp.set_property_native("fullscreen", true)
    elseif s.maximized then
        mp.set_property_native("window-maximized", true)
    elseif s.scale and s.scale > 0 then
        mp.set_property_native("window-scale", s.scale)
    end
end

mp.register_event("file-loaded", restore_state)
mp.register_event("shutdown", save_state)
