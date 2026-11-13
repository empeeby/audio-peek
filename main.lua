--- audio-peek.yazi
--- Preview audio files in yazi: a combined waveform + spectrogram image plus a
--- metadata panel.
---
--- A fork of gesellkammer/audio-preview.yazi (MIT). See LICENSE and README.md.
---
--- Requirements: sox + ffmpeg (image) and, optionally, mediainfo (metadata panel).

local M = {}

-- ── Tunables ────────────────────────────────────────────────────────────────
-- Waveform colour (any ffmpeg colour spec, e.g. "#ff33dd" or "cyan").
local WAVEFORM_COLOR = "#ff33dd"
-- Combined spectrogram height in px, shared across channels (each channel gets
-- roughly SPECTROGRAM_HEIGHT / channels so the total stays constant).
local SPECTROGRAM_HEIGHT = 275
-- Every rendered image is scaled to exactly this size (sox's output width and
-- height drift a few px with duration/channel count). A fixed size lets a blank
-- placeholder of the same size reserve the image's space while it renders.
local IMAGE_W, IMAGE_H = 800, SPECTROGRAM_HEIGHT + 240
-- Seconds to wait on an *uncached* file before rendering starts, so holding a
-- key to scroll doesn't spawn a render per file passed. Cached previews show
-- immediately.
local DEBOUNCE = 0.05
-- How much audio to decode, by file duration (seconds). The audio is decoded
-- once to a small 12 kHz wav that both the spectrogram and waveform are drawn
-- from. `full` decodes everything (~0.1s per minute of audio); otherwise
-- `count` snippets of `length` seconds, evenly spaced, are decoded and stitched
-- together (each snippet is a seek, ~7ms apiece, independent of file length).
-- First matching level wins; files of unknown duration are decoded in full.
-- `direct` skips the intermediate wav: for very short files the extra ffmpeg
-- startup costs more than decoding the file twice.
local LEVELS = {
	{ max = 30, full = true, direct = true },
	{ max = 120, full = true },
	{ max = 600, count = 32, length = 1 },
	{ max = math.huge, count = 64, length = 0.5 },
}
-- Sample rate of the intermediate wav (the spectrogram shows 0 - rate/2 Hz).
local DECODE_RATE = 12000

-- External tools required for the image preview. `mediainfo` is optional and is
-- handled separately (its absence just hides the metadata panel).
local REQUIRED_TOOLS = { "sox", "ffmpeg" }

-- Fields to extract from mediainfo output, in display order.
-- lossy_only fields are suppressed for lossless/uncompressed formats.
local FIELDS = {
	{ key = "Duration", section = "General" },
	{ key = "File size", section = "General" },
	{ key = "Channel(s)", section = "Audio" },
	{ key = "Format", section = "Audio" },
	{ key = "Format profile", section = "Audio" },
	{ key = "Sampling rate", section = "Audio" },
	{ key = "Bit depth", section = "Audio" },
	{ key = "Bit rate mode", section = "Audio", lossy_only = true },
	{ key = "Bit rate", section = "Audio", lossy_only = true },
	{ key = "Overall bit rate", section = "General", lossy_only = true },
}

-- Memoised list of missing required tools. A tool is "missing" when it can't be
-- spawned at all (`:output()` returns nil); a bad exit status still counts as
-- present, so the probe flag doesn't need to be valid for every tool.
local _missing
local function missing_tools()
	if _missing then
		return _missing
	end
	local missing = {}
	for _, bin in ipairs(REQUIRED_TOOLS) do
		local out = Command(bin):arg({ "--version" }):output()
		if not out then
			table.insert(missing, bin)
		end
	end
	_missing = missing
	return missing
end

-- Returns { {key, value}, ... } (plain data: yazi consumes ui.Line objects when
-- they're rendered, so they're rebuilt on every render).
local function get_meta_lines(file_url)
	local out, _ = Command("mediainfo"):arg({ tostring(file_url) }):output()
	if not out or out.stdout == "" then
		return {}
	end

	local section = nil
	local values = {}
	for line in out.stdout:gmatch("[^\n]+") do
		if line == "General" or line == "Audio" then
			section = line
		else
			local k, v = line:match("^(.-)%s+: (.+)$")
			if k and v and section then
				local key = section .. "/" .. k
				if not values[key] then
					values[key] = v
				end
			end
		end
	end

	local is_lossy = values["Audio/Compression mode"] == "Lossy"

	local lines = {}
	for _, f in ipairs(FIELDS) do
		if not f.lossy_only or is_lossy then
			local v = values[f.section .. "/" .. f.key]
			if v then
				table.insert(lines, { f.key, v })
			end
		end
	end
	return lines
