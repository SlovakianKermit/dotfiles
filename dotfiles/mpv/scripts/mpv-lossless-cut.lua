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
	delete_retries = 5,
	delete_retry_delay = 0.75,
	queue_enabled = true,
	queue_scope = "output_dir",
	queue_poll_interval = 2,
	queue_stale_timeout = 21600,
	queue_max_wait = 0,
	show_cut_markers = true,
	cut_marker_prefix = "cut",
}

require("mp.options").read_options(options, "mpv-lossless-cut")

local cuts = {}
local os_name = package.config:sub(1, 1) == "\\" and "windows"
	or (io.popen("uname"):read("*a"):match("Darwin") and "mac" or "linux")

-- identity of this mpv process, used by the cross-instance queue
local my_pid = tonumber(mp.get_property_native("pid")) or 0
local my_host = "localhost"
do
	local file = io.open("/proc/sys/kernel/hostname", "r")
	if file then
		my_host = file:read("*l") or my_host
		file:close()
	end
end


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

-- Best-effort unlink that reports *why* it failed. Returns true if the path is
-- no longer there (missing already counts as success).
local function delete_file(file_path)
	local file_info = utils.file_info(file_path)

	if not file_info then
		-- already gone; nothing to do
		return true
	end

	if file_info.is_dir then
		return false, "path is a directory"
	end

	local args
	if os_name == "windows" then
		args = { "cmd", "/c", "del", "/f", file_path }
	else
		-- "--" so names starting with a dash are not parsed as options
		args = { "rm", "-f", "--", file_path }
	end

	local res = utils.subprocess({
		args = args,
		cancellable = false,
		capture_stdout = true,
		capture_stderr = true,
	})

	if res.status == 0 then
		return true
	end

	local err = res.stderr and res.stderr:gsub("%s+$", "") or ""
	if err == "" then
		err = "rm exited with " .. tostring(res.status)
	end
	return false, err
end

-- Delete the source after a verified cut. Network shares (SMB/CIFS, NFS) can
-- refuse - or only complete - an unlink while the player still holds the file
-- open, so this retries with backoff and confirms the file is really gone
-- instead of trusting the exit status. Calls on_done(err) when it gives up.
local function delete_source(file_path, on_done)
	local attempts = math.max(1, math.floor(tonumber(options.delete_retries) or 1))
	local delay = tonumber(options.delete_retry_delay) or 0.75

	local function attempt(n)
		local ok, err = delete_file(file_path)

		-- some servers accept the delete but only unlink once the last handle
		-- is closed, so the filesystem - not the exit code - is the truth
		if ok and not utils.file_info(file_path) then
			log("Deleted source: " .. file_path)
			on_done(nil)
			return
		elseif ok then
			err = "file still present after rm"
		end

		if n >= attempts then
			on_done(err or "unknown error")
			return
		end

		mp.add_timeout(delay * 2 ^ (n - 1), function()
			attempt(n + 1)
		end)
	end

	attempt(1)
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

-- cross-instance queue -------------------------------------------------------
-- Every mpv process runs its own copy of this script, so serialising cut jobs
-- has to happen through the filesystem. A lock directory (created with mkdir,
-- the one atomic primitive available) plus a FIFO ticket queue under
-- $XDG_RUNTIME_DIR keeps concurrent instances from clobbering each other's
-- scratch dirs or running two renders against the same destination.

local active_job

