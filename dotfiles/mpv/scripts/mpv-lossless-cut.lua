local msg = require("mp.msg")
local utils = require("mp.utils")

local options = {
	lossless = true,
	output_dir = ".",
	multi_cut_mode = "separate",
	ffmpeg_path = "ffmpeg",
	verify = true,
	verify_duration = true,
	duration_tolerance = 2.0,
	min_size_bytes = 1024,
	ffprobe_path = "ffprobe",
	notify = true,
	notify_timeout = 1500,
	notify_error_timeout = 15000,
	delete_source = true,
	quit_after_cut = true,
}

require("mp.options").read_options(options, "mpv-lossless-cut")

local cuts = {}
local os_name = package.config:sub(1, 1) == "\\" and "windows"
	or (io.popen("uname"):read("*a"):match("Darwin") and "mac" or "linux")

-- utility functions
local function log(message)
	msg.info(message)
	mp.osd_message(message)
end

local function sanitize_filename(filename)
	local sanitized = filename:gsub('[\\/:*?"<>|]', "_")

	-- leading and trailing whitespace
	sanitized = sanitized:gsub("^%s*(.-)%s*$", "%1")

	return sanitized
end

local function ffmpeg_escape_filepath(path)
	if os_name == "windows" then
		return path:gsub("/", "\\"):gsub("\\", "\\\\"):gsub("'", "'\\''")
	else
		return path:gsub("\\", "/"):gsub("'", "'\\''")
	end
end

local function to_hms(secs)
	local hours = math.floor(secs / 3600)
	local minutes = math.floor((secs % 3600) / 60)
	local remaining_seconds = ((secs % 3600) % 60)

	local str = {}
	if hours > 0 then
		table.insert(str, hours .. "h")
	end
	if minutes > 0 then
		table.insert(str, minutes .. "m")
	end
	if remaining_seconds > 0 then
		table.insert(str, string.format("%.1fs", remaining_seconds))
	end

	return #str == 0 and "0" or table.concat(str, "")
end

local function join_paths(path1, path2)
	if not path1 or path1 == "" then
		return path2 or ""
	end
	if not path2 or path2 == "" then
		return path1
	end

	local separator
	if os_name == "windows" then
		separator = "\\"
	else
		separator = "/"
	end

	-- normalize separators in both paths
	path1 = path1:gsub("[/\\]", separator)
	path2 = path2:gsub("[/\\]", separator)

	-- remove trailing separator from path1
	path1 = path1:gsub(separator == "\\" and "\\+$" or "/+$", "")

	-- handle absolute path2 (starts with drive letter on Windows or / on Unix)
	if path2:match("^[A-Za-z]:") or path2:match("^" .. (separator == "\\" and "\\" or "/")) then
		return path2
	end

	-- handle relative paths with .. and .
	local function resolve_path(base, relative)
		local parts = {}

		-- split base path into parts
		local pattern = separator == "\\" and "[^\\\\]+" or "[^/]+"
		for part in base:gmatch(pattern) do
			table.insert(parts, part)
		end

		-- process relative path parts
		for part in relative:gmatch(pattern) do
			if part == ".." then
				if #parts > 0 then
					table.remove(parts)
				end
			elseif part ~= "." then
				table.insert(parts, part)
			end
		end

		-- reconstruct path
		local result = table.concat(parts, separator)

		-- handle drive letters on Windows
		if base:match("^[A-Za-z]:") then
			local drive = base:match("^[A-Za-z]:")
			if not result:match("^[A-Za-z]:") then
				result = drive .. separator .. result
			end
		elseif
			base:match("^" .. (separator == "\\" and "\\\\" or "/"))
			and not result:match("^" .. (separator == "\\" and "\\\\" or "/"))
		then
			result = separator .. result
		end

		return result
	end

	return resolve_path(path1, path2)
end

