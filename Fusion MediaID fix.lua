--[[
Fusion MediaIn ID Update v2 — DaVinci Resolve (Lua)
PostFlows toolkit — https://github.com/postflows

Fixes "Media Offline" inside Fusion compositions after a timeline or project
is moved to another project. MediaIn nodes reference Media Pool clips by
Media ID, and those IDs are project-specific. This script finds every MediaIn
that points to the Media Pool and re-links it to the matching clip of the
current project.

What it scans:
  - Fusion compositions of timeline clips (all comps, not only the first)
  - Fusion effects applied to clips, including Adjustment Clips
    (requires DaVinci Resolve 21.1.2+, older versions skip this part)
  - the current timeline or all timelines of the project

How a clip is matched (first hit wins):
  1. Media ID still exists in the pool  -> nothing to do
  2. same file path                      -> re-link
  3. same clip name / file name, unique  -> re-link
  4. file still exists on disk           -> import into a bin, then re-link

Only MediaIn nodes with MediaSource = "MediaPool" are touched. The built-in
input of a clip or effect (MediaSource = "Timeline") is never modified.
--]]

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local CONFIG = {
    ALL_TIMELINES   = true,   -- false: current timeline only
    INCLUDE_EFFECTS = true,   -- scan Fusion effects on clips (Resolve 21.1.2+)
    IMPORT_MISSING  = true,   -- import files missing from the pool by their stored path
    IMPORT_BIN      = "Fusion MediaIn Restored",
    DRY_RUN         = false,  -- true: report only, change nothing
}

-- Optional override from a wrapper script
if type(PF_MEDIAIN_FIX_CONFIG) == "table" then
    for k, v in pairs(PF_MEDIAIN_FIX_CONFIG) do CONFIG[k] = v end
end

local resolve = resolve or (Resolve and Resolve())

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function norm_path(p)
    if type(p) ~= "string" then return "" end
    return (p:gsub("\\", "/"))
end

local function basename(p)
    return (norm_path(p):match("([^/]+)$")) or ""
end

local function file_exists(path)
    if path == nil or path == "" then return false end
    if bmd and bmd.fileexists then
        local ok, res = pcall(bmd.fileexists, path)
        if ok then return res and true or false end
    end
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function clip_path(clip)
    local ok, v = pcall(function() return clip:GetClipProperty("File Path") end)
    if not ok then return "" end
    if type(v) == "table" then v = v["File Path"] end
    return norm_path(v or "")
end

local function frames_to_tc(frames, fps)
    fps = math.floor((tonumber(fps) or 25) + 0.5)
    if fps < 1 then fps = 25 end
    frames = math.floor(tonumber(frames) or 0)
    local f = frames % fps
    local s = math.floor(frames / fps)
    return string.format("%02d:%02d:%02d:%02d",
        math.floor(s / 3600), math.floor(s / 60) % 60, s % 60, f)
end

------------------------------------------------------------------------
-- Media Pool index
------------------------------------------------------------------------
local project   = resolve:GetProjectManager():GetCurrentProject()
local mediapool = project:GetMediaPool()

local pool = { byId = {}, byPath = {}, byName = {} }

local function add_name(name, id)
    if name == nil or name == "" then return end
    pool.byName[name] = pool.byName[name] or {}
    pool.byName[name][id] = true
end

local function index_clip(clip)
    local id = clip:GetMediaId()
    if id == nil or id == "" then return end
    pool.byId[id] = clip
    local path = clip_path(clip)
    if path ~= "" then
        pool.byPath[path] = id
        add_name(basename(path), id)
    end
    add_name(clip:GetName(), id)
end

local function index_folder(folder)
    for _, clip in ipairs(folder:GetClipList() or {}) do index_clip(clip) end
    for _, sub in ipairs(folder:GetSubFolderList() or {}) do index_folder(sub) end
end

local function unique_id(set)
    if not set then return nil, 0 end
    local found, n = nil, 0
    for id in pairs(set) do found = id; n = n + 1 end
    if n == 1 then return found, 1 end
    return nil, n
