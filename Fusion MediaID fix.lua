--[[
Fusion MediaIn ID Update — Lua version for DaVinci Resolve

Solves the issue of lost media files in Fusion compositions when transferring
projects: updates Media IDs of MediaIn nodes by matching file names against
the current project's MediaPool.
--]]

local function get_folder_clips(folder, mediapool_dict)
    local clips = folder:GetClipList()
    if clips then
        for _, clip in ipairs(clips) do
            local name     = clip:GetName()
            local media_id = clip:GetMediaId()
            if name and media_id then
                mediapool_dict[name] = media_id
            end
        end
    end

    local subfolders = folder:GetSubFolderList()
    if subfolders then
        for _, subfolder in ipairs(subfolders) do
            get_folder_clips(subfolder, mediapool_dict)
        end
    end
end

local function get_mediapool_files()
    local project     = resolve:GetProjectManager():GetCurrentProject()
    local mediapool   = project:GetMediaPool()
    local root_folder = mediapool:GetRootFolder()
    local mediapool_dict = {}
    get_folder_clips(root_folder, mediapool_dict)
    return mediapool_dict
end

local function update_media_ids()
    local ok, err = pcall(function()

        local mediapool_files = get_mediapool_files()

        print("========================================")
        print("MediaPool Files:")
        for name, id in pairs(mediapool_files) do
            print(string.format("  %s: %s", name, id))
        end
        print("========================================")

        local project  = resolve:GetProjectManager():GetCurrentProject()
        local timeline = project:GetCurrentTimeline()

        if not timeline then
            print("Error: failed to retrieve the current timeline.")
            return
        end

        local updates_count  = 0
        local skipped_count  = 0
        local notfound_count = 0
        local track_count    = timeline:GetTrackCount("video")

        for track_index = 1, track_count do
            local clips = timeline:GetItemListInTrack("video", track_index)

            if clips then
                for _, clip in ipairs(clips) do
                    local clip_ok, clip_err = pcall(function()

                        local fusion_comp = clip:GetFusionCompByIndex(1)
                        if not fusion_comp then return end

                        local tool_list = fusion_comp:GetToolList()
                        if not tool_list then return end

                        for _, tool in pairs(tool_list) do
                            if tool.Name and tool.Name:find("MediaIn") then
                                local attrs = tool:GetAttrs()
                                if not attrs then return end

                                local old_media_id = attrs["TOOLS_Clip_MediaID"] or ""
                                local file_name    = attrs["TOOLS_Clip_Name"]    or ""

                                if file_name == "" then return end

                                if mediapool_files[file_name] then
                                    local new_media_id = mediapool_files[file_name]

                                    if old_media_id == new_media_id then
                                        print(string.format("\n[%s] Info: Media ID is already up to date, skipping.", tool.Name))
                                        skipped_count = skipped_count + 1
                                    else
                                        print(string.format("\n[%s]", tool.Name))
                                        print(string.format("  File:       %s", file_name))
                                        print(string.format("  Old ID:     %s", old_media_id))
                                        print(string.format("  New ID:     %s", new_media_id))

                                        local set_ok, set_err = pcall(function()
                                            tool:SetInput("MediaID", new_media_id)
                                        end)

                                        if set_ok then
                                            print("  ✓ Media ID successfully updated.")
                                            updates_count = updates_count + 1
                                        else
                                            print(string.format("  ✗ Failed to update Media ID: %s", tostring(set_err)))
                                        end
                                    end
                                else
                                    print(string.format("\n[%s] Warning: file '%s' not found in MediaPool.", tool.Name, file_name))
                                    notfound_count = notfound_count + 1
                                end
                            end
                        end

                    end)

                    if not clip_ok then
                        print(string.format("Error processing clip: %s", tostring(clip_err)))
                    end
                end
            end
        end

        print("\n========================================")
        print(string.format("  Updated:            %d", updates_count))
        print(string.format("  Already up to date: %d", skipped_count))
        print(string.format("  Not found in pool:  %d", notfound_count))
        print("========================================")
    end)

    if not ok then
        print(string.format("Critical error: %s", tostring(err)))
    end
end

update_media_ids()