-- file operations
local function ensure_directory_exists(dir)
	local dir_info = utils.file_info(dir)
	if not dir_info or not dir_info.is_dir then
		local args
		if os_name == "windows" then
			args = { "cmd", "/c", "mkdir", dir }
		else
			args = { "mkdir", "-p", dir }
		end

		local res = utils.subprocess({ args = args, cancellable = false })
		return res.status == 0
	end
	return true
end

local function delete_file(file_path)
	local file_info = utils.file_info(file_path)

	if not file_info or file_info.is_dir then
		return false
	end

	local args
	if os_name == "windows" then
		args = { "cmd", "/c", "del", file_path }
	else
		args = { "rm", file_path }
	end

	local res = utils.subprocess({ args = args, cancellable = false })
	return res.status == 0
end

local function set_file_times(file_path, mtime)
	if not mtime then
		msg.warn("No mtime provided for: " .. file_path)
		return false
	end

	local file_info = utils.file_info(file_path)
	if not file_info then
		msg.error("File does not exist, cannot set times: " .. file_path)
		return false
	end

	local normalized_path = file_path:gsub([[\]], "/")
	local result

	if os_name == "windows" then
		result = utils.subprocess({
			args = {
				"powershell",
				"-command",
				string.format(
					"$file = Get-Item -LiteralPath '%s'; "
						.. '$date = (Get-Date "1970-01-01 00:00:00").AddSeconds(%d).ToLocalTime(); '
						.. "$file.CreationTime = $date; "
						.. "$file.LastWriteTime = $date",
					normalized_path:gsub("/", "\\"):gsub("'", "''"),
					mtime
				),
			},
			cancellable = false,
		})
	else
		result = utils.subprocess({
			args = {
				"touch",
				"-t",
				os.date("!%Y%m%d%H%M.%S", mtime),
				normalized_path,
			},
			cancellable = false,
		})
	end

	local success = (result.status == 0)

	if not success then
		local error_msg = result.stderr or result.stdout or "Unknown error"
		msg.error("Failed to set file times for " .. file_path .. ": " .. error_msg)
	else
		msg.verbose("Successfully set file times for: " .. file_path)
	end

	return success
end

-- ffmpeg operations
local function run_ffmpeg(args)
	local base_args = {
		options.ffmpeg_path,
		-- hide output
		"-nostdin",
		"-loglevel",
		"error",
		-- overwrite existing files
		"-y",
	}

	-- add args to base
	for _, arg in ipairs(args) do
		table.insert(base_args, arg)
	end

	local cmd_str = table.concat(base_args, " ")
	print("Running ffmpeg command: " .. cmd_str)

	local result = utils.subprocess({
		args = base_args,
		cancellable = false,
	})

	return result.status == 0, result.stdout, result.stderr
end

local function probe_duration(path)
	local result = utils.subprocess({
		args = {
			options.ffprobe_path,
			"-v",
			"error",
			"-show_entries",
			"format=duration",
			"-of",
			"default=noprint_wrappers=1:nokey=1",
			path,
		},
		cancellable = false,
		capture_stdout = true,
	})

	if not result or result.status ~= 0 then
		return nil
	end

	return tonumber(result.stdout)
end

-- Cheap sanity check on a produced file: it exists and is non-trivially sized.
-- Reads only filesystem metadata, never the media itself.
local function verify_output(path)
	if not options.verify then
		return true
	end

	local info = utils.file_info(path)
	if not info then
		return false, "output file missing"
	end
	if info.is_dir then
		return false, "output is a directory"
	end
	if info.size < options.min_size_bytes then
		return false, string.format("output suspiciously small (%d bytes)", info.size)
	end

	return true
end

