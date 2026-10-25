local logger = require("welite.lib.logger")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Client = require("welite.lib.client")
local BackgroundWorker = require("welite.lib.background_worker")
local Downloader = require("welite.lib.downloader")
local ExternalAnnotationsDB = require("welite.lib.external_annotations_db")
local Integrations = require("welite.integrations.init")
local LibraryDB = require("welite.lib.library_db")
local Mixin = require("welite.lib.mixin")
local Migrations = require("welite.lib.migrations")
local QRLogin = require("welite.lib.qr_login")
local Settings = require("welite.lib.settings")
local Updater = require("welite.lib.updater")
local UpdaterUI = require("welite.ui.updater")

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
    require("welite.lib.reader_services").attach(self)
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