end

------------------------------------------------------------------------
-- Import of missing files
------------------------------------------------------------------------
local import_bin = nil
local imported   = {}   -- path -> new media id (or false on failure)

local function get_import_bin()
    if import_bin then return import_bin end
    local root = mediapool:GetRootFolder()
    for _, sub in ipairs(root:GetSubFolderList() or {}) do
        if sub:GetName() == CONFIG.IMPORT_BIN then import_bin = sub return sub end
    end
    import_bin = mediapool:AddSubFolder(root, CONFIG.IMPORT_BIN)
    return import_bin
end

local function import_file(path)
    if imported[path] ~= nil then return imported[path] or nil end
    local bin = get_import_bin()
    local prev = mediapool:GetCurrentFolder()
    if bin then mediapool:SetCurrentFolder(bin) end
    local items = mediapool:ImportMedia({ path })
    if prev then mediapool:SetCurrentFolder(prev) end
    local clip = items and items[1]
    if clip then
        index_clip(clip)
        imported[path] = clip:GetMediaId()
        return imported[path]
    end
    imported[path] = false
    return nil
end

------------------------------------------------------------------------
-- Matching
------------------------------------------------------------------------
-- returns status, new_id
-- status: ok | path | name | import | ambiguous | missing | import_failed
local function find_target(old_id, clip_name, path)
    if old_id ~= "" and pool.byId[old_id] then return "ok", old_id end

    path = norm_path(path)
    if path ~= "" and pool.byPath[path] then return "path", pool.byPath[path] end

    local id, n = unique_id(pool.byName[clip_name])
    if n == 0 and path ~= "" then id, n = unique_id(pool.byName[basename(path)]) end
    if n == 1 then return "name", id end
    if n > 1 then return "ambiguous", nil end

    if CONFIG.IMPORT_MISSING and file_exists(path) then
        if CONFIG.DRY_RUN then return "import", nil end
        local new_id = import_file(path)
        if new_id then return "import", new_id end
        return "import_failed", nil
    end
    return "missing", nil
end

------------------------------------------------------------------------
-- Scan
------------------------------------------------------------------------
local report = {
    counts = { ok = 0, path = 0, name = 0, import = 0,
               ambiguous = 0, missing = 0, import_failed = 0, set_failed = 0 },
    rows = {},
    effects_supported = nil,
    timelines = 0, items = 0, comps = 0,
}

local function process_comp(comp, where)
    report.comps = report.comps + 1
    local tools = comp:GetToolList(false, "MediaIn") or {}
    local undo_open = false

    for _, tool in pairs(tools) do
        local attrs  = tool:GetAttrs() or {}
        local source = tool:GetInput("MediaSource")
        local old_id = attrs.TOOLS_Clip_MediaID or ""

        local is_pool_ref = (source == "MediaPool") or (source == nil and old_id ~= "")
        if is_pool_ref then
            local name = attrs.TOOLS_Clip_Name or ""
            local path = attrs.TOOLS_Clip_Path or ""
            local status, new_id = find_target(old_id, name, path)

            if status ~= "ok" and new_id and not CONFIG.DRY_RUN then
                if not undo_open then comp:StartUndo("Fix MediaIn IDs"); undo_open = true end
                tool:SetInput("MediaID", new_id)
                local now = (tool:GetAttrs() or {}).TOOLS_Clip_MediaID
                if now ~= new_id then status = "set_failed" end
            end

            report.counts[status] = (report.counts[status] or 0) + 1
            if status ~= "ok" then
                table.insert(report.rows, {
                    status = status, where = where, tool = attrs.TOOLS_Name,
                    clip = name, path = path, old_id = old_id, new_id = new_id or "",
                })
            end
        end
    end

    if undo_open then comp:EndUndo(true) end
end

