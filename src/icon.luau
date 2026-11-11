--!nonstrict
-- Glyph helper with one extra icon: a flat tomato drawn in the current theme colour.
-- The icon font has no tomato, and images can't be tinted, so the SVG is written
-- once per colour into the data dir and then reused.

local M = {}

local TOMATO = [[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="96" height="96"><defs><mask id="cut"><rect width="24" height="24" fill="#fff"/><path d="M12 4.2 L13.6 7.6 L17.6 6.9 L14.9 9.4 L16.6 11.6 L12 10.3 L7.4 11.6 L9.1 9.4 L6.4 6.9 L10.4 7.6 Z" fill="#000" stroke="#000" stroke-width="2.4" stroke-linejoin="round"/></mask></defs><g fill="%s" fill-opacity="%s" stroke="%s" stroke-opacity="%s"><path mask="url(#cut)" stroke="none" d="M12 6.4c-5.2 0-9.2 3.3-9.2 7.6 0 4.7 4 7.9 9.2 7.9s9.2-3.2 9.2-7.9c0-4.3-4-7.6-9.2-7.6z"/><path stroke-width="0.9" stroke-linejoin="round" d="M12 4.2 L13.6 7.6 L17.6 6.9 L14.9 9.4 L16.6 11.6 L12 10.3 L7.4 11.6 L9.1 9.4 L6.4 6.9 L10.4 7.6 Z"/><path fill="none" stroke-width="1.6" stroke-linecap="round" d="M12 5.2 C12 3.6 12.6 2.6 14 2"/></g></svg>]]

local dir = noctalia.pluginDataDir() .. "/icons"
local written = {}

local function resolve(token)
    local base, alpha = string.match(token or "on_surface", "^([^/]+)/?(.*)$")
    local ok, hex = pcall(noctalia.getColor, base)
    if not ok or type(hex) ~= "string" or not string.match(hex, "^#%x+$") then hex = "#888888" end
    return string.upper(hex), (alpha ~= "" and tonumber(alpha)) or 1
end

function M.tomatoPath(token)
    local hex, alpha = resolve(token)
    local key = string.sub(hex, 2) .. (alpha < 1 and string.format("-%02d", math.floor(alpha * 100)) or "")
    local path = dir .. "/tomato-" .. key .. ".svg"
    if not written[path] then
        if not noctalia.fileExists(path) then
            noctalia.mkdirAll(dir)
            local a = string.format("%.2f", alpha)
            noctalia.writeFile(path, string.format(TOMATO, hex, a, hex, a))
        end
        written[path] = true
    end
    return path
end

-- Same props as ui.glyph; name = "tomato" draws the custom icon.
function M.glyph(props)
    if props.name ~= "tomato" then return ui.glyph(props) end
    local size = props.size or 16
    return ui.image({ path = M.tomatoPath(props.color), width = size, height = size, fit = "contain" })
end

return M
