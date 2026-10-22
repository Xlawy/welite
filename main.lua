local Event = require("ui/event")
local logger = require("welite.lib.logger")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Client = require("welite.lib.client")
local BackgroundWorker = require("welite.lib.background_worker")
local Downloader = require("welite.lib.downloader")
local ExternalAnnotationsDB = require("welite.lib.external_annotations_db")
local Integrations = require("welite.integrations.init")
local LibraryDB = require("welite.lib.library_db")
local Mixin = require("welite.lib.mixin")
local Migrations = require("welite.lib.migrations")
local PluginUtil = require("welite.lib.plugin_util")
local ProgressSync = require("welite.lib.progress_sync")
local ProgressSyncDialog = require("welite.ui.progress_sync_dialog")
local QRLogin = require("welite.lib.qr_login")
local ReadReport = require("welite.lib.read_report")
local Settings = require("welite.lib.settings")
local Updater = require("welite.lib.updater")
local UpdaterUI = require("welite.ui.updater")

local _ = PluginUtil.tr

local WeLitePlugin = WidgetContainer:extend{
    name = "welite",
    is_doc_only = false,
    version = require("welite.identity").version,
}

-- Stable entry point used by third-party launchers such as SimpleUI and ZenUI.
function WeLitePlugin:openBookshelf()
    return self:showBookshelf()
end

-- Both SimpleUI and ZenUI discover conventional plugin launch methods.
function WeLitePlugin:launch()
    return self:openBookshelf()
end

function WeLitePlugin:onZenUIReady()
    Integrations.onZenUIReady(self)
    return true
end

