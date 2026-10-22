local DataStorage = require("datastorage")
local BookStore = require("weread.lib.book_store")
local Cookie = require("weread.lib.cookie")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

local Settings = {}
Settings.__index = Settings
Settings.AUTH_SCHEMA_VERSION = 1

-- File manager and ReaderUI coexist. Independent snapshots can overwrite a
-- newer login when the older instance flushes an unrelated preference.
-- Share only stores for the same profile file; weak values release closed profiles.
local live_stores = setmetatable({}, { __mode = "v" })

local defaults = {
    auth_schema_version = Settings.AUTH_SCHEMA_VERSION,
    device_fingerprint = "",
    api_key = "",
    cookies = {},
    wr_ticket = "",
    wr_wrpa = "",
    account = {
        name = "",
        user_vid = "",
        login_method = "",
        login_time = 0,
    },
    books = {},
    downloads = {},
    sync = {
        pull_on_open = true,
        upload_on_close = true,
        ask_on_conflict = true,
        upload_interval_minutes = 0,
    },
    cache = {
        download_book_images = true,
        download_mp_images = false,
        download_underlines_and_thoughts = false,
        prefetch_annotations = false,
        auto_prefetch_next_chapter = false,
        show_prefetch_notifications = true,
        show_annotations = true,
        -- When true, taps in the left/right edge zones never open thought popups
        -- (and native #wrthought link follow is suppressed there too).
        ignore_edge_thought_taps = true,
        -- Fraction of screen width on each side treated as the page-turn edge zone.
        edge_tap_ratio = 0.20,
        max_size_mb = 1024,
    },
    read_report = {
        enabled = false,
        mode = "manual",
        book_id = "",
        book_title = "",
        interval_seconds = 30,
        report_on_open = true,
    },
    thought_popup = {
        -- Thought popup height as a fraction of the screen height.
        height_ratio = 0.70,
        -- Popup font size relative to the document font size; used while
        -- font_size is unset. Zero follows the document font size exactly.
        font_size_relative = 0,
        -- Fixed absolute popup font size (unscaled px); when set it takes
        -- precedence over font_size_relative.
        font_size = nil,
        -- Popup position: "center" (TextViewer-style centered window with
        -- page buttons, default) or "bottom" (solid-line bottom bar).
        position = "center",
        -- Centered popup width as a fraction of the screen width (only used
        -- when position is "center").
        width_ratio = 0.8,
        -- Text contrast delta for the popup blocks: +9 (the default) renders
        -- every text block in pure black; lower values progressively lighten it.
        contrast = 9,
        -- Tap the left/right half of the popup to turn pages (bottom and
        -- centered positions; off by default).
        tap_to_page = false,
    },
    advanced = {
        developer_logs = false,
    },
    update = {
        auto_check = false,
        prefer_proxy = true,
        last_check = 0,
        skipped_version = "",
        snoozed_version = "",
        snooze_until = 0,
        available_version = "",
        archive_url = "",
        checksum_url = "",
        archive_size = 0,
        release_notes = "",
        release_url = "",
    },
    shelf = {
        sort_order = "default",
        paginated = true,
        view_mode = "cover",
    },
    download_dir = "",
}

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    return out
end

local function ensure_dir(path)
    if not lfs.attributes(path, "mode") then
        lfs.mkdir(path)
    end
end

local function clear_auth_store(store)
    store:saveSetting("api_key", "")
    store:saveSetting("cookies", {})
    store:saveSetting("wr_ticket", "")
    store:saveSetting("wr_wrpa", "")
    store:saveSetting("account", deepcopy(defaults.account))
end

function Settings:new()
    local Environment = require("weread.lib.mock_environment")
    local environment = Environment.active()
    local mock_endpoint
    if environment.enabled then
        -- Invalid saved configuration must never silently select production.
        mock_endpoint = assert(Environment.endpoint(environment))
    end
    local name = mock_endpoint and "weread-mock" or "weread"
    local data_dir = DataStorage:getFullDataDir() .. "/" .. name
    ensure_dir(data_dir)
    local download_data_dir = mock_endpoint and data_dir or (DataStorage:getFullDataDir() .. "/welite")
    ensure_dir(download_data_dir)
    local obj = {
        data_dir = data_dir,
        default_cache_dir = download_data_dir .. "/cache",
        settings_file = DataStorage:getSettingsDir() .. "/" .. name .. ".lua",
        mock_endpoint = mock_endpoint,
        collection_name = name,
    }
    obj.store = live_stores[obj.settings_file]
    if not obj.store then
        obj.store = LuaSettings:open(obj.settings_file)
        live_stores[obj.settings_file] = obj.store
    end
    if mock_endpoint then
        obj.store:saveSetting("auth_schema_version", Settings.AUTH_SCHEMA_VERSION)
        obj.store:saveSetting("api_key", "mock-api-key")
        obj.store:saveSetting("cookies", { wr_skey = "mock-only", wr_vid = "900000" })
        obj.store:saveSetting("account", { name = "Mock", user_vid = "900000", login_method = "mock" })
        obj.store:saveSetting("wr_ticket", "")
        obj.store:saveSetting("wr_wrpa", "")
        -- A test must not move downloaded files into a production cache.
        obj.store:saveSetting("download_dir", "")
        obj.store:flush()
    end
    -- Retire old downloads without opening, copying or deleting their files.
    -- BookStore otherwise follows persisted cache_dir paths back into the old cache.
    local cache_layout_changed = false
    if not mock_endpoint and obj.store:readSetting("welite_cache_layout", 0) < 1 then
        local old_root = data_dir .. "/cache"
        local function old_path(path)
            return type(path) == "string" and (path == old_root or path:sub(1,#old_root+1) == old_root .. "/")
        end
        if old_path(obj.store:readSetting("download_dir", "")) then
            obj.store:saveSetting("download_dir", "")
        end
        local indexes = obj.store:readSetting("books", {})
        local pending = obj.store:readSetting("welite_pending_progress_sync", {})
        for id, index in pairs(indexes) do
            local retired = type(index) == "table" and (old_path(index.cache_dir)
                or old_path(index.cached_file) or old_path(index.cached_full_book))
            if not retired and type(index) == "table" then
                for _,path in pairs(index.cached_chapters or {}) do
                    if old_path(path) then retired = true; break end
                end
            end
            if retired then
                indexes[id] = nil
                if pending.books then pending.books[tostring(id)] = nil end
            end
        end
        obj.store:saveSetting("books", indexes)
        obj.store:saveSetting("welite_pending_progress_sync", pending)
        obj.store:saveSetting("welite_cache_layout", 1)
        cache_layout_changed = true
    end
    -- cache_dir is the download root; defaults to <data_dir>/cache unless overridden.
    local download_dir = obj.store:readSetting("download_dir", "")
    obj.cache_dir = (type(download_dir) == "string" and download_dir ~= "") and download_dir or obj.default_cache_dir
    ensure_dir(obj.cache_dir)
    local cache = obj.store:readSetting("cache", deepcopy(defaults.cache))
    local cache_changed = false
    if cache.download_book_images == nil then
        cache.download_book_images = cache.download_images ~= false
        cache_changed = true
    end
    if cache.download_mp_images == nil then
        cache.download_mp_images = false
        cache_changed = true
    end
    if cache.book_footnotes_in_popup ~= nil then
        cache.book_footnotes_in_popup = nil
        cache_changed = true
    end
    if cache.download_underlines_and_thoughts == nil then
        cache.download_underlines_and_thoughts = false
        cache_changed = true
    end
    if cache.prefetch_annotations == nil then
        -- Annotation prefetch now stores reusable source data instead of
        -- embedding marks in downloaded EPUBs, so it starts as a new opt-in.
        cache.prefetch_annotations = false
        cache_changed = true
    end
    if cache.auto_prefetch_next_chapter == nil then
        cache.auto_prefetch_next_chapter = false
        cache_changed = true
    end
    if cache.show_prefetch_notifications == nil then
        cache.show_prefetch_notifications = true
        cache_changed = true
    end
    if cache.show_annotations == nil then
        cache.show_annotations = true
        cache_changed = true
    end
    if cache.ignore_edge_thought_taps == nil then
        cache.ignore_edge_thought_taps = true
        cache_changed = true
    end
    if cache.edge_tap_ratio == nil then
        cache.edge_tap_ratio = 0.20
        cache_changed = true
    end
    if cache.download_images ~= nil then
        cache.download_images = nil
        cache_changed = true
    end
    if cache_changed then
        obj.store:saveSetting("cache", cache)
        obj.store:flush()
    end
    local sync = obj.store:readSetting("sync", {})
    local sync_changed = false
    for key, value in pairs(defaults.sync) do
        if sync[key] == nil then sync[key] = value; sync_changed = true end
    end
    if sync_changed then
        obj.store:saveSetting("sync", sync)
    end
    local legacy_changed = sync_changed or cache_layout_changed
    for _, key in ipairs({
        "config_auth_fingerprint",
        "config_preferences_fingerprint",
        "config_loaded",
        "curl_payload",
    }) do
        if obj.store:readSetting(key, nil) ~= nil then
            if type(obj.store.delSetting) == "function" then
                obj.store:delSetting(key)
            else
                obj.store:saveSetting(key, nil)
            end
            legacy_changed = true
        end
    end
    local stored_auth_version = tonumber(obj.store:readSetting("auth_schema_version", 0)) or 0
    if stored_auth_version < Settings.AUTH_SCHEMA_VERSION then
        -- Authentication before schema v1 may have come from legacy manual
        -- flows and has no reliable QR account provenance.
        -- Invalidate only credentials; books, downloads and user preferences
        -- remain intact and the UI will guide the user through a fresh QR login.
        clear_auth_store(obj.store)
        obj.store:saveSetting("auth_schema_version", Settings.AUTH_SCHEMA_VERSION)
        legacy_changed = true
    end
    if legacy_changed then
        obj.store:flush()
    end
    return setmetatable(obj, self)
end

-- Old in-memory records and offline metadata can outlive the one-time layout
-- migration. Enforce the retired-root boundary on every book read/write too.
local function has_retired_download(settings, book)
    if settings.mock_endpoint or type(book) ~= "table" then return false end
    local root = settings.data_dir .. "/cache"
    local function retired(path)
        return type(path) == "string" and (path == root or path:sub(1,#root+1) == root .. "/")
    end
    if retired(book.cache_dir) or retired(book.cached_file) or retired(book.cached_full_book) then return true end
    for _,path in pairs(book.cached_chapters or {}) do if retired(path) then return true end end
    return false
end

local function clear_retired_download(settings, book)
    if not has_retired_download(settings, book) then return end
    book.cache_dir = nil
    book.cached_file = nil
    book.cached_full_book = nil
    book.cached_chapters = nil
    book.annotation_documents = nil
    book._cached = nil
    book._download_state = nil
end

function Settings:get(key, default)
    if default == nil then
        default = defaults[key]
    end
    if key ~= "books" then
        return self.store:readSetting(key, deepcopy(default))
    end
    local indexes = self.store:readSetting("books", {})
    local books = {}
    for book_id, index in pairs(indexes or {}) do
        -- Never follow a retired index into its metadata/reading-state files.
        if not has_retired_download(self, index) then
            local book = BookStore.load(self, book_id, index)
            clear_retired_download(self, book)
            books[book_id] = book
        end
    end
    return books
end

function Settings:set(key, value)
    if key == "books" and type(value) == "table" then
        local indexes = {}
        for book_id, book in pairs(value) do
            clear_retired_download(self, book)
            local ok, index_or_err = BookStore.save(self, book_id, book)
            if not ok then
                error("Could not save book data: " .. tostring(index_or_err))
            end
            indexes[book_id] = index_or_err
        end
        value = indexes
    end
    self.store:saveSetting(key, value)
end

function Settings:delete(key)
    if type(self.store.delSetting) == "function" then
        self.store:delSetting(key)
    else
        self.store:saveSetting(key, nil)
    end
end

function Settings:has_legacy_book_records()
    local books = self.store:readSetting("books", {})
    return not BookStore.is_minimal_index(books)
end

function Settings:flush()
    self.store:flush()
end

function Settings:get_device_fingerprint()
    local fingerprint = self:get("device_fingerprint", "")
    if type(fingerprint) == "string" and #fingerprint <= 10
        and fingerprint:match("^%d+$") and tonumber(fingerprint) <= 4294967295 then
        return fingerprint
    end

    -- Match the website's unsigned 32-bit decimal wr_fp format. This identifies
    -- an installation, not an account, and must survive logout and QR retries.
    local source = io.open("/dev/urandom", "rb")
    if not source then error("Could not generate WeRead device fingerprint") end
    local bytes = source:read(4)
    source:close()
    if not bytes or #bytes ~= 4 then
        error("Could not generate WeRead device fingerprint")
    end
    local a, b, c, d = bytes:byte(1, 4)
    fingerprint = string.format("%.0f", ((a * 256 + b) * 256 + c) * 256 + d)
    self:set("device_fingerprint", fingerprint)
    self:flush()
    return fingerprint
end

function Settings:update_auth(credentials, options)
    credentials = credentials or {}
    options = options or {}
    local changed = false

    if type(credentials.cookies) == "table" then
        local cookies = credentials.cookies
        if options.replace_cookies ~= true then
            cookies = Cookie.merge(self:get("cookies", {}), cookies)
        else
            cookies = deepcopy(cookies)
        end
        self:set("cookies", cookies)
        changed = true
    end

    for _, key in ipairs({ "api_key", "wr_ticket", "wr_wrpa" }) do
        local value = credentials[key]
        if type(value) == "string" then
            self:set(key, value)
            changed = true
        end
    end
    if type(credentials.account) == "table" then
        self:set("account", deepcopy(credentials.account))
        changed = true
    end

    if changed and options.flush ~= false then
        self:flush()
    end
    return changed
end

function Settings:merge_set_cookie(set_cookie, options)
    if not set_cookie or set_cookie == "" then
        return false
    end
    local cookies = Cookie.merge_set_cookie(self:get("cookies", {}), set_cookie)
    return self:update_auth({ cookies = cookies }, {
        replace_cookies = true,
        flush = not options or options.flush ~= false,
    })
end

function Settings:get_all()
    local all = {}
    for key in pairs(defaults) do
        all[key] = self:get(key)
    end
    return all
end

function Settings:get_download_dir()
    return self.cache_dir
end

-- Pass nil or "" to reset to the default download directory.
function Settings:set_download_dir(path)
    if self.mock_endpoint then return self.cache_dir end
    if type(path) ~= "string" or path == "" then
        self:set("download_dir", "")
        self.cache_dir = self.default_cache_dir
    else
        self:set("download_dir", path)
        self.cache_dir = path
    end
    self:flush()
    ensure_dir(self.cache_dir)
    return self.cache_dir
end

function Settings:reset_account()
    clear_auth_store(self.store)
    self:flush()
end

function Settings:is_cookie_configured()
    return Cookie.has_login_cookie(self:get("cookies", {})) == true
end

function Settings:is_api_configured()
    return self:get("api_key", "") ~= ""
end

return Settings
