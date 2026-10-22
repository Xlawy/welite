-- Project user-defined WeRead shelf groups onto the current shelf snapshot.

local Groups = {}

local function text(value, fallback)
    if type(value) ~= "string" then return fallback end
    value = value:match("^%s*(.-)%s*$")
    return value ~= "" and value or fallback
end

local function group_key(archive, label)
    local id = archive.archiveId or archive.archive_id or archive.id
    if id ~= nil and tostring(id) ~= "" then return "archive:" .. tostring(id) end
    return "name:" .. label
end

function Groups.list(archives, books, unnamed_label, ungrouped_label)
    local by_id = {}
    for _, book in ipairs(type(books) == "table" and books or {}) do
        local id = book.book_id or book.bookId
        if id then by_id[tostring(id)] = book end
    end

    local groups = {}
    local grouped = {}
    for _, source_archive in ipairs(type(archives) == "table" and archives or {}) do
        local archive = type(source_archive) == "table" and source_archive or {}
        local ids = type(archive.bookIds) == "table" and archive.bookIds or {}
        local label = text(archive.name, unnamed_label or "Unnamed group")
        local members, seen = {}, {}
        for _, id in ipairs(ids) do
            id = tostring(id)
            local book = by_id[id]
            if book and not seen[id] then
                members[#members + 1] = book
                seen[id] = true
                grouped[id] = true
            end
        end
        -- Public-account archives contain no regular books. The original
        -- bookshelf already exposes those separately, so do not add a ghost
        -- group for them. Empty user-created groups stay visible.
        if #members > 0 or #ids == 0 then
            groups[#groups + 1] = {
                key = group_key(archive, label),
                label = label,
                books = members,
            }
        end
    end
    local ungrouped = {}
    for _, book in ipairs(type(books) == "table" and books or {}) do
        local id = book.book_id or book.bookId
        if id and not grouped[tostring(id)] then ungrouped[#ungrouped + 1] = book end
    end
    if #groups > 0 and #ungrouped > 0 then
        groups[#groups + 1] = {
            key = "__ungrouped__",
            label = ungrouped_label or "Uncategorized",
            books = ungrouped,
        }
    end
    return groups
end

function Groups.find(groups, key)
    for _, group in ipairs(type(groups) == "table" and groups or {}) do
        if group.key == key then return group end
    end
end

return Groups