function WeLitePlugin:init()
    -- Never replace the original WeRead plugin's public handle.
    if self.ui then self.ui.welite = self end
    math.randomseed(os.time())
    self.settings = Settings:new()
    self.external_annotations_db = ExternalAnnotationsDB:new(self.settings)
    self.library_db = LibraryDB:new(self.settings)
    local updater = Updater:new{
        settings = self.settings,
        current_version = self.version,
    }
    self.updater = UpdaterUI:new{
        updater = updater,
        settings = self.settings,
        is_connected = function()
            return self:isNetworkConnected()
        end,
        refresh_ui = function()
            self:refreshUI()
        end,
    }
    self.client = Client:new(self.settings)
    self.prefetch_worker = BackgroundWorker:new{
        temp_dir = self.settings.data_dir .. "/workers",
        -- A soft launch gate, not a reservation: fork uses copy-on-write and
        -- normally consumes far less than this on a 512 MB Kindle.
        min_available_kb = 64 * 1024,
    }
    self.downloader = Downloader:new{
        client = self.client,
        settings = self.settings,
        background_worker = self.prefetch_worker,
        show_info       = function(text) self:showInfo(text) end,
        show_transient  = function(text, timeout) self:showTransientInfo(text, timeout) end,
        refresh_ui      = function() self:refreshUI() end,
        refresh_shelf   = function() self:refreshShelfCacheIndicators() end,
        open_file       = function(path) self:openFile(path) end,
        safe_callback   = function(label, fn) return self:safeCallback(label, fn) end,
        require_login   = function(cookie, api_key) return self:requireLogin(cookie, api_key) end,
        run_online_task = function(label, fn)
            return self:runOnlineTask(label, fn)
        end,
        is_connected = function()
            return self:isNetworkConnected()
        end,
    }
    Migrations.run(self.settings, self.client)
    self.external_annotations_db:migrateLegacySettings()
    if self.downloader.recover then
        self.downloader:recover()
    end
    self.qr_login = QRLogin:new(self, self.client, self.settings)
    self.read_report = ReadReport:new{
        time_ledger = require("welite.lib.reading_time_ledger").open(self.settings,function()
            local time=require("ui/time")
            return time.to_s(time.now())
        end),
        settings = self.settings,
        client = self.client,
        library_db = self.library_db,
        scheduler = UIManager,
        get_document = function()
            return self.ui and self.ui.document
        end,
        detect_book = function()
            return self:detectWeReadBook()
        end,
        position_provider = function(book_id)
            if not self.progress_sync then
                return nil, "progress_sync_initializing", true
            end
            return self.progress_sync:position_for_report(book_id)
        end,
        -- The report tick runs on the UI loop; use the link-state check here
        -- because NetworkMgr:isOnline() does a blocking DNS lookup.
        is_online = function()
            return self:isNetworkConnected()
        end,
    }
    self.progress_sync = ProgressSync:new{
        can_finish_close_upload = function()
            local active = require("apps/reader/readerui").instance
            return not active or active == self.ui
        end,
        settings = self.settings,
        client = self.client,
        scheduler = UIManager,
        get_document = function()
            return self.ui and self.ui.document
        end,
        get_footer = function()
            return self.ui and self.ui.view and self.ui.view.footer
        end,
        get_view_mode = function()
            return self.ui and self.ui.view and self.ui.view.view_mode or "page"
        end,
        detect_book = function()
            return self:detectWeReadBook()
        end,
        get_book = function(book_id)
            return self.settings:get("books", {})[tostring(book_id)]
        end,
        get_chapters = function(book)
            return self:ensureChaptersLoaded(book)
        end,
        refresh_catalog_async = function(book_id,done,valid)
            return require("welite.lib.progress_pull_worker").catalog(self,book_id,done,valid)
        end,
        get_file_context = function(book, path)
            return self:getChapterInfoFromFile(book, path)
        end,
        run_online = function(_kind, callback, run_options)
            return self:runOnlineTask(
                _("Sync progress"), callback, nil, run_options)
        end,
        upload_position_async = function(book_id, position, done, valid)
            return self.read_report:upload_position_async(book_id, position, done, valid)
        end,
        capture_local_snapshot = function(context, position)
            return require("welite.lib.progress_source_locator").snapshot(self,context,position)
        end,
        prepare_local_async = function(context, position, done, valid)
            return require("welite.lib.progress_source_locator").capture(self,context,position,done,valid)
        end,
        prepare_remote_async = function(context, remote, done, valid)
            return require("welite.lib.progress_source_locator").start(self,context,remote,done,valid)
        end,
        goto_xpointer = function(xp)
            return pcall(function() self.ui.rolling:onGotoXPointer(xp) end)
        end,
        goto_page = function(page)
            return pcall(function() self.ui.rolling:onGotoPage(page) end)
        end,
        goto_fraction = function(fraction)
            -- KOReader accepts fractional percentages. Rounding here loses
            -- several pages in long books before the host resolves a position.
            local percent = math.max(0, math.min(1, tonumber(fraction) or 0)) * 100
            return pcall(function()
                if self.ui and self.ui.rolling
                    and self.ui.rolling.onGotoPercent then
                    self.ui.rolling:onGotoPercent(percent)
                elseif self.ui then
                    self.ui:handleEvent(Event:new("GotoPercent", percent))
                else
                    error("reader unavailable")
                end
            end)
        end,
        open_chapter = function(book, chapter)
            return self:openProgressTargetChapter(book, chapter)
        end,
        is_online = function()
            return self:isNetworkConnected()
        end,
        on_choice = function(context)
            ProgressSyncDialog.show_choice(context)
        end,
        run_pull = function(task, done, valid)
            return require("welite.lib.progress_pull_worker").start(self,task,done,valid)
        end,
        get_remote_chapter_fraction = function(book_id, remote)
            return require("welite.lib.progress_pull_worker").cached_chapter_fraction(self,book_id,remote)
        end,
        cancel_pull = function()
            require("welite.lib.progress_source_locator").cancel(self)
            require("welite.lib.progress_pull_worker").cancel(self)
        end,
        on_synced = function(book_id, account)
            require("welite.ui.welite.reading_sync").complete(self, book_id, account)
        end,
        notify = function(code, data)
            ProgressSyncDialog.notify(code, data)
        end,
    }
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.postInitCallback and self.ui.registerPostInitCallback then
        self.ui:registerPostInitCallback(function() require("welite.ui.welite.home").queueStartup(self) end)
    end
    self.integrations = Integrations
    self.integrations.register(self)
    self._reader_session_gen = 0
    self.updater:schedule_auto_check()
    logger.info("initialized:", "version=", self.version)
    updater:cleanup_backup()
end

Mixin.apply(WeLitePlugin, {
    (require("welite.ui.common")),
    (require("welite.ui.menu")),
    (require("welite.ui.cache")),
    (require("welite.ui.read_report")),
    (require("welite.ui.library")),
    (require("welite.ui.annotations_controller")),
    (require("welite.ui.xpointer_overlay_controller")),
    (require("welite.ui.annotation_sync_controller")),
    (require("welite.ui.reader_navigation")),
    (require("welite.lib.reader_lifecycle")),
})

return WeLitePlugin
