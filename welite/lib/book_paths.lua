-- Canonical cache locations shared by storage, downloads and reader lookup.
local M = {}
local function basename_safe(value)
    value = tostring(value or ""):gsub("[^%w%._-]", "_")
    if value == "" then
        value = "weread"
    end
    return value
end

-- Directory name a book is stored under (sanitized book id). Exposed so the
-- local-cache scanner can match on-disk directory names against shelf book ids.
function M.book_dir_name(book_id)
    return basename_safe(book_id)
end

function M.book_cache_dir(settings, book_id)
    return settings.cache_dir .. "/" .. M.book_dir_name(book_id)
end

-- Resolve where a book's files actually live. The current settings.cache_dir may
-- differ from where a book was downloaded (the user changed it since), so prefer
-- concrete evidence of the real location: an explicit book.cache_dir (set when any
-- file — chapter or MP article — is written), then the directory of a stored
-- cached_file/chapter path, and only as a last resort the path recomputed under
-- the current root. This keeps deletion, stats and moves on the real files instead
-- of orphaning them. MP article-only books have no cached_file, so book.cache_dir
-- is the only thing that pins them down.
function M.book_resolved_dir(settings, book_id, book)
    if book and type(book.cache_dir) == "string" and book.cache_dir ~= "" then
        return book.cache_dir
    end
    local function dirname(path)
        if type(path) == "string" then
            return path:match("^(.*)/[^/]+$")
        end
    end
    local dir = book and dirname(book.cached_full_book or book.cached_file)
    if not dir and book and type(book.cached_chapters) == "table" then
        for _i, chapter_path in pairs(book.cached_chapters) do
            dir = dirname(chapter_path)
            if dir then
                break
            end
        end
    end
    return dir or M.book_cache_dir(settings, book_id)
end

return M
