-- Manual override for SDR / HDR output.
-- Key: Shift+Ctrl+S
--
-- mpv.conf now selects output automatically per file:
--   SDR sources -> target-colorspace-hint=no (bt.709 / sRGB, matches KWin)
--   HDR sources -> [hdr-passthrough] profile (PQ/HLG -> true HDR passthrough)
--
-- This key is only needed when auto-detection is wrong, e.g. an HDR file with
-- missing/incorrect colour tags (untagged HDR plays as SDR), or SDR content
-- tagged as HDR. It starts in the SDR state, matching the config default, so
-- the first press forces HDR passthrough.
--
-- SDR  -> target-colorspace-hint=no  target-prim=bt.709  target-trc=srgb
--         saturation=0
-- HDR  -> target-colorspace-hint=yes target-prim=auto    target-trc=auto
--         saturation=20

local sdr = true

local function set_prop(name, value)
    local ok, err = pcall(mp.set_property, name, value)
    if not ok then
        mp.msg.warn("sdr-toggle: could not set " .. name .. " = " .. tostring(value) ..
                    " (" .. tostring(err) .. ")")
    end
end

mp.add_key_binding("Shift+Ctrl+s", "toggle-sdr", function()
    sdr = not sdr
    if sdr then
        set_prop("target-colorspace-hint", "no")
        set_prop("target-prim", "bt.709")
        set_prop("target-trc", "srgb")
        set_prop("saturation", 0)
    else
        set_prop("target-colorspace-hint", "yes")
        set_prop("target-prim", "auto")
        set_prop("target-trc", "auto")
        set_prop("saturation", 20)
    end
    mp.osd_message("Output: " .. (sdr and "SDR  (bt.709 / sRGB)" or "HDR passthrough (forced)"), 2)
end)