local function scan_timeline(tl)
    report.timelines = report.timelines + 1
    local tl_name = tl:GetName()
    local fps     = tl:GetSetting("timelineFrameRate")
    local start   = tl:GetStartFrame() or 0

    for ti = 1, tl:GetTrackCount("video") do
        for _, item in ipairs(tl:GetItemListInTrack("video", ti) or {}) do
            local ok_t, typ = pcall(function() return item:GetType() end)
            if not (ok_t and typ == "transition") then
                report.items = report.items + 1
                local base = string.format("%s | V%d | %s @ %s", tl_name, ti, item:GetName() or "?",
                                           frames_to_tc(item:GetStart() - start, fps))

                -- Fusion compositions of the clip
                local n = item:GetFusionCompCount() or 0
                for k = 1, n do
                    local comp = item:GetFusionCompByIndex(k)
                    if comp then process_comp(comp, base .. " | comp " .. k) end
                end

                -- Fusion effects (21.1.2+)
                if CONFIG.INCLUDE_EFFECTS and report.effects_supported ~= false then
                    local ok_e, effects = pcall(function() return item:GetEffects("fusion") end)
                    if ok_e and type(effects) == "table" then
                        report.effects_supported = true
                        for _, eff in ipairs(effects) do
                            local info = eff:GetInfo() or {}
                            local comp = eff:GetFusionComp()
                            if comp then process_comp(comp, base .. " | fx " .. (info.name or "?")) end
                        end
                    else
                        report.effects_supported = false
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- Run
------------------------------------------------------------------------
local LABELS = {
    path = "RELINKED (path)", name = "RELINKED (name)", import = "IMPORTED + RELINKED",
    ambiguous = "AMBIGUOUS NAME", missing = "MISSING", import_failed = "IMPORT FAILED",
    set_failed = "SET FAILED",
}

local function run()
    index_folder(mediapool:GetRootFolder())

    local timelines = {}
    if CONFIG.ALL_TIMELINES then
        for i = 1, project:GetTimelineCount() do table.insert(timelines, project:GetTimelineByIndex(i)) end
    else
        local tl = project:GetCurrentTimeline()
        if tl then table.insert(timelines, tl) end
    end
    if #timelines == 0 then print("[MediaIn Fix] No timeline to scan.") return end

    for _, tl in ipairs(timelines) do scan_timeline(tl) end

    local c = report.counts
    print("========================================")
    print("Fusion MediaIn ID Update v2" .. (CONFIG.DRY_RUN and "  [DRY RUN]" or ""))
    print("========================================")
    for _, r in ipairs(report.rows) do
        local label = LABELS[r.status] or r.status
        if CONFIG.DRY_RUN and r.status == "import" then label = "WOULD IMPORT" end
        print(string.format("\n%s\n  %s | %s\n  Clip: %s\n  Path: %s", label, r.where, r.tool, r.clip, r.path))
        if r.new_id ~= "" then print(string.format("  ID:   %s -> %s", r.old_id, r.new_id)) end
    end
    print("\n========================================")
    print(string.format("  Timelines / clips / comps: %d / %d / %d", report.timelines, report.items, report.comps))
    if report.effects_supported == false then
        print("  Fusion effects: not scanned (needs Resolve 21.1.2+)")
    end
    print(string.format("  Already OK:          %d", c.ok))
    print(string.format("  Relinked by path:    %d", c.path))
    print(string.format("  Relinked by name:    %d", c.name))
    print(string.format("  %-20s %d", CONFIG.DRY_RUN and "Would import:" or "Imported + relinked:", c.import))
    print(string.format("  Ambiguous name:      %d", c.ambiguous))
    print(string.format("  Missing file:        %d", c.missing))
    if c.import_failed + c.set_failed > 0 then
        print(string.format("  Failed:              %d", c.import_failed + c.set_failed))
    end
    print("========================================")
end

local ok, err = pcall(run)
if not ok then print("[MediaIn Fix] Critical error: " .. tostring(err)) end

PF_MEDIAIN_FIX_REPORT = report
PF_MEDIAIN_FIX_ERROR = (not ok) and tostring(err) or nil
return report
