local Content = require("welite.lib.content")
local logger = require("welite.lib.logger")

local PluginUtil = require("welite.lib.plugin_util")
local log_error = PluginUtil.log_error

local Migrations = {}
local completed = setmetatable({}, { __mode = "k" })

function Migrations.run(settings, client)
    local owner = settings.store or settings
    if completed[owner] then return true end
    local books = settings:get("books", {})
    local found, migrated, failed = false, 0, 0
    for _book_id, book in pairs(books) do
        if type(book) == "table" and book.chapters ~= nil then
            found = true
            if type(book.chapters) == "table" then
                local ok, saved = pcall(Content.save_catalog_cache,
                    client, settings, book, book.chapters)
                if ok and saved then
                    migrated = migrated + 1
                else
                    failed = failed + 1
                end
            end
        end
    end
    if failed > 0 then
        logger.warn("legacy catalog migration deferred:", "catalog_failures=", tostring(failed))
        return false
    end
    if not found and not settings:has_legacy_book_records() then
        completed[owner] = true
        return true
    end
    for _, book in pairs(books) do
        if type(book) == "table" then book.chapters = nil end
    end

    local ok, err = pcall(function()
        settings:set("books", books)
        settings:flush()
    end)
    if ok then
        completed[owner] = true
        logger.info("legacy per-book data migrated:",
            "catalogs=", tostring(migrated),
            "catalog_failures=", tostring(failed))
    else
        logger.err("legacy per-book data migration failed:",
            log_error(err))
    end
    return ok
end

return Migrations
