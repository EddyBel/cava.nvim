-- ============================================================================
-- THEME
-- ============================================================================
--
-- Utilidades de color compartidas por Player y Cava para poder darle a sus
-- ventanas un fondo ligeramente distinto al del editor (el mismo truco que
-- usan plugins como neo-tree/nvim-tree): NO se toca el colorscheme, sólo se
-- define un highlight group que es una copia de "Normal" con el fondo
-- oscurecido, y se aplica vía la opción de ventana `winhighlight`.
-- ============================================================================
local Theme = {}
--- Convierte un número de color (como lo devuelve nvim_get_hl) a "#rrggbb".
---
---@param color number
---@return string
local function to_hex(color)
    return string.format("#%06x", color)
end
--- Descompone un hexadecimal "#rrggbb" en componentes r, g, b (0-255).
---
---@param hex string
---@return number|nil r
---@return number|nil g
---@return number|nil b
local function hex_to_rgb(hex)
    hex = hex:gsub("#", "")
    if #hex ~= 6 then
        return nil
    end
    local r = tonumber(hex:sub(1, 2), 16)
    local g = tonumber(hex:sub(3, 4), 16)
    local b = tonumber(hex:sub(5, 6), 16)
    return r, g, b
end
--- Oscurece un color hexadecimal moviéndolo hacia el negro.
---
---@param hex string Color en formato "#rrggbb".
---@param amount number 0 = sin cambio, 1 = negro absoluto.
---@return string hex Color oscurecido (o el original si no se pudo parsear).
function Theme.darken(hex, amount)
    amount = math.max(0, math.min(1, tonumber(amount) or 0))
    local r, g, b = hex_to_rgb(hex)
    if not r then
        return hex
    end
    r = math.floor(r * (1 - amount))
    g = math.floor(g * (1 - amount))
    b = math.floor(b * (1 - amount))
    return string.format("#%02x%02x%02x", r, g, b)
end

--- Crea/actualiza un highlight group que es una copia de "Normal" pero con
--- el fondo oscurecido un `amount` (0-1). Conserva el resto de atributos de
--- "Normal" (foreground, etc.) para no alterar el color del texto, sólo el
--- fondo de la ventana.
---
--- Si el colorscheme actual no define un `bg` explícito para "Normal" (por
--- ejemplo, fondo transparente heredado de la terminal), no se puede
--- oscurecer nada y la función no hace ningún cambio — se preserva la
--- transparencia en vez de forzar un color arbitrario.
---
---@param name string Nombre del highlight group a crear (ej. "CavaNormal").
---@param amount number Cuánto oscurecer (0-1).
---@return boolean applied `true` si se pudo definir el highlight.
function Theme.setup_darker_normal(name, amount)
    local ok, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
    if not ok or not normal or not normal.bg then
        return false
    end
    local definition = vim.tbl_extend("force", {}, normal)
    local darker_hex = Theme.darken(to_hex(normal.bg), amount)
    local r, g, b = hex_to_rgb(darker_hex)
    if r then
        definition.bg = (r * 65536) + (g * 256) + b
    end
    vim.api.nvim_set_hl(0, name, definition)
    return true
end

return Theme
