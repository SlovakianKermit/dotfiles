---@diagnostic disable: undefined-global
-- Delete the currently playing file and advance to the next playlist entry.
-- Bound in input.conf as:  Ctrl+DEL  script-message delete-current

local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"

local opts = {
	-- seconds to wait for mpv to load the next item / release the old handle
	delete_delay = 0.5,
	-- extra delete attempts (some mounts refuse to unlink while the handle closes)
	retries = 2,
}

require "mp.options".read_options(opts, "delete-current")

local function basename(path)
	return path:match "([^/]+)$" or path
end

local function remove(path)
	local info = utils.file_info(path)
	if not info or info.is_dir then
		return false, "not a regular file"
	end

	local res = utils.subprocess { args = { "rm", "--", path }, cancellable = false }
	if res.status == 0 and utils.file_info(path) == nil then
		return true
	end

	local err = res.stderr and res.stderr:gsub("%s+$", "") or ""
	if err == "" then
		err = "rm exited with " .. tostring(res.status)
	end
	return false, err
end

-- Drop the already-deleted entry from the playlist so that playlist-prev does
-- not try to reopen a file that no longer exists. Removing an entry before the
-- current one does not interrupt playback.
local function drop_entry(index)
	if type(index) ~= "number" then
		return
	end
	local count = mp.get_property_number("playlist-count", 0) or 0
	if index < 0 or index >= count then
		return
	end
	mp.commandv("playlist-remove", tostring(index))
end

local function try_delete(path, name, quit_after, attempts, index)
	local ok, err = remove(path)
	if ok then
		msg.info("Deleted: " .. path)
		mp.osd_message("Deleted " .. name, 3)
		drop_entry(index)
		if quit_after then
			mp.commandv "quit"
		end
		return
	end

	if attempts > 1 then
		mp.add_timeout(1.0, function()
			try_delete(path, name, quit_after, attempts - 1, index)
		end)
		return
	end

	msg.warn("Could not delete " .. path .. ": " .. tostring(err))
	mp.osd_message("Could not delete " .. name .. ": " .. tostring(err), 5)
end

local function delete_current()
	local path = mp.get_property("path", "")
	if path == "" or path:match "^%a[%w+.-]*://" then
		mp.osd_message("Not a local file, nothing to delete", 3)
		return
	end

	local count = mp.get_property_number("playlist-count", 0) or 0
	local pos = mp.get_property_number("playlist-pos", 0) or 0
	local name = basename(path)
	local attempts = math.max(1, opts.retries)

	-- Order matters: never delete the file mpv is currently playing. mpv hits
	-- EOF on the unlinked file and quits before advancing, so leave the item
	-- first and only then delete the file (once its handle is closed).
	if pos < count - 1 then
		mp.commandv("playlist-next", "force")
		mp.add_timeout(opts.delete_delay, function()
			try_delete(path, name, false, attempts, pos)
		end)
	else
		-- Last item: delete, then close mpv ourselves. Letting the playlist end
		-- on its own would quit mpv and cancel a pending delete.
		try_delete(path, name, true, attempts, nil)
	end
end

mp.add_key_binding(nil, "delete-current", delete_current)