local function notify(summary, body, urgency)
	if not options.notify then
		return
	end

	local text = summary
	if body and body ~= "" then
		text = summary .. "\n" .. body
	end

	-- errors linger much longer than the routine completion popup
	local timeout = options.notify_timeout
	if urgency == "critical" and options.notify_error_timeout and options.notify_error_timeout > 0 then
		timeout = options.notify_error_timeout
	end

	local args = { "notify-send", "-a", "mpv", "-h", "string:desktop-entry:mpv" }
	if timeout and timeout > 0 then
		table.insert(args, "-t")
		table.insert(args, tostring(timeout))
	end
	if urgency then
		table.insert(args, "-u")
		table.insert(args, urgency)
	end
	table.insert(args, "mpv lossless cut")
	table.insert(args, text)

	-- run synchronously so the notification is delivered before we potentially
	-- close the current file / quit mpv
	mp.command_native({
		name = "subprocess",
		args = args,
		playback_only = false,
	})
end

local function remove_dir(dir)
	if not dir or dir == "" then
		return
	end

	local args
	if os_name == "windows" then
		args = { "cmd", "/c", "rmdir", "/s", "/q", dir }
	else
		args = { "rm", "-rf", dir }
	end

	utils.subprocess({ args = args, cancellable = false })
end

local function quit_mpv()
	-- close the whole player once the cut is done (rather than advancing
	-- to the next item in the playlist)
	mp.commandv("quit")
end

local function render_cut(input, outpath, start, duration, input_mtime)
	local args = {
		-- seek to start before loading file (faster) https://trac.ffmpeg.org/wiki/Seeking#Inputseeking
		"-ss",
		tostring(start),
		"-t",
		tostring(duration),
		"-i",
		input,
		-- copy all input streams
		"-map",
		"0",
		-- shift timestamps so they start at 0
		"-avoid_negative_ts",
		"make_zero",
	}

	if options.lossless then
		table.insert(args, "-c")
		table.insert(args, "copy")
	end

	table.insert(args, outpath)

	local success = run_ffmpeg(args)

	if success and input_mtime then
		set_file_times(outpath, input_mtime)
	end

	return success
end

local function merge_cuts(temp_dir, filepaths, outpath, input_mtime)
	-- i hate that you have to do a separate command and render each cut separately first, i tried using
	-- filter_complex for merging with multiple inputs but it wouldn't let me. todo: look into this further

	local merge_file = join_paths(temp_dir, "merging.txt")
	local content = ""

	for _, path in ipairs(filepaths) do
		content = content .. string.format("file '%s'\n", ffmpeg_escape_filepath(path))
	end

	local file = io.open(merge_file, "w")
	if not file then
		log("Failed to create merge file")
		return false
	end
	file:write(content)
	file:close()

	local success = run_ffmpeg({
		"-f",
		"concat",
		"-safe",
		"0",
		"-i",
		merge_file,
		-- don't re-encode
		"-c",
		"copy",
		-- copy all input streams
		"-map",
		"0",
		outpath,
	})

	os.remove(merge_file)

	if success and input_mtime then
		set_file_times(outpath, input_mtime)
	end

	if success then
		for _, path in ipairs(filepaths) do
			os.remove(path)
		end
	end

	return success
end

local function dump_cache(outpath)
	local cache_state = mp.get_property_native("demuxer-cache-state")
	if not cache_state then
		return nil
	end

	local cache_ranges = cache_state["seekable-ranges"]
	if #cache_ranges == 0 then
		return nil
	end

	local cache_start = cache_ranges[1]["start"]
	local cache_end = cache_ranges[1]["end"]

	local success = mp.commandv("dump-cache", cache_start, cache_end, outpath)
	if not success then
		log("Failed to dump cache")
		return nil
	end

	return cache_start
end

