local Event = require("ui/event")
local logger = require("weread.lib.logger")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Client = require("weread.lib.client")
local BackgroundWorker = require("weread.lib.background_worker")
local Downloader = require("weread.lib.downloader")
local ExternalAnnotationsDB = require("weread.lib.external_annotations_db")
local Integrations = require("integrations.init")
local LibraryDB = require("weread.lib.library_db")
local Mixin = require("weread.lib.mixin")
local Migrations = require("weread.lib.migrations")
local PluginUtil = require("weread.lib.plugin_util")
local ProgressSync = require("weread.lib.progress_sync")
local ProgressSyncDialog = require("weread.ui.progress_sync_dialog")
local QRLogin = require("weread.lib.qr_login")
local ReadReport = require("weread.lib.read_report")
local Settings = require("weread.lib.settings")
local Updater = require("weread.lib.updater")
local UpdaterUI = require("weread.ui.updater")

local _ = PluginUtil.tr

local WeReadPlugin = WidgetContainer:extend{
    name = "weread",
    is_doc_only = false,
    version = "1.0.2",
}

-- Stable entry point used by third-party launchers such as SimpleUI and ZenUI.
function WeReadPlugin:openBookshelf()
    return self:showBookshelf()
end

-- Both SimpleUI and ZenUI discover conventional plugin launch methods.
function WeReadPlugin:launch()
    return self:openBookshelf()
end

function WeReadPlugin:onZenUIReady()
    Integrations.onZenUIReady(self)
    return true
end

function WeReadPlugin:init()
    -- KOReader derives the public module name from welite.koplugin. Existing
    -- reader services and third-party launchers still use the weread handle.
    if self.ui then self.ui.weread = self end
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
        time_ledger = require("weread.lib.reading_time_ledger").open(self.settings,function()
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
            return require("weread.lib.progress_pull_worker").catalog(self,book_id,done,valid)
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
            return require("weread.lib.progress_source_locator").snapshot(self,context,position)
        end,
        prepare_local_async = function(context, position, done, valid)
            return require("weread.lib.progress_source_locator").capture(self,context,position,done,valid)
        end,
        prepare_remote_async = function(context, remote, done, valid)
            return require("weread.lib.progress_source_locator").start(self,context,remote,done,valid)
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
            return require("weread.lib.progress_pull_worker").start(self,task,done,valid)
        end,
        cancel_pull = function()
            require("weread.lib.progress_source_locator").cancel(self)
            require("weread.lib.progress_pull_worker").cancel(self)
        end,
        on_synced = function(book_id, account)
            require("weread.ui.welite.reading_sync").complete(self, book_id, account)
        end,
        notify = function(code, data)
            ProgressSyncDialog.notify(code, data)
        end,
    }
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.postInitCallback and self.ui.registerPostInitCallback then
        self.ui:registerPostInitCallback(function() require("weread.ui.welite.home").queueStartup(self) end)
    end
    self.integrations = Integrations
    self.integrations.register(self)
    self._reader_session_gen = 0
    self.updater:schedule_auto_check()
    logger.info("initialized:", "version=", self.version)
    updater:cleanup_backup()
end

Mixin.apply(WeReadPlugin, {
    (require("weread.ui.common")),
    (require("weread.ui.menu")),
    (require("weread.ui.cache")),
    (require("weread.ui.read_report")),
    (require("weread.ui.library")),
    (require("weread.ui.annotations_controller")),
    (require("weread.ui.xpointer_overlay_controller")),
    (require("weread.ui.annotation_sync_controller")),
    (require("weread.ui.reader_navigation")),
    (require("weread.lib.reader_lifecycle")),
})

return WeReadPlugin