end

-- Duration in seconds (from the container header, so it's cheap), or nil.
local function get_duration(path)
	local out = Command("mediainfo"):arg({ "--Inform=General;%Duration%", path }):output()
	local ms = out and tonumber(out.stdout:match("[%d%.]+"))
	return ms and ms / 1000 or nil
end

-- Run a command to completion; returns true or false + a short error message.
local function run(cmd, args)
	local out, err = Command(cmd):arg(args):output()
	if not out then
		return false, "spawn " .. cmd .. ": " .. tostring(err)
	end
	if not out.status.success then
		local msg = out.stderr:match("[^\n]+") or ("exit " .. tostring(out.status.code))
		return false, cmd .. ": " .. msg
	end
	return true
end

local function level_for(duration)
	if not duration then
		return { full = true }
	end
	for _, l in ipairs(LEVELS) do
		if duration <= l.max then
			return l
		end
	end
	return { full = true }
end

-- Ffmpeg args that decode `src` (whole, or the level's snippets) into a small
-- wav at DECODE_RATE. Snippets: each is its own input that seeks first, so only
-- the snippets are decoded. fastseek + a tiny probe keep each input cheap (mp3
-- seeking otherwise scans, and wav probing reads megabytes per input).
local function decode_args(src, duration, level, out)
	local args = { "-v", "error", "-y" }
	local function push(...)
		for _, a in ipairs({ ... }) do
			table.insert(args, a)
		end
	end

	if level.full then
		push("-i", src)
	else
		local labels = {}
		local step = duration / level.count
		for i = 0, level.count - 1 do
			local at = math.max(0, (i + 0.5) * step - level.length / 2)
			push(
				"-fflags",
				"+fastseek",
				"-probesize",
				"32",
				"-analyzeduration",
				"0",
				"-ss",
				string.format("%.3f", at),
				"-t",
				tostring(level.length),
				"-i",
				src
			)
			table.insert(labels, "[" .. i .. ":a]")
		end
		push("-filter_complex", table.concat(labels) .. "concat=n=" .. level.count .. ":v=0:a=1[o]", "-map", "[o]")
	end
	push("-ar", tostring(DECODE_RATE), out)
	return args
end

-- Render the waveform + spectrogram image for `src` into `combo`. Everything is
-- written to temp files and the final image is renamed into place, so a render
-- cancelled half-way (hover moved on) never leaves a truncated cache entry.
local function generate(src, cache, duration, level)
	local base = tostring(cache)
	local spec_tmp = base .. ".spec.tmp.png"
	local combo_tmp = base .. ".combo.tmp.png"
	local sample_tmp = base .. ".sample.wav"

	local function cleanup()
		for _, p in ipairs({ spec_tmp, combo_tmp, sample_tmp }) do
			fs.remove("file", Url(p))
		end
	end

	local input, ok, err = src, nil, nil
	if not level.direct then
		ok, err = run("ffmpeg", decode_args(src, duration, level, sample_tmp))
		if not ok then
			cleanup()
			return false, err
		end
		input = sample_tmp
	end

	local out = Command("soxi"):arg({ "-c", input }):output()
	local channels = out and tonumber(out.stdout:match("%d+")) or 1
	-- sox needs >= 64px per channel; the final scale to IMAGE_H absorbs any excess.
	local spec_h = math.max(64, SPECTROGRAM_HEIGHT // channels)

	-- `rate` is a no-op on the already-resampled intermediate wav.
	ok, err = run(
		"sox",
		{ input, "-n", "rate", tostring(DECODE_RATE), "spectrogram", "-r", "-y", tostring(spec_h), "-o", spec_tmp }
	)
	if not ok then
		cleanup()
		return false, err
	end

	ok, err = run("ffmpeg", {
		"-v",
		"error",
		"-i",
		input,
		"-i",
		spec_tmp,
		"-filter_complex",
		"[1:v]format=rgba,pad=w=iw:h=ih+240:x=0:y=240:color=black[specpad];"
			.. "[0:a]showwavespic=s=640x240:split_channels=1:colors="
			.. WAVEFORM_COLOR
			.. "[wave0];"
			.. "[wave0][specpad]scale2ref=w=rw:h=240[wave][specpad2];"
			.. "[wave]colorkey=0xffffff:0.15:0.05[wavekey];"
			.. "[specpad2][wavekey]overlay=0:0,scale="
			.. IMAGE_W
			.. ":"
			.. IMAGE_H
			.. "[combo]",
		"-map",
		"[combo]",
		"-frames:v",
		"1",
		"-y",
		combo_tmp,
	})
	if not ok then
		cleanup()
		return false, err
	end

	ok, err = fs.rename(Url(combo_tmp), Url(base .. ".combo.png"))
	cleanup()
	if not ok then
		return false, "rename: " .. tostring(err)
	end
	return true
end

-- A fully transparent IMAGE_W x IMAGE_H png, created once next to the cache.
-- Shown while the real image renders so yazi lays out (and the metadata lands)
-- exactly where it will be once the real image replaces it. Never drawing text
-- in the image's area also matters: yazi doesn't track image cells, so blanking
-- text there after the image appears would punch holes in it.
local function placeholder(cache)
	local dir = tostring(cache):match("^(.*)/")
	if not dir then
		return nil
	end
	local url = Url(string.format("%s/audio-peek-placeholder-%dx%d.png", dir, IMAGE_W, IMAGE_H))
	if fs.cha(url) then
		return url
	end
	local tmp = tostring(url) .. ".tmp.png"
	local ok = run("ffmpeg", {
		"-v",
		"error",
		"-y",
		"-f",
		"lavfi",
		"-i",
		string.format("color=black@0.0:s=%dx%d,format=rgba", IMAGE_W, IMAGE_H),
		"-frames:v",
		"1",
		tmp,
	})
	if not (ok and fs.rename(Url(tmp), url)) then
		return nil
	end
	return url
end

-- Draw the preview: the image (if any) on top, then the metadata panel, then an
-- optional status line (so the metadata doesn't move when the status goes away).
local function render(job, img, meta, status)
	local area = job.area
	local y = area.y
	if img then
		local r = ya.image_show(img, ui.Rect({ x = area.x, y = y, w = area.w, h = area.h - #meta }))
		y = y + (r and r.h or 0)
	end

	local lines = {}
	for _, kv in ipairs(meta) do
		table.insert(lines, ui.Line({ ui.Span(kv[1] .. ": "):style(ui.Style():bold()), ui.Span(kv[2]) }))
	end
	if status then
		table.insert(lines, ui.Line(""))
		table.insert(lines, ui.Line(status):style(ui.Style():italic()))
	end

	if #lines == 0 then
		ya.preview_widget(job, {})
	else
		ya.preview_widget(job, {
			ui.Text(lines):area(ui.Rect({ x = area.x, y = y, w = area.w, h = area.y + area.h - y })),
		})
	end
end

-- Rendering happens here, only for the hovered file. Yazi aborts a peek when
-- the hover moves on (killing any sox/ffmpeg it spawned), so browsing a big
-- folder no longer queues a render for every file in it.
function M:peek(job)
	-- If the tools needed to render the image are missing, tell the user instead
	-- of silently showing a blank preview.
	local missing = missing_tools()
	if #missing > 0 then
		ya.preview_widget(job, {
			ui.Text({
				ui.Line("audio-peek: missing required tool(s):"):style(ui.Style():bold()),
				ui.Line(table.concat(missing, ", ")),
				ui.Line(""),
				ui.Line("Install them to enable audio previews."),
			}):area(job.area),
		})
		return
	end

	local src = tostring(job.file.url)
	-- skip = 0: the image doesn't depend on scroll position, so one cache entry per file.
	local cache = ya.file_cache({ file = job.file, skip = 0 })
	local combo = cache and Url(tostring(cache) .. ".combo.png")
	local cha = combo and fs.cha(combo)
	local cached = cha and cha.len > 0

	if cache and not cached then
		ya.sleep(DEBOUNCE)
	end

	local meta = get_meta_lines(job.file.url)
	local duration = get_duration(src)
	local level = level_for(duration)

	if not cache then
		return render(job, nil, meta)
	end

	if not cached then
		render(job, placeholder(cache), meta, level.full and "Rendering preview…" or "Rendering sampled preview…")
		local ok, err = generate(src, cache, duration, level)
		if not ok then
			ya.err("audio-peek: " .. tostring(err))
			return render(job, nil, meta, "audio-peek: " .. tostring(err))
		end
	end

	render(job, combo, meta)
end

-- The preview is a single static image; scrolling has nothing to reveal.
function M:seek() end

-- Intentionally does nothing: rendering on preload ran sox/ffmpeg for every
-- audio file in a directory at once. Kept so an existing `prepend_preloaders`
-- entry for this plugin stays harmless; it can be removed from yazi.toml.
function M:preload()
	return true
end

return M
