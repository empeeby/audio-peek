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

-- External tools required for the image preview. `mediainfo` is optional and is
-- handled separately (its absence just hides the metadata panel).
local REQUIRED_TOOLS = { "sox", "ffmpeg" }

-- Fields to extract from mediainfo output, in display order.
-- lossy_only fields are suppressed for lossless/uncompressed formats.
local FIELDS = {
  { key = "Duration",         section = "General" },
  { key = "File size",        section = "General" },
  { key = "Channel(s)",       section = "Audio" },
  { key = "Format",           section = "Audio" },
  { key = "Format profile",   section = "Audio" },
  { key = "Sampling rate",    section = "Audio" },
  { key = "Bit depth",        section = "Audio" },
  { key = "Bit rate mode",    section = "Audio",   lossy_only = true },
  { key = "Bit rate",         section = "Audio",   lossy_only = true },
  { key = "Overall bit rate", section = "General", lossy_only = true },
}

-- Memoised list of missing required tools. A tool is "missing" when it can't be
-- spawned at all (`:output()` returns nil); a bad exit status still counts as
-- present, so the probe flag doesn't need to be valid for every tool.
local _missing
local function missing_tools()
  if _missing then return _missing end
  local missing = {}
  for _, bin in ipairs(REQUIRED_TOOLS) do
    local out = Command(bin):arg({ "--version" }):output()
    if not out then table.insert(missing, bin) end
  end
  _missing = missing
  return missing
end

local function get_meta_lines(file_url)
  local out, _ = Command("mediainfo"):arg({ tostring(file_url) }):output()
  if not out or out.stdout == "" then return {} end

  local section = nil
  local values = {}
  for line in out.stdout:gmatch("[^\n]+") do
    if line == "General" or line == "Audio" then
      section = line
    else
      local k, v = line:match("^(.-)%s+: (.+)$")
      if k and v and section then
        local key = section .. "/" .. k
        if not values[key] then values[key] = v end
      end
    end
  end

  local is_lossy = values["Audio/Compression mode"] == "Lossy"

  local lines = {}
  for _, f in ipairs(FIELDS) do
    if not f.lossy_only or is_lossy then
      local v = values[f.section .. "/" .. f.key]
      if v then
        table.insert(lines, ui.Line({
          ui.Span(f.key .. ": "):style(ui.Style():bold()),
          ui.Span(v),
        }))
      end
    end
  end
  return lines
end

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

  local start, cache = os.clock(), ya.file_cache(job)
  if not cache or self:preload() ~= 1 then return end
  ya.sleep(math.max(0, 0.1 + start - os.clock()))

  local combo_cache = Url(tostring(cache) .. ".combo.png")
  local area = job.area
  local meta = get_meta_lines(job.file.url)
  local meta_h = #meta
  local available_h = area.h - meta_h

  local y = area.y

  -- Waveform stacked above the spectrogram in one combined image: yazi
  -- only remembers one shown image rect, so a second ya.image_show call
  -- would hide the first.
  if fs.cha(combo_cache) then
    local r = ya.image_show(combo_cache, ui.Rect({ x = area.x, y = y, w = area.w, h = available_h }))
    y = y + (r and r.h or 0)
  end

  local total_img_h = y - area.y
  if meta_h > 0 then
    ya.preview_widget(job, {
      ui.Text(meta):area(ui.Rect({
        x = area.x,
        y = area.y + total_img_h,
        w = area.w,
        h = area.h - total_img_h,
      })),
    })
  else
    ya.preview_widget(job, {})
  end
end

function M:seek(job, units)
  local h = cx.active.current.hovered
  if h and h.url == job.file.url then
    local step = ya.clamp(-1, units, 1)
    ya.emit("peek", { math.max(0, cx.active.preview.skip + step), only_if = job.file.url })
  end
end

function M:preload(job)
  if not job then return 1 end

  -- Nothing to generate if the required tools aren't installed; peek() reports
  -- the problem to the user.
  if #missing_tools() > 0 then return 1 end

  local percentage = 5 + job.skip
  if percentage > 95 then
    ya.emit("peek", { 90, only_if = job.file.url, upper_bound = true })
    return 2
  end

  local cache = ya.file_cache(job)
  if not cache then return 1 end

  local combo_cache = Url(tostring(cache) .. ".combo.png")
  local spec_cha = fs.cha(cache)
  local combo_cha = fs.cha(combo_cache)
  local spec_ok = spec_cha and spec_cha.len > 0
  local combo_ok = combo_cha and combo_cha.len > 0

  if spec_ok and combo_ok then return 1 end

  if not spec_ok then
    local out, _ = Command("soxi"):arg({ "-c", tostring(job.file.url) }):output()
    local channels = out and tonumber(out.stdout:match("%d+")) or 1
    local spec_h = math.max(1, SPECTROGRAM_HEIGHT // channels)

    local child, code = Command("sox")
        :arg({ tostring(job.file.url),
          "-n", "rate", "12k",
          "spectrogram", "-r", "-y", tostring(spec_h), "-o", tostring(cache) })
        :spawn()
    if not child then
      ya.err("spawn sox: " .. tostring(code))
      return 0
    end
    local status = child:wait()
    if not (status and status.success) then return 2 end
  end

  if not combo_ok then
    local child, code = Command("ffmpeg")
        :arg({ "-v", "error",
          "-i", tostring(job.file.url),
          "-i", tostring(cache),
          "-filter_complex",
          "[1:v]format=rgba,pad=w=iw:h=ih+240:x=0:y=240:color=black[specpad];" ..
          "[0:a]showwavespic=s=640x240:split_channels=1:colors=" .. WAVEFORM_COLOR .. "[wave0];" ..
          "[wave0][specpad]scale2ref=w=rw:h=240[wave][specpad2];" ..
          "[wave]colorkey=0xffffff:0.15:0.05[wavekey];" ..
          "[specpad2][wavekey]overlay=0:0[combo]",
          "-map", "[combo]",
          "-frames:v", "1", "-y",
          tostring(combo_cache) })
        :spawn()
    if not child then
      ya.err("spawn ffmpeg: " .. tostring(code))
      return 0
    end
    local status = child:wait()
    if not (status and status.success) then return 2 end
  end

  return 1
end

return M
