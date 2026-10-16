-- Toggle SDR output (bt.709 / sRGB) vs HDR passthrough.
-- Key: Shift+Ctrl+S
--
-- Why: with KWin's HDR compositing enabled, mpv adopts the compositor's
-- preferred HDR description and up-converts SDR content (SDR->PQ/BT.2020),
-- which tints near-white content (e.g. pale skin looks yellow). Forcing SDR
-- output makes KWin treat the surface as plain sRGB and it matches the source.
--
-- SDR  -> target-colorspace-hint=no  target-prim=bt.709  target-trc=srgb
-- HDR  -> target-colorspace-hint=yes target-prim=auto     target-trc=auto
--         (i.e. back to the mpv.conf defaults)

local sdr = false

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
    else
        set_prop("target-colorspace-hint", "yes")
        set_prop("target-prim", "auto")
        set_prop("target-trc", "auto")
    end
    mp.osd_message("Output: " .. (sdr and "SDR  (bt.709 / sRGB)" or "HDR passthrough"), 2)
end)
