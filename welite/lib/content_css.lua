-- Book CSS compatibility; intentionally preserves all non-root styling.
local M = {}
-- True when the text following the literal "0" of a font-size declaration
-- (already captured by the caller's pattern) is only an optional unit plus
-- whitespace and an optional !important flag, i.e. the declared size really is
-- zero. Zero times any unit is still zero length, so an empty tail (bare 0) and
-- every letter-unit form (px/em/rem/vh/...) count; fractional sizes such as
-- 0.5rem never match because "." is not a letter.
local function is_zero_font_size(tail)
    local value = tail:lower():match("^%s*(.-)%s*$")
    if value:sub(-10) == "!important" then
        value = (value:match("^(.-)%s*!important$") or ""):match("^%s*(.-)%s*$")
    end
    return value == "" or value == "%" or value:match("^%a+$") ~= nil
end

-- Known limitations: property-name matching is case-sensitive (all observed
-- WeRead shards are lowercase), a CSS comment containing exactly
-- "font-size: 0" may have its interior rewritten without structural harm, and
-- only top-level rules naming exactly html/body are touched (:root,
-- descendant selectors and @media-wrapped rules are left as-is).

-- True when the selector list names nothing but the root elements, i.e. every
-- comma-separated selector is exactly html or body (case- and
-- whitespace-insensitive). Compound selectors such as "body p" or
-- "body, .wrapper" also style other content, so they never qualify.
local function is_root_selector_list(selectors)
    local count = 0
    for selector in (selectors or ""):gmatch("[^,]+") do
        count = count + 1
        local name = selector:lower():gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "html" and name ~= "body" then return false end
    end
    return count > 0
end

-- Remove every zero `font-size` declaration from one braceless declaration
-- block. The sentinel "{" guarantees the boundary capture below always has a
-- character to inspect, even when the declaration opens the block.
local function strip_zero_font_sizes(block)
    local removed = 0
    local cleaned = ("{" .. block):gsub("([^%w%-])(%s*)font%-size%s*:%s*0([^;}]*)(;?)", function(boundary, leading, tail, _terminator)
        if not is_zero_font_size(tail) then
            return nil -- keep fractional sizes such as 0.5rem untouched
        end
        removed = removed + 1
        return boundary .. leading
    end)
    return cleaned:sub(2), removed
end

-- Strip hostile `font-size: 0` declarations from server-provided book css, but
-- only inside rules whose selector list is exactly `html` and/or `body`.
-- WeRead shards occasionally ship `html, body { ... font-size: 0; }`; WeRead's
-- own apps ignore root-element sizing but crengine honors it, collapsing the
-- whole book to a near-zero font size on device. Elsewhere `font-size: 0` can
-- be intentional (e.g. hiding whitespace between inline-block items), so every
-- other rule passes through verbatim.
local function sanitize_book_css_pass(css)
    local removed = 0
    -- Scan whole `selector { block }` units (balanced braces); untouched units
    -- are returned verbatim so no other declaration can be disturbed.
    local sanitized = css:gsub("([^{}]*)(%b{})", function(prelude, block)
        -- Text before the last ";" belongs to an at-rule or a previous
        -- statement, not to this block's selector list.
        local selectors = prelude:match("[^;]*$") or ""
        if not is_root_selector_list(selectors) then
            return prelude .. block
        end
        local cleaned, dropped = strip_zero_font_sizes(block:sub(2, -2))
        removed = removed + dropped
        return prelude .. "{" .. cleaned .. "}"
    end)
    return sanitized, removed
end

function M.sanitize(css)
    if type(css) ~= "string" or css == "" then
        return css, 0
    end
    -- Each pass consumes one boundary character per match, so adjacent zero
    -- declarations ("font-size:0;font-size:0") need repeated passes until the
    -- fixpoint; the cap only guards pathological input.
    local removed_total = 0
    local sanitized = css
    for _i = 1, 16 do
        local removed
        sanitized, removed = sanitize_book_css_pass(sanitized)
        removed_total = removed_total + removed
        if removed == 0 then break end
    end
    return sanitized, removed_total
end

return M
