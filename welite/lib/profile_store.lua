-- One-time, atomic copy of the old profile. Book paths and credentials are kept;
-- the original file is never flushed, renamed or removed. No cache-tree scan.
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local Identity = require("welite.identity")
local Profile = { MAX_BYTES = 8 * 1024 * 1024 }

local function exists(path)
    return lfs.attributes(path, "mode") == "file"
end

local function read_snapshot(path)
    local found = false
    for _, candidate in ipairs({path, path .. ".old"}) do
        if exists(candidate) then
            found = true
            local size = lfs.attributes(candidate, "size")
            if not size or size > Profile.MAX_BYTES then
                error("welite.profile_store: legacy profile exceeds migration limit")
            end
            local ok, value = pcall(dofile, candidate)
            if ok and type(value) == "table" then return value end
        end
    end
    if found then error("welite.profile_store: cannot read legacy profile or its backup") end
end

function Profile.open(path, legacy_path)
    -- Presence, not login state, prevents a logout from reimporting credentials.
    if exists(path) or exists(path .. ".old") then
        local store = LuaSettings:wrap(read_snapshot(path))
        store.file = path
        return store
    end
    local data = read_snapshot(legacy_path)
    if not data then return LuaSettings:open(path) end
    local update = type(data.update) == "table" and data.update or {}
    data.update = {
        source = Identity.repository,
        auto_check = update.auto_check == true,
        prefer_proxy = update.prefer_proxy ~= false,
    }
    data.welite_profile_migrated = 1
    local stage = path .. ".migrating"
    -- Never mistake a previous interrupted attempt for this write succeeding.
    os.remove(stage)
    os.remove(stage .. ".old")
    local store = LuaSettings:wrap(data)
    store.file = stage
    local ok, err = pcall(function()
        store:flush()
        local saved = read_snapshot(stage)
        assert(saved and saved.welite_profile_migrated == 1,
            "staged profile was not persisted")
        local moved, reason = os.rename(stage, path)
        assert(moved, reason or "profile activation failed")
        require("ffi/util").fsyncDirectory(path)
    end)
    if not ok then
        os.remove(stage)
        os.remove(stage .. ".old")
        error("welite.profile_store: migration failed: " .. tostring(err))
    end
    os.remove(stage .. ".old")
    store.file = path
    return store
end

return Profile