local function read_text(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local data = file:read("*a")
	file:close()
	return data
end

local function write_text(path, data)
	local file = io.open(path, "w")
	if not file then
		return false
	end
	file:write(data)
	file:close()
	return true
end

-- returns true if the command exited 0
local function run(args)
	local res = utils.subprocess({
		args = args,
		cancellable = false,
		capture_stdout = true,
		capture_stderr = true,
	})
	return res ~= nil and res.status == 0
end

-- pid liveness is the only reliable staleness signal: the lua thread blocks for
-- the whole ffmpeg run, so no heartbeat timer can fire mid-render
local function pid_alive(pid)
	pid = tonumber(pid)
	if not pid or pid <= 0 then
		return false
	end
	if os_name == "windows" then
		-- no cheap probe available; rely on the age timeout instead
		return true
	end
	return run({ "kill", "-0", tostring(pid) })
end

-- one queue per destination folder, unless queue_scope=global
local function queue_root(outdir)
	local base = os.getenv("XDG_RUNTIME_DIR")
	if not base or base == "" then
		base = os.getenv("TMPDIR") or "/tmp"
	end

	local global = options.queue_scope == "global"
	local scope = (global or not outdir) and "global" or tostring(outdir)

	-- djb2, so the scope fits in a directory name
	local hash = 5381
	for i = 1, #scope do
		hash = (hash * 33 + scope:byte(i)) % 4294967296
	end

	local key = string.format("%s-%08x", global and "global" or "outdir", hash)
	return join_paths(join_paths(base, "mpv-lossless-cut"), key)
end

local function lock_dir_of(root)
	return join_paths(root, "lock")
end

local function read_owner(root)
	local data = read_text(join_paths(lock_dir_of(root), "owner"))
	if not data then
		return nil
	end

	local owner = {}
	for key, value in data:gmatch("([%w_]+)=([^\n]*)") do
		owner[key] = value
	end
	return owner
end

local function owner_is_stale(root)
	local owner = read_owner(root)
	if not owner then
		-- no owner file: either the holder is mid-write or it died on startup
		local info = utils.file_info(lock_dir_of(root))
		return info ~= nil and (os.time() - (info.mtime or os.time())) > 10, "lock without an owner file"
	end
	if tostring(owner.pid) == tostring(my_pid) then
		return true, "lock left behind by this instance"
	end
	if not pid_alive(owner.pid) then
		return true, string.format("owner pid %s is gone", tostring(owner.pid))
	end

	local max_age = tonumber(options.queue_stale_timeout) or 0
	local started = tonumber(owner.started) or 0
	if max_age > 0 and started > 0 and (os.time() - started) > max_age then
		return true, "owner exceeded queue_stale_timeout"
	end

	return false
end

local function try_acquire(root, desc)
	local lock_dir = lock_dir_of(root)
	if not run({ "mkdir", "-p", root }) then
		return false
	end

	-- mkdir fails when the directory exists, so exactly one instance wins
	if not run({ "mkdir", lock_dir }) then
		return false
	end

	write_text(
		join_paths(lock_dir, "owner"),
		string.format(
			"pid=%s\nhost=%s\nwhat=%s\nstarted=%d\n",
			tostring(my_pid),
			my_host,
			(desc or "cut job"):gsub("\n", " "),
			os.time()
		)
	)
	return true
end

local function lock_holder_desc(root)
	local owner = read_owner(root)
	if not owner then
		return nil
	end

	local what = owner.what or "a cut job"
	if owner.host and owner.host ~= my_host then
		what = what .. " on " .. owner.host
	end
	return what
end

local function release_lock(root)
	local owner = read_owner(root)

	-- never remove a lock that a newer instance took over from us
	if owner and owner.pid and tostring(owner.pid) ~= tostring(my_pid) then
		return
	end

	remove_dir(lock_dir_of(root))
end

local function release_job_lock(job)
	if job and job.held then
		job.held = false
		release_lock(job.root)
	end
end

local function list_tickets(queue_dir)
	local entries = utils.readdir(queue_dir)
	if not entries then
		return {}
	end
	table.sort(entries)
	return entries
end

-- tickets whose instance is gone would otherwise block the queue forever
local function prune_tickets(queue_dir, entries)
	for _, name in ipairs(entries) do
		local pid = tonumber(name:match("%-(%d+)$"))
		if pid and not pid_alive(pid) then
			os.remove(join_paths(queue_dir, name))
		end
	end
end

-- nanosecond wall clock from date(1) keeps tickets ordered across processes
local function new_ticket(root)
	local stamp
	local res = utils.subprocess({
		args = { "date", "+%s%N" },
		cancellable = false,
		capture_stdout = true,
		capture_stderr = true,
	})
	local out = res and res.stdout and res.stdout:gsub("%s+$", "") or ""
	if res and res.status == 0 and out:match("^%d+$") then
		stamp = out
	else
		stamp = string.format("%d%09d", os.time(), 0)
	end

	return join_paths(join_paths(root, "queue"), string.format("%s-%08d", stamp, my_pid))
end

-- scratch dirs named "<pid>-<id>" from dead instances are safe to drop
local function prune_scratch(base)
	local entries = utils.readdir(base)
	if not entries then
		return
	end

	for _, name in ipairs(entries) do
		local pid = tonumber(name:match("^(%d+)%-"))
		if pid and not pid_alive(pid) then
			msg.warn("Removing stale cut scratch dir: " .. name)
			remove_dir(join_paths(base, name))
		end
	end
end

-- defined with the job runner below; the queue hands off to it
local begin_job

local function enqueue_job(job)
	local root = job.root
	local queue_dir = join_paths(root, "queue")

	if not run({ "mkdir", "-p", queue_dir }) then
		msg.warn("Could not create the cut queue, running without serialisation")
		begin_job(job)
		return
	end

	local ticket = new_ticket(root)
	job.ticket = ticket
	job.queued_at = os.time()
	write_text(ticket, string.format("pid=%s\nhost=%s\nwhat=%s\n", tostring(my_pid), my_host, job.desc))

	local interval = math.max(0.25, tonumber(options.queue_poll_interval) or 2)
	local announced = false

	local function poll()
		if active_job ~= job then
			-- cancelled or the player is shutting down
			os.remove(ticket)
			return
		end

		local entries = list_tickets(queue_dir)
		prune_tickets(queue_dir, entries)

		local waiting = {}
		for _, name in ipairs(entries) do
			if utils.file_info(join_paths(queue_dir, name)) then
				table.insert(waiting, name)
			end
		end

		local position = 0
		for i, name in ipairs(waiting) do
			if name == ticket:match("[^/]+$") then
				position = i
				break
			end
		end

		if position == 0 then
			-- ticket was pruned or removed: re-create it so the job is not lost
			write_text(ticket, string.format("pid=%s\nhost=%s\nwhat=%s\n", tostring(my_pid), my_host, job.desc))
			position = #waiting + 1
		end

		if position == 1 then
			local stale, why = owner_is_stale(root)
			if stale then
				msg.warn("Taking over stale cut lock: " .. tostring(why))
				remove_dir(lock_dir_of(root))
			end

			if try_acquire(root, job.desc) then
				os.remove(ticket)
				job.ticket = nil
				job.held = true
				if not announced and os.time() - job.queued_at > 5 then
					announced = true
					notify("Cut started", job.desc)
				end
				begin_job(job)
				return
			end
		end

		local max_wait = tonumber(options.queue_max_wait) or 0
		local waited = os.time() - job.queued_at
		if max_wait > 0 and waited > max_wait then
			os.remove(ticket)
			job.ticket = nil
			active_job = nil
			log(string.format("Cut cancelled: still queued after %ds", waited))
			notify("Cut cancelled", job.desc .. "\nstill queued after " .. waited .. "s", "critical")
			return
		end

		local holder = lock_holder_desc(root) or "another mpv instance"
		mp.osd_message(
			string.format("Cut queued (%d of %d): %s", position, math.max(#waiting, position), holder),
			math.max(3, interval + 1)
		)

		mp.add_timeout(interval, poll)
	end

	local holder = lock_holder_desc(root)
	log(string.format("Cut queued: %s is already running", holder or "another mpv instance"))
	poll()
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

-- Snapshot everything the job needs at keypress time. A queued job may not
-- start for minutes and end-file wipes `cuts` the moment playback moves on.
local job_seq = 0

local function build_job()
	if #cuts == 0 or not cuts[#cuts].end_time then
		log("No complete cuts to render")
		return nil
	end

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
		return nil
	end

	local filename_noext, ext

	if not is_stream then
		filename_noext, ext = filename:match("^(.*)(%.[^%.]+)$")
		if not filename_noext then
			-- default to mkv if no extension, cause ffmpeg needs one
			filename_noext, ext = filename, ".mkv"
		end
	else
		filename_noext = sanitize_filename(mp.get_property("media-title"))
		ext = ".mkv"
	end

	-- outputs keep the source's own filename
	local out_path = join_paths(outdir, filename_noext .. ext)

	if not is_stream and out_path == input then
		local err = "refusing to overwrite the source file"
		log(err)
		notify("Cut failed", err, "critical")
		return nil
	end

	-- copy the cut list, already sorted, so later edits cannot change this job
	local snapshot = {}
	for _, cut in ipairs(cuts) do
		table.insert(snapshot, { start_time = cut.start_time, end_time = cut.end_time })
	end
	table.sort(snapshot, function(a, b)
		return a.start_time < b.start_time
	end)

	local mtime = input_info and input_info.mtime or nil
	local cache_offset = 0
	local cache_file

	if is_stream then
		-- grab the stream data now: waiting in the queue would let the demuxer
		-- cache expire and the job would have nothing left to cut
		cache_file = join_paths(outdir, string.format("cache-dump-%d.mkv", my_pid))
		local offset = dump_cache(cache_file)
		if not offset then
			log("Failed to dump stream cache")
			delete_file(cache_file)
			return nil
		end
		cache_offset = offset
		local cache_info = utils.file_info(cache_file)
		mtime = cache_info and cache_info.mtime or mtime
	end

	job_seq = job_seq + 1
	local do_merge = #snapshot > 1 and options.multi_cut_mode == "merge"

	return {
		id = job_seq,
		input = cache_file or input,
		source = input,
		filename = filename,
		filename_noext = filename_noext,
		ext = ext,
		outdir = outdir,
		out_path = out_path,
		mtime = mtime,
		cache_offset = cache_offset,
		cache_file = cache_file,
		is_stream = is_stream,
		cuts = snapshot,
		num_cuts = #snapshot,
		desc = string.format(
			'%s "%s" (%d cut%s)',
			do_merge and "merging" or "cutting",
			filename or filename_noext,
			#snapshot,
			#snapshot == 1 and "" or "s"
		),
	}
end

local function run_job(job)
	log("Rendering cuts...")

	local num_cuts = job.num_cuts
	local do_merge = num_cuts > 1 and options.multi_cut_mode == "merge"
	local outdir = job.outdir
	local out_path = job.out_path
	local filename_noext = job.filename_noext
	local ext = job.ext
	local input = job.input
	local mtime = job.mtime
	local cache_offset = job.cache_offset

	-- merge segments go to a per-job scratch dir so neither a crashed run nor
	-- a concurrent instance can poison this one
	local seg_base = join_paths(outdir, ".mpv-cut-tmp")
	local seg_dir = outdir
	if do_merge then
		prune_scratch(seg_base)
		seg_dir = join_paths(seg_base, string.format("%d-%d", my_pid, job.id))
		if not ensure_directory_exists(seg_dir) then
			local err = "failed to create temporary directory"
			log(err)
			notify("Cut failed", err, "critical")
			return
		end
	end

	local rendered = {}

	for i, cut in ipairs(job.cuts) do
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
		-- leave no empty scratch dir behind in the destination
		run({ "rmdir", seg_base })
	end

	-- the output is final (or the job is over): let the next instance start,
	-- even though the source delete below still has retries to chew through
	release_job_lock(job)

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
		if not job.is_stream then
			local source = job.source
			local do_delete = options.delete_source and source and source ~= success_path

			local function finish()
				if options.quit_after_cut then
					quit_mpv()
				end
			end

			if do_delete then
				-- Unload the source first: a share can keep refusing the
				-- unlink (or only complete it on close) while mpv still has
				-- the file open, and the demuxer readahead keeps the share
				-- busy. Only safe to stop playback when we are quitting anyway.
				if options.quit_after_cut then
					mp.commandv("stop")
				end

				delete_source(source, function(err)
					if err then
						msg.error("Could not delete source " .. source .. ": " .. tostring(err))
						notify("Source not deleted", source .. "\n" .. tostring(err), "critical")
					end
					finish()
				end)
			else
				finish()
			end
		end
	end
end

-- a queued job runs through here; the pcall guarantees the lock is dropped
-- even if ffmpeg handling throws
begin_job = function(job)
	active_job = job

	local ok, err = pcall(run_job, job)
	if not ok then
		msg.error("Cut job crashed: " .. tostring(err))
		notify("Cut failed", tostring(err), "critical")
	end

	release_job_lock(job)

	if job.cache_file then
		delete_file(job.cache_file)
	end

	if active_job == job then
		active_job = nil
	end
end

local function request_cut()
	if active_job then
		log("Cut job already in progress")
		return
	end

	local job = build_job()
	if not job then
		return
	end

	active_job = job

	if not options.queue_enabled then
		job.held = false
		begin_job(job)
		return
	end

	job.root = queue_root(job.outdir)
	enqueue_job(job)
end

-- seekbar markers ------------------------------------------------------------
-- mpv has no native way to draw a range on the seekbar, but the builtin OSC
-- and uosc both render chapter markers there, so temporary chapters are the
-- portable way to show where the cut points are. The file's own chapters are
-- kept and restored.

local base_chapters = nil

local function capture_base_chapters()
	if base_chapters then
		return
	end

	base_chapters = {}
	for _, chapter in ipairs(mp.get_property_native("chapter-list") or {}) do
		table.insert(base_chapters, { title = chapter.title, time = chapter.time })
	end
end

local function sync_markers()
	if not options.show_cut_markers then
		return
	end

	capture_base_chapters()

	local list = {}
	for _, chapter in ipairs(base_chapters) do
		table.insert(list, { title = chapter.title, time = chapter.time })
	end

	for i, cut in ipairs(cuts) do
		if cut.start_time then
			table.insert(list, {
				title = string.format("%s %d start", options.cut_marker_prefix, i),
				time = cut.start_time,
			})
		end
		if cut.end_time then
			table.insert(list, {
				title = string.format("%s %d end", options.cut_marker_prefix, i),
				time = cut.end_time,
			})
		end
	end

	table.sort(list, function(a, b)
		return a.time < b.time
	end)

	mp.set_property_native("chapter-list", list)
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

	sync_markers()
end

local function cut_set_start(start_time)
	local last_cut = cuts[#cuts]

	if not last_cut or last_cut.end_time then
		-- a start that falls before an existing segment's end would render two
		-- overlapping cuts, which is almost never what was intended
		local blocking, blocking_index
		for index, cut in ipairs(cuts) do
			if cut.end_time and start_time < cut.end_time then
				blocking, blocking_index = cut, index
				break
			end
		end

		if blocking then
			log(string.format(
				"[cut %d] start %.2fs overlaps cut %d (%.2fs-%.2fs)",
				#cuts + 1,
				start_time,
				blocking_index,
				blocking.start_time,
				blocking.end_time
			))
			return
		end

		local new_cut = { start_time = start_time }
		table.insert(cuts, new_cut)
		log(string.format("[cut %d] Set start time: %.2fs", #cuts, start_time))
	else
		last_cut.start_time = start_time
		log(string.format("[cut %d] Updated start time: %.2fs", #cuts, start_time))
	end

	sync_markers()
end

local function cut_set_end(end_time)
	if #cuts == 0 then
		log("No start point found")
		return
	end

	local cut = cuts[#cuts]
	if cut.start_time and end_time <= cut.start_time then
		log(string.format(
			"[cut %d] end %.2fs is not after the start at %.2fs",
			#cuts,
			end_time,
			cut.start_time
		))
		return
	end

	local had_end_time = cut.end_time ~= nil

	cut.end_time = end_time
	log(string.format("[cut %d] %s end time: %.2fs", #cuts, had_end_time and "Updated" or "Set", end_time))

	sync_markers()
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

mp.add_key_binding("r", "cut_render", request_cut)

mp.register_event("end-file", function()
	cut_clear(true)
	-- the next file gets its own chapters; never carry markers across
	base_chapters = nil
end)

-- never leave a ticket or a lock behind when the player goes away
mp.register_event("shutdown", function()
	local job = active_job
	if not job then
		return
	end
	if job.ticket then
		os.remove(job.ticket)
		job.ticket = nil
	end
	release_job_lock(job)
end)

print("mpv-lossless-cut loaded")