local function cut_render()
	if #cuts == 0 or not cuts[#cuts].end_time then
		log("No complete cuts to render")
		return
	end

	log("Rendering cuts...")

	local input = mp.get_property("path")
	local filename = mp.get_property("filename")

	local input_info = utils.file_info(input)

	local is_stream = input_info == nil

	local outdir
	if options.output_dir == "@cwd" then
		outdir = utils.getcwd()
	elseif is_stream then
		-- no source directory, so relative paths are relative to the working directory
		outdir = join_paths(utils.getcwd(), options.output_dir)
	else
		local input_dir = utils.split_path(input)
		outdir = join_paths(input_dir, options.output_dir)
	end

	-- create output directory if needed
	if not ensure_directory_exists(outdir) then
		log("Failed to create output directory")
		return
	end

	local filename_noext, ext
	local cache_offset = 0

	local temp_cache_file_name = join_paths(outdir, "cache-dump.mkv")

	if not is_stream then
		filename_noext, ext = filename:match("^(.*)(%.[^%.]+)$")
		if not filename_noext then
			-- default to mkv if no extension, cause ffmpeg needs one
			filename_noext, ext = filename, ".mkv"
		end
	else
		filename_noext = sanitize_filename(mp.get_property("media-title"))
		ext = ".mkv"

		input = temp_cache_file_name

		local offset = dump_cache(input)
		if not offset then
			log("Failed to dump stream cache")
			return
		end

		cache_offset = offset
	end

	input_info = utils.file_info(input)

	if not input_info then
		log("Failed to read input file info")
	end

	-- sort cuts by start time
	table.sort(cuts, function(a, b)
		return a.start_time < b.start_time
	end)

	local num_cuts = #cuts
	local do_merge = num_cuts > 1 and options.multi_cut_mode == "merge"

	-- outputs keep the source's own filename; merge segments go to a scratch
	-- dir so they don't collide with the single final output name
	local out_path = join_paths(outdir, filename_noext .. ext)

	if out_path == input then
		local err = "refusing to overwrite the source file"
		log(err)
		notify("Cut failed", err, "critical")
		return
	end

	local seg_dir = outdir
	if do_merge then
		seg_dir = join_paths(outdir, ".mpv-cut-tmp")
		if not ensure_directory_exists(seg_dir) then
			local err = "failed to create temporary directory"
			log(err)
			notify("Cut failed", err, "critical")
			return
		end
	end

	local mtime = input_info and input_info.mtime or nil
	local rendered = {}

	for i, cut in ipairs(cuts) do
		if cut.end_time then
			local duration = cut.end_time - cut.start_time

			local target
			if num_cuts == 1 then
				target = out_path
			elseif do_merge then
				target = join_paths(seg_dir, string.format("seg_%d%s", i, ext))
			else
				target = join_paths(outdir, string.format("%s_%d%s", filename_noext, i, ext))
			end

			log(string.format("(%d/%d) Rendering cut to %s", i, num_cuts, target))

			if render_cut(input, target, cut.start_time - cache_offset, duration, mtime) then
				table.insert(rendered, { path = target, duration = duration })
				log(string.format("(%d/%d) Rendered cut to %s", i, num_cuts, target))
			else
				log("Failed to render cut " .. i)
			end
		end
	end

	local failure

	-- existence / size check on every produced piece
	for _, seg in ipairs(rendered) do
		local ok, reason = verify_output(seg.path)
		if not ok then
			failure = seg.path .. ": " .. reason
			break
		end
	end

	if not failure and #rendered < num_cuts then
		failure = string.format("%d of %d segments failed to render", num_cuts - #rendered, num_cuts)
	end

	local success_path = nil
	local final_duration = nil

	if not failure and do_merge then
		local seg_files = {}
		local seg_duration = 0
		for _, seg in ipairs(rendered) do
			table.insert(seg_files, seg.path)
			seg_duration = seg_duration + (probe_duration(seg.path) or 0)
		end

		log("Merging cuts...")
		if not merge_cuts(seg_dir, seg_files, out_path, mtime) then
			failure = "merge failed"
		else
			local ok, reason = verify_output(out_path)
			local merged_duration = options.verify_duration and probe_duration(out_path) or nil

			if not ok then
				failure = out_path .. ": " .. reason
			elseif
				options.verify_duration
				and seg_duration > 0
				and merged_duration
				and math.abs(merged_duration - seg_duration) > options.duration_tolerance
			then
				-- a healthy concat matches the sum of its parts; comparing to the
				-- *requested* length would false-fail because lossless cuts snap
				-- to keyframes
				failure = string.format(
					"%s: merge duration mismatch (got %.2fs, parts sum to %.2fs)",
					out_path,
					merged_duration,
					seg_duration
				)
			else
				success_path = out_path
				final_duration = merged_duration
			end
		end
	elseif not failure and num_cuts == 1 then
		-- separate mode with one segment: already verified above
		success_path = out_path
		final_duration = options.verify_duration and probe_duration(out_path) or nil
	end

	if do_merge then
		remove_dir(seg_dir)
	end

	if failure then
		log("Cut failed: " .. failure)
		notify("Cut failed", failure, "critical")
	elseif success_path then
		local message = success_path
		if final_duration then
			message = string.format("%s (%.1fs)", success_path, final_duration)
		end
		log("Cut complete: " .. message)
		notify("Cut complete", message)

		-- once the output is verified: delete the source, then quit mpv
		if not is_stream then
			local source = mp.get_property("path")
			local do_delete = options.delete_source and source and source ~= success_path

			local function finish()
				if options.quit_after_cut then
					quit_mpv()
				end
			end

			if do_delete and not delete_file(source) then
				-- some mounts won't unlink while the handle is still closing
				mp.add_timeout(1.0, function()
					if delete_file(source) then
						log("Deleted source: " .. source)
					else
						msg.warn("Could not delete source: " .. source)
					end
					finish()
				end)
			else
				if do_delete then
					log("Deleted source: " .. source)
				end
				finish()
			end
		end
	end

	if is_stream then
		delete_file(temp_cache_file_name)
	end
end

-- cut management functions
local function cut_toggle_mode()
	options.multi_cut_mode = options.multi_cut_mode == "separate" and "merge" or "separate"
	log(string.format('Cut mode set to "%s"', options.multi_cut_mode))
end

local function cut_clear(silent)
	if next(cuts) then
		cuts = {}

		if not silent then
			log("Cuts cleared")
		end
	else
		if not silent then
			log("No cuts to clear")
		end
	end
end

local function cut_set_start(start_time)
	local last_cut = cuts[#cuts]
	if not last_cut or last_cut.end_time then
		local new_cut = { start_time = start_time }
		table.insert(cuts, new_cut)
		log(string.format("[cut %d] Set start time: %.2fs", #cuts, start_time))
	else
		last_cut.start_time = start_time
		log(string.format("[cut %d] Updated start time: %.2fs", #cuts, start_time))
	end
end

local function cut_set_end(end_time)
	if #cuts == 0 then
		log("No start point found")
		return
	end

	local had_end_time = cuts[#cuts].end_time ~= nil

	cuts[#cuts].end_time = end_time
	log(string.format("[cut %d] %s end time: %.2fs", #cuts, had_end_time and "Updated" or "Set", end_time))
end

-- key bindings
mp.add_key_binding("g", "cut_set_start", function()
	local time = mp.get_property_number("time-pos")
	if time ~= nil then
		cut_set_start(time)
	end
end)

mp.add_key_binding("h", "cut_set_end", function()
	local time = mp.get_property_number("time-pos")
	if time ~= nil then
		cut_set_end(time)
	end
end)

mp.add_key_binding("G", "cut_set_start_sof", function()
	cut_set_start(0)
end)

mp.add_key_binding("H", "cut_set_end_eof", function()
	cut_set_end(mp.get_property_number("duration"))
end)

mp.add_key_binding("ctrl+g", "cut_toggle_mode", cut_toggle_mode)
mp.add_key_binding("ctrl+h", "cut_clear", cut_clear)

mp.add_key_binding("r", "cut_render", cut_render)

mp.register_event("end-file", function()
	cut_clear(true)
end)

print("mpv-lossless-cut loaded")
