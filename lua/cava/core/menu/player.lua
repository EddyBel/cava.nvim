-- ============================================================================
-- PLAYER
-- ============================================================================
--
-- Este módulo administra exclusivamente el buffer/ventana encargado de
-- mostrar la información de la canción actual:
--
--     ┌──────────────────────────────┐
--     │            MUSIC             │
--     │                              │
--     │          Artwork             │
--     │   ● Playing   Provider       │
--     │        Song title            │
--     │        Artist                │
--     │        Album                 │
--     │   [████████░░░░]  01:20/03:20│
--     │      [<<]  [||]  [>>]        │
--     └──────────────────────────────┘
--
-- El módulo NO se encarga de:
--
--   - crear splits ni decidir el orden de las ventanas (eso es de Menu);
--   - obtener información de Playerctl;
--   - ejecutar CAVA/Chafa.
--
-- Su responsabilidad es exclusivamente:
--
--     datos → layout → buffer → highlights
--
-- Menu es quien crea la ventana (`vim.cmd("vsplit")`, etc.) y le entrega el
-- winid mediante `Player:attach_window(winid)`.
--
-- ============================================================================
--                    ARQUITECTURA DE RENDERIZADO (IMPORTANTE)
-- ============================================================================
--
-- El contenido visual está dividido en "secciones" independientes
-- (`Player.SECTIONS`):
--
--     header    -> título "MUSIC" + separador (sólo cambia con el ancho)
--     artwork   -> portada centrada (sólo cambia con set_artwork/clear_artwork)
--     meta      -> icono/estado + provider + título/artista/álbum
--     progress  -> barra de progreso + tiempo (cambia MUY seguido)
--     controls  -> [<<] [||]/[>] [>>] + separador inferior
--     tracklist -> lista de canciones (cambia poco)
--
-- Cada sección tiene:
--   - un builder: `Player:_build_section_<nombre>(width)`
--   - una caché:  `self._section_cache[<nombre>] = { lines, highlights }`
--   - un flag:    `self._dirty[<nombre>]`
--
-- CÓMO SE USA AHORA EL MÓDULO:
--
--   1. `Player:render()`
--        Fuerza el recálculo de TODAS las secciones (marca todo como
--        "dirty"). Úsalo sólo cuando no sabes qué cambió o tras
--        `attach_window` / cambios de configuración. Es la opción "nuclear".
--
--   2. Actualizaciones puntuales (lo normal en cada tick del reproductor):
--        - `Player:update_music(metadata)`
--              Compara campo a campo contra la metadata anterior y sólo
--              marca "dirty" lo que realmente cambió:
--                * status/provider  -> meta + controls
--                * title/artist/album -> meta
--                * position/duration -> progress
--              Si llamas esto cada segundo sólo con position/duration
--              cambiando, ÚNICAMENTE se reconstruye/reescribe la sección
--              "progress" (2 líneas). Portada, tracklist y sus highlights
--              no se tocan.
--        - `Player:set_artwork(lines, highlights)` / `clear_artwork()`
--              Sólo afecta "artwork".
--        - `Player:update_tracklist(...)`, `set_tracklist_selected(...)`,
--          `set_tracklist_artwork(...)`, `clear_tracklist_artwork()`,
--          `clear_tracklist()`
--              Sólo afectan "tracklist".
--
--   3. Escritura al buffer (automática, no requiere hacer nada especial):
--        Aunque una sección se recalcule, `Player` compara el resultado
--        final línea por línea contra lo último escrito (diff de
--        prefijo/sufijo) y sólo llama `nvim_buf_set_lines` en el rango que
--        cambió. Los highlights sólo se limpian/reaplican en ese mismo
--        rango (el resto son extmarks y no se ven afectados). Si nada
--        cambió realmente, no se toca el buffer en absoluto.
--
--   4. El cambio de ancho de la ventana se detecta solo (comparando con el
--      ancho del render anterior) y fuerza "dirty" en todas las secciones,
--      porque el ancho afecta el centrado/truncado de todo el layout.
--
-- Si agregas un campo nuevo a la metadata o una sección nueva, recuerda:
--   - agregar el nombre a `Player.SECTIONS`,
--   - crear su `_build_section_<nombre>(width)` que devuelva
--     `lines, highlights` (con `highlight.line` RELATIVO al inicio de la
--     sección, no absoluto al buffer — el ensamblado se encarga del offset),
--   - decidir en qué setter/updater se debe marcar "dirty".
-- ============================================================================
local Player = {}
Player.__index = Player

--- Orden en el que se ensamblan las secciones dentro del buffer.
--- El orden importa: define el layout final de arriba hacia abajo.
Player.SECTIONS = { "header", "artwork", "meta", "progress", "controls", "tracklist" }

-- ============================================================================
--                              CONFIGURATION
-- ============================================================================
---@type table
Player.config = {
    --------------------------------------------------------------------------
    -- Buffer
    --------------------------------------------------------------------------
    --- Nombre del buffer.
    name = "Music Manager",
    --- Buffer que no pertenece a un archivo normal.
    buftype = "nofile",
    --- Ocultar el buffer en lugar de eliminarlo cuando desaparece
    --- temporalmente de una ventana.
    bufhidden = "hide",
    --- No crear archivo .swp.
    swapfile = false,

    --------------------------------------------------------------------------
    -- Background
    --------------------------------------------------------------------------
    background = {
        --- Si es `false`, la ventana usa el fondo normal del editor.
        enabled = true,
        --- Cuánto oscurecer el fondo respecto a "Normal": 0 = igual,
        --- 1 = negro absoluto. 0.15 es un valor sutil, similar a lo que
        --- usan plugins como neo-tree.
        darken = 0.15,
        --- Nombre del highlight group generado internamente.
        highlight_group = "CavaPlayerNormal",
    },

    --------------------------------------------------------------------------
    -- Window options
    --------------------------------------------------------------------------
    window = {
        wrap = false,
        number = false,
        relativenumber = false,
        cursorline = false,
        cursorcolumn = false,
        signcolumn = "no",
        colorcolumn = "",
    },
    --------------------------------------------------------------------------
    -- Music information
    --------------------------------------------------------------------------
    music = {
        title = "MUSIC",

        title_style = {
            -- Activa/desactiva el estilo.
            enabled = false,

            -- Caracteres laterales.
            --
            -- Puedes usar:
            --
            --     left  = ""
            --     right = ""
            --
            -- Si ambos son nil o "", no se dibujan caracteres laterales.
            left = '',
            right = '',

            -- Espacio entre los laterales y el texto.
            padding = 1,

            -- Highlight que se utilizará como base.
            highlight_group = "CavaPlayerTitle",

            -- Puedes utilizar un color hexadecimal:
            --
            --     foreground = "#FFFFFF"
            --
            -- o dejarlo en nil para conservar el foreground
            -- definido por el colorscheme.
            foreground = nil,

            -- Puede ser:
            --
            --     "#FFDF00"
            --
            -- o un highlight existente de Neovim:
            --
            --     "Pmenu"
            --     "Visual"
            --     "StatusLine"
            --     "CursorLine"
            --
            background = "WinBarNC",
        },

        empty_title = "No music playing",
        empty_artist = "Unknown artist",
        empty_album = "Unknown album",
        --- Espaciado horizontal entre el borde de la ventana y el contenido.
        padding = 1,
        --- Número de líneas vacías entre secciones.
        spacing = 1,
        controls = {
            previous = "[<<]",
            play = "[>]",
            pause = "[||]",
            next = "[>>]",
        },
        status_icons = {
            Playing = "●",
            Paused = "Ⅱ",
            Stopped = "■",
        },
        progress = {
            filled = "█",
            empty = "░",
            left = "[",
            right = "]",
        },
        artwork = {
            enabled = true,
            placeholder = "█",
            highlight = "CavaArtwork",
            max_width = 28,
            max_height = 18,
        },
        tracklist = {
            enabled = true,
            --- Modo de visualización de la tracklist:
            ---
            ---   "full"     -> Muestra TODAS las canciones de la tracklist
            ---                 (comportamiento por defecto/original).
            ---
            ---   "upcoming" -> Sólo muestra la canción ACTUAL y las que siguen
            ---                 (se omiten las anteriores). Da la sensación
            ---                 visual de "ir recorriendo" la playlist hacia
            ---                 adelante en vez de ver una lista estática
            ---                 completa. Si no se puede determinar cuál es la
            ---                 canción actual (no hay selección conocida), cae
            ---                 de vuelta a "full" automáticamente.
            ---
            --- Cambiar este valor en caliente con `Player:set_tracklist_view_mode(mode)`.
            view_mode = "upcoming",
            --- Separación entre el reproductor y la tracklist.
            spacing = 1,
            --- Separación entre canciones.
            item_spacing = 1,
            --- Ancho máximo de la miniatura.
            thumbnail_width = 6,
            --- Alto máximo de la miniatura.
            thumbnail_height = 3,
            --- Separación entre miniatura y texto.
            thumbnail_gap = 2,
            --- Separación entre información y duración.
            duration_gap = 2,
            --- Texto utilizado mientras no existe miniatura.
            placeholder = "▀▀",
            --- Símbolo de la canción actualmente seleccionada.
            selected = "▶",
            --- Highlight de la canción actual.
            selected_highlight = "Title",
            --- Highlight normal.
            title_highlight = "Normal",
            --- Highlight secundario.
            metadata_highlight = "Comment",
            --- Highlight de duración.
            duration_highlight = "Comment",

            artwork = {
                --- Activa/desactiva las miniaturas de artwork
                --- dentro de la tracklist.
                ---
                ---   true  -> muestra miniaturas.
                ---   false -> muestra únicamente información textual.
                enabled = true,

                --- Fuente visual de las miniaturas.
                ---
                ---   "image"       -> utiliza el artwork renderizado por Chafa.
                ---   "placeholder" -> utiliza siempre el placeholder genérico.
                source = "image",
            },

            -- Placeholder mostrado cuando todavía no existe una tracklist.
            empty_placeholder = {
                enabled = true,
                items = 3,
                title = "No tracklist available",
                artist = "Waiting for playlist data...",
                fake_title = "—",
                fake_metadata = "—",
                fake_duration = "--:--"
            },
        },
    },
}

-- ============================================================================
--                              CONSTRUCTOR
-- ============================================================================
---@param opts table|nil Configuración personalizada.
---@return table self Nueva instancia de Player.
function Player.new(opts)
    local self = setmetatable({}, Player)
    self.config = vim.tbl_deep_extend("force", Player.config, opts or {})
    --- Buffer/ventana del Music Manager.
    self.bufnr = nil
    self.winid = nil
    --- Artwork state.
    self.artwork_lines = nil
    self.artwork_highlights = nil
    self.artwork_highlight_cache = {}
    --- Metadata actual de la canción.
    self.music_metadata = nil
    --- Tracklist actual.
    self.tracklist = nil
    --- Miniaturas renderizadas de la tracklist.
    ---
    --- Cada entrada puede contener:
    --- {
    ---     lines = {...},
    ---     highlights = {...},
    --- }
    self.tracklist_artwork = {}
    --- Índice de la canción actualmente seleccionada.
    self.tracklist_selected = nil
    --- Namespace utilizado para aplicar y limpiar highlights.
    self.namespace = vim.api.nvim_create_namespace("cava.nvim.player")
    ----------------------------------------------------------------------
    -- Estado de renderizado incremental (ver comentario de arquitectura
    -- al inicio del archivo).
    ----------------------------------------------------------------------
    --- Caché de líneas/highlights por sección (ver `Player.SECTIONS`).
    self._section_cache = {}
    --- Flags de "sección pendiente de recalcular".
    self._dirty = {}
    for _, section in ipairs(Player.SECTIONS) do
        self._dirty[section] = true
    end
    --- Último ancho de contenido usado para renderizar (detecta resize).
    self._last_width = nil
    --- Últimas líneas efectivamente escritas en el buffer (para el diff).
    self._last_rendered_lines = nil
    return self
end

-- ============================================================================
--                              STATE
-- ============================================================================
---@return boolean `true` si el buffer existe y es válido.
function Player:is_valid()
    return self.bufnr ~= nil and vim.api.nvim_buf_is_valid(self.bufnr)
end

---@return boolean `true` si la ventana existe y es válida.
function Player:is_window_valid()
    return self.winid ~= nil and vim.api.nvim_win_is_valid(self.winid)
end

--- Limpia referencias a buffer/ventana que ya no existen.
function Player:cleanup_invalid_state()
    if self.winid and not vim.api.nvim_win_is_valid(self.winid) then
        self.winid = nil
    end
    if self.bufnr and not vim.api.nvim_buf_is_valid(self.bufnr) then
        self.bufnr = nil
    end
end

-- ============================================================================
--                              DIMENSIONS
-- ============================================================================
---@return number width Ancho actual en celdas (0 si la ventana no existe).
function Player:get_width()
    if not self:is_window_valid() then
        return 0
    end
    return vim.api.nvim_win_get_width(self.winid)
end

---@return number height Alto actual en líneas (0 si la ventana no existe).
function Player:get_height()
    if not self:is_window_valid() then
        return 0
    end
    return vim.api.nvim_win_get_height(self.winid)
end

-- ============================================================================
--                              BUFFER CREATION
-- ============================================================================
--- Crea el buffer del Music Manager (sin ventana todavía).
---
---@return number|nil bufnr Buffer creado, o `nil` si falló.
function Player:create_buffer()
    self.bufnr = vim.api.nvim_create_buf(false, true)
    if not self.bufnr then
        return nil
    end
    self:configure_buffer()
    return self.bufnr
end

--- Configura nombre/opciones del buffer del Music Manager.
function Player:configure_buffer()
    if not self:is_valid() then
        return
    end
    local bufnr = self.bufnr
    vim.api.nvim_buf_set_name(bufnr, self.config.name)
    vim.api.nvim_set_option_value("buftype", self.config.buftype, { buf = bufnr })
    vim.api.nvim_set_option_value("bufhidden", self.config.bufhidden, { buf = bufnr })
    vim.api.nvim_set_option_value("swapfile", self.config.swapfile, { buf = bufnr })
    vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
end

-- ============================================================================
--                              WINDOW
-- ============================================================================
--- Asocia una ventana (creada por Menu) a este buffer y aplica sus opciones.
---
---@param winid number ID de la ventana ya creada por Menu (p.ej. vía vsplit).
function Player:attach_window(winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end
    self.winid = winid
    if self:is_valid() then
        vim.api.nvim_win_set_buf(winid, self.bufnr)
    end
    self:configure_window()
end

--- Aplica las opciones visuales configuradas a la ventana del Music Manager.
function Player:configure_window()
    if not self:is_window_valid() then
        return
    end
    for option, value in pairs(self.config.window) do
        pcall(vim.api.nvim_set_option_value, option, value, { win = self.winid })
    end
    self:apply_background()
end

--- Aplica (o quita) el fondo oscurecido de la ventana. Seguro de llamar en
--- cualquier momento: recalcula el color a partir del "Normal" actual, así
--- que también sirve para refrescar tras un cambio de colorscheme.
function Player:apply_background()
    if not self:is_window_valid() then
        return
    end
    local bg = self.config.background or {}
    if not bg.enabled then
        pcall(vim.api.nvim_set_option_value, "winhighlight", "", { win = self.winid })
        return
    end
    local Theme = require("cava.core.menu.theme")
    local group = bg.highlight_group or "CavaPlayerNormal"
    if not Theme.setup_darker_normal(group, bg.darken) then
        -- "Normal" no tiene bg explícito (fondo transparente): no forzamos
        -- ningún color, dejamos la ventana como esté.
        return
    end
    local winhighlight = table.concat({
        "Normal:" .. group,
        "NormalNC:" .. group,
        "EndOfBuffer:" .. group,
        "SignColumn:" .. group,
    }, ",")
    pcall(vim.api.nvim_set_option_value, "winhighlight", winhighlight, { win = self.winid })
end

--- Aplica un ancho específico a la ventana (lo calcula y decide Menu).
---
---@param width number Ancho deseado en celdas.
function Player:apply_width(width)
    if not self:is_window_valid() then
        return
    end
    pcall(vim.api.nvim_win_set_width, self.winid, width)
end

-- ============================================================================
--                              TEXT HELPERS
-- ============================================================================
---@param text string Texto.
---@return number width Ancho visual en celdas.
function Player:display_width(text)
    return vim.fn.strdisplaywidth(text or "")
end

---@param text string Texto que se repetirá.
---@param width number Ancho máximo.
---@return string result Texto repetido hasta `width` (ancho visual).
function Player:repeat_display(text, width)
    text = tostring(text or "")
    if text == "" or width <= 0 then
        return ""
    end
    local text_width = self:display_width(text)
    if text_width <= 0 then
        return ""
    end
    local result = ""
    local current_width = 0
    while current_width + text_width <= width do
        result = result .. text
        current_width = current_width + text_width
    end
    return result
end

---@param text string Texto original.
---@param width number Ancho máximo.
---@return string Texto ajustado (con "..." si fue truncado).
function Player:truncate(text, width)
    text = tostring(text or "")
    if width <= 0 then
        return ""
    end
    if self:display_width(text) <= width then
        return text
    end
    if width <= 3 then
        return vim.fn.strcharpart(text, 0, width)
    end
    return vim.fn.strcharpart(text, 0, width - 3) .. "..."
end

---@param text string Texto.
---@param width number Ancho total.
---@return string Texto centrado.
function Player:center(text, width)
    text = self:truncate(text or "", width)
    local text_width = self:display_width(text)
    local remaining = math.max(width - text_width, 0)
    local left = math.floor(remaining / 2)
    local right = remaining - left
    return string.rep(" ", left) .. text .. string.rep(" ", right)
end

---@param width number Ancho de la línea.
---@return string Línea separadora.
function Player:music_separator(width)
    return string.rep(" ", width)
end

--- Configura y devuelve el highlight utilizado por el título.
---
--- `foreground` y `background` pueden ser:
---
---   - un color hexadecimal, por ejemplo "#FFFFFF";
---   - el nombre de un highlight existente de Neovim, por ejemplo "Pmenu".
---   - nil.
---
---@return string highlight_group Nombre del grupo de highlight.
function Player:get_title_highlight()
    local config = self.config.music.title_style or {}

    local group =
        config.highlight_group
        or "CavaPlayerTitle"

    local definition = {}

    --------------------------------------------------------------------------
    -- Foreground
    --------------------------------------------------------------------------
    if config.foreground ~= nil then
        if type(config.foreground) == "string" then
            if config.foreground:sub(1, 1) == "#" then
                definition.fg = config.foreground
            else
                local source =
                    vim.api.nvim_get_hl(
                        0,
                        {
                            name = config.foreground,
                            link = false,
                        }
                    )

                if source.fg then
                    definition.fg = source.fg
                end
            end
        end
    end

    --------------------------------------------------------------------------
    -- Background
    --------------------------------------------------------------------------
    if config.background ~= nil then
        if type(config.background) == "string" then
            if config.background:sub(1, 1) == "#" then
                definition.bg = config.background
            else
                local source =
                    vim.api.nvim_get_hl(
                        0,
                        {
                            name = config.background,
                            link = false,
                        }
                    )

                if source.bg then
                    definition.bg = source.bg
                end
            end
        end
    end

    --------------------------------------------------------------------------
    -- Si no se especificó foreground/background, heredamos del colorscheme.
    --------------------------------------------------------------------------
    if next(definition) == nil then
        vim.api.nvim_set_hl(
            0,
            group,
            {
                link = "Normal",
            }
        )
    else
        vim.api.nvim_set_hl(
            0,
            group,
            definition
        )
    end

    return group
end

function Player:get_title_glyph_highlight()
    local config =
        self.config.music.title_style or {}

    local group =
    "CavaPlayerTitleGlyph"

    local title_group =
        self:get_title_highlight()

    local title_hl =
        vim.api.nvim_get_hl(
            0,
            {
                name = title_group,
                link = false,
            }
        )

    local definition = {}

    if title_hl.bg then
        definition.fg = title_hl.bg
    end

    vim.api.nvim_set_hl(
        0,
        group,
        definition
    )

    return group
end

--- Agrega líneas vacías a una lista de líneas (separación entre secciones).
---
---@param lines table Lista de líneas que será modificada.
---@param count number Cantidad de líneas vacías.
function Player:add_music_spacing(lines, count)
    count = math.max(0, tonumber(count) or 0)
    for _ = 1, count do
        lines[#lines + 1] = ""
    end
end

-- ============================================================================
--                              ARTWORK HIGHLIGHTS
-- ============================================================================
--- Obtiene o crea un highlight dinámico para un color RGB devuelto por Chafa.
---
---@param fg string|nil Color foreground hexadecimal.
---@param bg string|nil Color background hexadecimal.
---@return string|nil Nombre del highlight generado.
function Player:get_artwork_highlight(fg, bg)
    if fg == vim.NIL then
        fg = nil
    end
    if bg == vim.NIL then
        bg = nil
    end
    if not fg and not bg then
        return nil
    end
    local fg_name = fg and fg:gsub("#", "") or "none"
    local bg_name = bg and bg:gsub("#", "") or "none"
    local name = "CavaArtwork_" .. fg_name .. "_" .. bg_name
    if self.artwork_highlight_cache[name] then
        return name
    end
    local definition = {}
    if fg then
        definition.fg = fg
    end
    if bg then
        definition.bg = bg
    end
    vim.api.nvim_set_hl(0, name, definition)
    self.artwork_highlight_cache[name] = true
    return name
end

-- ============================================================================
--                              ARTWORK
-- ============================================================================
--- Calcula el área máxima disponible para el artwork (bounding box).
---
---@param width number Ancho disponible.
---@param height number Alto disponible.
---@return number width Ancho máximo del artwork.
---@return number height Alto máximo del artwork.
function Player:calculate_artwork_size(width, height)
    local config = self.config.music.artwork
    if not config.enabled then
        return 0, 0
    end
    local max_width = math.max(1, math.floor(tonumber(config.max_width) or 15))
    local max_height = math.max(1, math.floor(tonumber(config.max_height) or 8))
    width = math.max(1, math.floor(tonumber(width) or 1))
    height = math.max(1, math.floor(tonumber(height) or 1))
    return math.min(max_width, width), math.min(max_height, height)
end

--- Genera el artwork temporal utilizado como placeholder.
---
---@param width number Ancho del placeholder.
---@param height number Alto del placeholder.
---@return table lines Líneas del placeholder.
---@return table highlights Highlights correspondientes.
function Player:build_artwork_placeholder(width, height)
    local config = self.config.music.artwork
    local lines = {}
    local highlights = {}
    for line = 0, height - 1 do
        lines[#lines + 1] = string.rep(config.placeholder, width)
        highlights[#highlights + 1] = {
            line = line,
            start_col = 0,
            end_col = self:display_width(lines[#lines]),
            hl = config.highlight,
        }
    end
    return lines, highlights
end

--- Construye la sección visual del artwork (artwork real o placeholder),
--- centrada horizontalmente dentro del ancho disponible.
---
---@param width number Ancho disponible.
---@return table lines Líneas del artwork.
---@return table highlights Highlights asociados.
function Player:build_music_artwork(width)
    local artwork_width, artwork_height =
        self:calculate_artwork_size(width, self:get_height())
    if artwork_width <= 0 or artwork_height <= 0 then
        return {}, {}
    end
    local artwork_lines
    local artwork_highlights
    if self.artwork_lines then
        artwork_lines = self.artwork_lines
        artwork_highlights = self.artwork_highlights or {}
    else
        artwork_lines, artwork_highlights =
            self:build_artwork_placeholder(artwork_width, artwork_height)
    end
    local lines = {}
    local highlights = {}
    for index, line in ipairs(artwork_lines) do
        local line_width = self:display_width(line)
        local remaining = math.max(width - line_width, 0)
        local offset = math.floor(remaining / 2)
        local centered = string.rep(" ", offset) .. line .. string.rep(" ", remaining - offset)
        lines[#lines + 1] = centered
        for _, highlight in ipairs(artwork_highlights) do
            if highlight.line == index - 1 then
                highlights[#highlights + 1] = {
                    line = #lines - 1,
                    start_col = highlight.start_col + offset,
                    end_col = highlight.end_col + offset,
                    hl = highlight.hl,
                    fg = highlight.fg,
                    bg = highlight.bg,
                }
            end
        end
    end
    return lines, highlights
end

--- Obtiene el espacio máximo disponible para el artwork (para pedirlo a Chafa).
---
---@return number width Ancho máximo.
---@return number height Alto máximo.
function Player:get_artwork_dimensions()
    local width = self:get_width()
    local height = self:get_height()
    if width <= 0 or height <= 0 then
        return 0, 0
    end
    local padding = math.max(0, tonumber(self.config.music.padding) or 0)
    local content_width = math.max(width - (padding * 2), 1)
    return self:calculate_artwork_size(content_width, height)
end

--- Establece la miniatura renderizada de una canción.
---
---@param index number Índice de la canción.
---@param lines table|nil Líneas renderizadas.
---@param highlights table|nil Highlights.
function Player:set_tracklist_artwork(index, lines, highlights)
    index = tonumber(index)
    if not index then
        return
    end
    if lines ~= nil and type(lines) ~= "table" then
        return
    end
    if highlights ~= nil and type(highlights) ~= "table" then
        return
    end
    if lines == nil then
        self.tracklist_artwork[index] = nil
    else
        self.tracklist_artwork[index] = {
            lines = lines,
            highlights = highlights or {},
        }
    end
    -- Sólo la tracklist depende de esto: el resto del buffer no se toca.
    self:_refresh("tracklist")
end

--- Elimina todas las miniaturas de la tracklist.
function Player:clear_tracklist_artwork()
    self.tracklist_artwork = {}
    self:_refresh("tracklist")
end

--- Elimina la tracklist.
function Player:clear_tracklist()
    self.tracklist = nil
    self.tracklist_artwork = {}
    self.tracklist_selected = nil
    self:_refresh("tracklist")
end

--- Establece la canción seleccionada dentro de la tracklist.
---
---@param index number|nil Índice de la canción.
function Player:set_tracklist_selected(index)
    if index ~= nil then
        index = tonumber(index)
        if not index then
            return
        end
    end
    self.tracklist_selected = index
    self:_refresh("tracklist")
end

--- Establece un artwork previamente renderizado por Chafa.
---
---@param lines table|nil Líneas ANSI ya convertidas a texto.
---@param highlights table|nil Instrucciones de color.
function Player:set_artwork(lines, highlights)
    if lines ~= nil and type(lines) ~= "table" then
        return
    end
    if highlights ~= nil and type(highlights) ~= "table" then
        return
    end
    self.artwork_lines = lines
    self.artwork_highlights = highlights or {}
    self:_refresh("artwork")
end

--- Elimina el artwork actual (vuelve a mostrarse el placeholder).
function Player:clear_artwork()
    self.artwork_lines = nil
    self.artwork_highlights = nil
    self:_refresh("artwork")
end

-- ============================================================================
--                              MUSIC LAYOUT HELPERS
-- ============================================================================
---@param position number|nil Posición actual en segundos.
---@param duration number|nil Duración total en segundos.
---@param width number Ancho total de la barra.
---@return string Barra de progreso.
function Player:music_progress(position, duration, width)
    local config = self.config.music.progress
    position = tonumber(position) or 0
    duration = tonumber(duration) or 0
    local left_width = self:display_width(config.left)
    local right_width = self:display_width(config.right)
    local available = width - left_width - right_width
    if available <= 0 then
        return ""
    end
    local ratio = 0
    if duration > 0 then
        ratio = position / duration
    end
    ratio = math.max(0, math.min(ratio, 1))
    local filled_width = math.floor(available * ratio)
    local empty_width = available - filled_width
    local filled = self:repeat_display(config.filled, filled_width)
    local empty = self:repeat_display(config.empty, empty_width)
    return config.left .. filled .. empty .. config.right
end

---@param seconds number|nil Tiempo en segundos.
---@return string Tiempo formateado MM:SS.
function Player:format_time(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local minutes = math.floor(seconds / 60)
    local remaining = seconds % 60
    return string.format("%02d:%02d", minutes, remaining)
end

---@param status string|nil Estado de reproducción.
---@return string Icono.
function Player:music_status_icon(status)
    return self.config.music.status_icons[status] or "?"
end

-- ============================================================================
--                              TRACKLIST HELPERS
-- ============================================================================
---@param seconds number|nil Duración en segundos.
---@return string Duración MM:SS.
function Player:tracklist_duration(seconds)
    if seconds == nil then
        return ""
    end
    return self:format_time(seconds)
end

---@param item table Elemento de la tracklist.
---@return boolean True si el elemento contiene información válida.
function Player:is_valid_tracklist_item(item)
    if type(item) ~= "table" then
        return false
    end
    return (
        item.title ~= nil
        or item.artist ~= nil
        or item.album ~= nil
        or item.track_id ~= nil
        or item.url ~= nil
    )
end

---@param item table Elemento de la tracklist.
---@param index number Índice del elemento.
---@return boolean True si es la canción seleccionada.
function Player:is_tracklist_item_selected(item, index)
    if type(item) ~= "table" then
        return false
    end
    if item.selected == true then
        return true
    end
    if self.tracklist_selected ~= nil then
        return self.tracklist_selected == index
    end
    return false
end

---@return table lines Miniatura placeholder.
---@return table highlights Highlights de la miniatura.
function Player:build_tracklist_thumbnail_placeholder()
    local config = self.config.music.tracklist

    local width = math.max(
        1,
        tonumber(config.thumbnail_width) or 6
    )

    local height = math.max(
        1,
        tonumber(config.thumbnail_height) or 3
    )

    local lines = {}
    local highlights = {}

    for line = 0, height - 1 do
        lines[#lines + 1] =
            self:repeat_display(
                config.placeholder,
                width
            )

        highlights[#highlights + 1] = {
            line = line,
            start_col = 0,
            end_col = self:display_width(
                lines[#lines]
            ),
            hl = config.metadata_highlight,
        }
    end

    return lines, highlights
end

---@param index number Índice de la canción.
---@return table|nil artwork Información de miniatura renderizada.
function Player:get_tracklist_artwork(index)
    local artwork = self.tracklist_artwork[index]
    if type(artwork) ~= "table" then
        return nil
    end
    if type(artwork.lines) ~= "table" then
        return nil
    end
    return artwork
end

---@param tracklist table|nil Tracklist normalizada.
---@return number|nil index Índice de la canción actual, o `nil` si no se
---puede determinar (ni `tracklist_selected` está establecido, ni ningún
---elemento trae `selected = true`).
function Player:get_tracklist_current_index(tracklist)
    if self.tracklist_selected ~= nil then
        return self.tracklist_selected
    end
    if type(tracklist) == "table" then
        for index, item in ipairs(tracklist) do
            if type(item) == "table" and item.selected == true then
                return index
            end
        end
    end
    return nil
end

-- ============================================================================
--                       TRACKLIST VIEW MODE
-- ============================================================================
--- Cambia el modo de visualización de la tracklist ("full" o "upcoming")
--- y refresca sólo la sección "tracklist" si el valor realmente cambió.
---
---@param mode string "full" | "upcoming"
function Player:set_tracklist_view_mode(mode)
    if mode ~= "full" and mode ~= "upcoming" then
        return
    end
    if self.config.music.tracklist.view_mode == mode then
        return
    end
    self.config.music.tracklist.view_mode = mode
    self:_refresh("tracklist")
end

--- Alterna entre "full" y "upcoming".
function Player:toggle_tracklist_view_mode()
    local current = self.config.music.tracklist.view_mode or "full"
    self:set_tracklist_view_mode(current == "full" and "upcoming" or "full")
end

---@param item table Elemento de la tracklist.
---@param index number Índice del elemento.
---@param width number Ancho disponible.
---@return table lines Líneas generadas.
---@return table highlights Highlights generados.
function Player:build_tracklist_item(item, index, width)
    local config = self.config.music.tracklist
    local lines = {}
    local highlights = {}

    local selected =
        self:is_tracklist_item_selected(item, index)

    local title =
        tostring(item.title or "Unknown title")

    local artist =
        tostring(item.artist or "")

    local album =
        tostring(item.album or "")

    local duration =
        self:tracklist_duration(item.duration)

    --------------------------------------------------------------------------
    -- Artwork
    --------------------------------------------------------------------------

    local artwork_config =
        config.artwork or {}

    local artwork_enabled =
        artwork_config.enabled ~= false

    local use_chafa =
        artwork_config.source ~= "placeholder"

    local thumbnail_lines = {}
    local thumbnail_highlights = {}

    local thumbnail_width = 0
    local thumbnail_height = 0
    local gap = ""

    if artwork_enabled then
        thumbnail_width = math.max(
            1,
            tonumber(config.thumbnail_width) or 6
        )

        thumbnail_height = math.max(
            1,
            tonumber(config.thumbnail_height) or 3
        )

        gap = string.rep(
            " ",
            math.max(
                1,
                tonumber(config.thumbnail_gap) or 2
            )
        )

        if use_chafa then
            local artwork =
                self:get_tracklist_artwork(index)

            if artwork then
                thumbnail_lines =
                    artwork.lines

                thumbnail_highlights =
                    artwork.highlights or {}
            else
                thumbnail_lines,
                thumbnail_highlights =
                    self:build_tracklist_thumbnail_placeholder()
            end
        else
            thumbnail_lines,
            thumbnail_highlights =
                self:build_tracklist_thumbnail_placeholder()
        end
    end

    --------------------------------------------------------------------------
    -- Información
    --------------------------------------------------------------------------

    local selected_prefix = ""

    if selected then
        selected_prefix =
            config.selected .. " "
    end

    local selected_prefix_width =
        self:display_width(selected_prefix)

    local duration_width =
        self:display_width(duration)

    local duration_gap =
        string.rep(
            " ",
            math.max(
                1,
                tonumber(config.duration_gap) or 2
            )
        )

    local duration_gap_width =
        self:display_width(duration_gap)

    --------------------------------------------------------------------------
    -- Metadata
    --------------------------------------------------------------------------

    local metadata = artist

    if album ~= "" then
        if metadata ~= "" then
            metadata = metadata .. " · "
        end

        metadata = metadata .. album
    end

    --------------------------------------------------------------------------
    -- Modo SIN artwork
    --------------------------------------------------------------------------

    if not artwork_enabled then
        local info_width =
            width
            - selected_prefix_width
            - duration_gap_width
            - duration_width

        info_width =
            math.max(info_width, 1)

        local title_width =
            math.max(
                1,
                info_width
            )

        local rendered_title =
            self:truncate(
                title,
                title_width
            )

        local title_line =
            selected_prefix
            .. rendered_title

        ----------------------------------------------------------------------
        -- Duración
        ----------------------------------------------------------------------

        if duration ~= "" then
            local current_width =
                self:display_width(title_line)

            local remaining =
                width
                - current_width
                - duration_width

            if remaining >= duration_gap_width then
                title_line =
                    title_line
                    .. string.rep(
                        " ",
                        remaining
                    )
                    .. duration
            else
                title_line =
                    self:truncate(
                        title_line,
                        math.max(
                            1,
                            width - duration_width
                        )
                    )
                    .. duration
            end
        end

        title_line =
            self:truncate(
                title_line,
                width
            )

        lines[#lines + 1] =
            title_line

        ----------------------------------------------------------------------
        -- Metadata
        ----------------------------------------------------------------------

        if metadata ~= "" then
            metadata =
                self:truncate(
                    metadata,
                    width
                )

            lines[#lines + 1] =
                metadata
        else
            lines[#lines + 1] = ""
        end

        ----------------------------------------------------------------------
        -- Highlights
        ----------------------------------------------------------------------

        local title_start =
            selected_prefix_width

        local rendered_title_width =
            self:display_width(
                rendered_title
            )

        highlights[#highlights + 1] = {
            line = 0,
            start_col = title_start,
            end_col = math.min(
                self:display_width(title_line),
                title_start
                + rendered_title_width
            ),
            hl =
                selected
                and config.selected_highlight
                or config.title_highlight,
        }

        if metadata ~= "" then
            highlights[#highlights + 1] = {
                line = 1,
                start_col = 0,
                end_col = math.min(
                    self:display_width(lines[2]),
                    self:display_width(metadata)
                ),
                hl = config.metadata_highlight,
            }
        end

        return lines, highlights
    end

    --------------------------------------------------------------------------
    -- Modo CON artwork
    --------------------------------------------------------------------------

    local info_width =
        width
        - thumbnail_width
        - self:display_width(gap)
        - selected_prefix_width
        - duration_gap_width
        - duration_width

    info_width =
        math.max(info_width, 1)

    local title_width =
        info_width

    if selected then
        title_width =
            math.max(
                1,
                info_width
                - selected_prefix_width
            )
    end

    local rendered_title =
        self:truncate(
            title,
            title_width
        )

    local title_line =
        selected_prefix
        .. rendered_title

    metadata =
        self:truncate(
            metadata,
            math.max(1, info_width)
        )

    --------------------------------------------------------------------------
    -- Render artwork
    --------------------------------------------------------------------------

    local artwork_height =
        math.min(
            thumbnail_height,
            #thumbnail_lines
        )

    for row = 1, artwork_height do
        local thumbnail =
            thumbnail_lines[row] or ""

        local thumbnail_visual_width =
            self:display_width(thumbnail)

        if thumbnail_visual_width < thumbnail_width then
            thumbnail =
                thumbnail
                .. string.rep(
                    " ",
                    thumbnail_width
                    - thumbnail_visual_width
                )
        end

        local line

        if row == 1 then
            line =
                thumbnail
                .. gap
                .. title_line

            if duration ~= "" then
                local current_width =
                    self:display_width(line)

                local remaining =
                    width
                    - current_width
                    - duration_width

                if remaining >= duration_gap_width then
                    line =
                        line
                        .. string.rep(
                            " ",
                            remaining
                        )
                        .. duration
                end
            end
        elseif row == 2 then
            line =
                thumbnail
                .. gap
                .. metadata
        else
            line = thumbnail
        end

        line =
            self:truncate(
                line,
                width
            )

        lines[#lines + 1] =
            line

        for _, highlight in
        ipairs(thumbnail_highlights)
        do
            if highlight.line == row - 1 then
                highlights[#highlights + 1] = {
                    line = #lines - 1,
                    start_col = highlight.start_col,
                    end_col = highlight.end_col,
                    hl = highlight.hl,
                    fg = highlight.fg,
                    bg = highlight.bg,
                }
            end
        end
    end

    --------------------------------------------------------------------------
    -- Highlights de texto
    --------------------------------------------------------------------------

    local title_start =
        thumbnail_width
        + self:display_width(gap)

    if selected then
        title_start =
            title_start
            + selected_prefix_width
    end

    highlights[#highlights + 1] = {
        line = 0,
        start_col = title_start,
        end_col = math.min(
            self:display_width(lines[1]),
            title_start
            + self:display_width(
                rendered_title
            )
        ),
        hl =
            selected
            and config.selected_highlight
            or config.title_highlight,
    }

    if metadata ~= "" and #lines >= 2 then
        local metadata_start =
            thumbnail_width
            + self:display_width(gap)

        highlights[#highlights + 1] = {
            line = 1,
            start_col = metadata_start,
            end_col = math.min(
                self:display_width(lines[2]),
                metadata_start
                + self:display_width(metadata)
            ),
            hl = config.metadata_highlight,
        }
    end

    return lines, highlights
end

---@param width number Ancho disponible.
---@return table lines Líneas del placeholder.
---@return table highlights Highlights del placeholder.
function Player:build_tracklist_placeholder(width)
    local config = self.config.music.tracklist
    local placeholder = config.empty_placeholder or {}

    if placeholder.enabled == false then
        return {}, {}
    end

    local item_count = math.max(
        1,
        tonumber(placeholder.items) or 3
    )

    local lines = {}
    local highlights = {}

    self:add_music_spacing(
        lines,
        config.spacing
    )

    -- Separador superior.
    -- lines[#lines + 1] =
    --     self:music_separator(width)
    --
    -- self:add_music_spacing(lines, 1)

    -- Título del estado vacío.
    local title =
        tostring(
            placeholder.title
            or "No tracklist available"
        )

    lines[#lines + 1] =
        self:center(
            self:truncate(title, width),
            width
        )

    highlights[#highlights + 1] = {
        line = #lines - 1,
        start_col = 0,
        end_col = self:display_width(lines[#lines]),
        hl = config.title_highlight,
    }

    local artist =
        tostring(
            placeholder.artist
            or "Waiting for playlist data..."
        )

    lines[#lines + 1] =
        self:center(
            self:truncate(artist, width),
            width
        )

    highlights[#highlights + 1] = {
        line = #lines - 1,
        start_col = 0,
        end_col = self:display_width(lines[#lines]),
        hl = config.metadata_highlight,
    }

    self:add_music_spacing(lines, 1)

    -- Separador superior.
    lines[#lines + 1] =
        self:music_separator(width)

    self:add_music_spacing(lines, 1)


    --------------------------------------------------------------------------
    -- Filas fantasma de canciones.
    --------------------------------------------------------------------------
    for index = 1, item_count do
        local thumbnail_lines,
        thumbnail_highlights =
            self:build_tracklist_thumbnail_placeholder()

        local thumbnail_width = math.max(
            1,
            tonumber(config.thumbnail_width) or 6
        )

        local thumbnail_gap = string.rep(
            " ",
            math.max(
                1,
                tonumber(config.thumbnail_gap) or 2
            )
        )

        local fake_title = config.empty_placeholder.fake_title or "—"
        local fake_metadata = config.empty_placeholder.fake_metadata or "—"
        local fake_duration = config.empty_placeholder.fake_duration or "--:--"

        local duration_width =
            self:display_width(fake_duration)

        local available =
            width
            - thumbnail_width
            - self:display_width(thumbnail_gap)
            - duration_width
            - math.max(
                1,
                tonumber(config.duration_gap) or 2
            )

        available = math.max(1, available)

        local title =
            self:truncate(
                fake_title,
                available
            )

        local metadata =
            self:truncate(
                fake_metadata,
                available
            )

        local start_line = #lines

        for row = 1, #thumbnail_lines do
            local thumbnail =
                thumbnail_lines[row] or ""

            local thumbnail_visual_width =
                self:display_width(thumbnail)

            if thumbnail_visual_width < thumbnail_width then
                thumbnail =
                    thumbnail
                    .. string.rep(
                        " ",
                        thumbnail_width
                        - thumbnail_visual_width
                    )
            end

            local line

            if row == 1 then
                line =
                    thumbnail
                    .. thumbnail_gap
                    .. title

                local current_width =
                    self:display_width(line)

                local remaining =
                    width
                    - current_width
                    - duration_width

                if remaining >= 1 then
                    line =
                        line
                        .. string.rep(
                            " ",
                            remaining
                        )
                        .. fake_duration
                end
            elseif row == 2 then
                line =
                    thumbnail
                    .. thumbnail_gap
                    .. metadata
            else
                line = thumbnail
            end

            lines[#lines + 1] =
                self:truncate(line, width)

            for _, highlight in ipairs(
                thumbnail_highlights
            ) do
                if highlight.line == row - 1 then
                    highlights[#highlights + 1] = {
                        line = start_line + row - 1,
                        start_col = highlight.start_col,
                        end_col = highlight.end_col,
                        hl = highlight.hl,
                        fg = highlight.fg,
                        bg = highlight.bg,
                    }
                end
            end
        end

        if index < item_count then
            self:add_music_spacing(
                lines,
                config.item_spacing
            )
        end
    end

    return lines, highlights
end

---@param tracklist table|nil Tracklist normalizada.
---@param width number Ancho disponible.
---@return table lines Líneas.
---@return table highlights Highlights.
function Player:build_music_tracklist(tracklist, width)
    local config = self.config.music.tracklist
    if not config.enabled then
        return {}, {}
    end
    if type(tracklist) ~= "table" then
        return self:build_tracklist_placeholder(width)
    end

    if #tracklist == 0 then
        return self:build_tracklist_placeholder(width)
    end

    --------------------------------------------------------------------------
    -- Modo "upcoming": determinar desde qué índice se debe mostrar.
    --
    -- Si no hay forma de saber cuál es la canción actual (todavía no llegó
    -- ninguna selección), se cae de vuelta a "full" — mostrar nada sería
    -- peor experiencia que mostrar la lista completa mientras se resuelve.
    --------------------------------------------------------------------------
    local view_mode = config.view_mode or "full"
    local current_index = nil
    if view_mode == "upcoming" then
        current_index = self:get_tracklist_current_index(tracklist)
    end
    local upcoming_active = view_mode == "upcoming" and current_index ~= nil

    local valid_items = {}
    for index, item in ipairs(tracklist) do
        if self:is_valid_tracklist_item(item) then
            if not upcoming_active or index >= current_index then
                valid_items[#valid_items + 1] = {
                    item = item,
                    index = index,
                }
            end
        end
    end
    if #valid_items == 0 then
        return {}, {}
    end

    local lines = {}
    local highlights = {}
    self:add_music_spacing(lines, config.spacing)

    -- Separador visual (o encabezado "Up next" en modo upcoming, si se
    -- configuró uno).
    if upcoming_active and config.upcoming_header and config.upcoming_header ~= "" then
        lines[#lines + 1] = self:center(
            self:truncate(config.upcoming_header, width),
            width
        )
    else
        lines[#lines + 1] = self:music_separator(width)
    end
    self:add_music_spacing(lines, 1)

    for item_position, entry in ipairs(valid_items) do
        local item_lines, item_highlights =
            self:build_tracklist_item(
                entry.item,
                entry.index,
                width
            )
        local start_line = #lines
        for _, line in ipairs(item_lines) do
            lines[#lines + 1] = line
        end
        for _, highlight in ipairs(item_highlights) do
            highlights[#highlights + 1] = {
                line = start_line + highlight.line,
                start_col = highlight.start_col,
                end_col = highlight.end_col,
                hl = highlight.hl,
                fg = highlight.fg,
                bg = highlight.bg,
            }
        end
        if item_position < #valid_items then
            self:add_music_spacing(
                lines,
                config.item_spacing
            )
        end
    end
    return lines, highlights
end

-- ============================================================================
--                     SECTION BUILDERS (RENDERIZADO INDEPENDIENTE)
-- ============================================================================
-- Cada builder recibe el ancho de contenido (ya sin padding horizontal) y
-- devuelve `lines, highlights`. Los `highlight.line` son RELATIVOS al inicio
-- de su propia sección; `_assemble()` se encarga de convertirlos a líneas
-- absolutas del buffer.
-- ============================================================================

---@param width number Ancho de contenido.
---@return table lines Líneas del header.
---@return table highlights Highlights del header.
function Player:_build_section_header(width)
    local config = self.config.music
    local title_style = config.title_style or {}

    if title_style.enabled ~= true then
        local lines = {
            self:center(
                config.title,
                width
            ),
            self:music_separator(width),
        }

        return lines, {}
    end

    local title =
        tostring(
            config.title
            or "MUSIC"
        )

    local padding = math.max(
        0,
        tonumber(title_style.padding) or 1
    )

    local left =
        title_style.left ~= nil
        and tostring(title_style.left)
        or ""

    local right =
        title_style.right ~= nil
        and tostring(title_style.right)
        or ""

    --------------------------------------------------------------------------
    -- El área coloreada es únicamente:
    --
    --     " MUSIC "
    --
    -- Los glyphs quedan fuera del background.
    --------------------------------------------------------------------------
    local padding_text =
        string.rep(" ", padding)

    local background_content =
        padding_text
        .. title
        .. padding_text

    local has_capsule =
        left ~= ""
        and right ~= ""

    local line_content

    if has_capsule then
        line_content =
            left
            .. background_content
            .. right
    else
        line_content = background_content
    end

    --------------------------------------------------------------------------
    -- display_width() se utiliza SOLAMENTE para calcular el layout visual.
    --------------------------------------------------------------------------
    local content_width =
        self:display_width(line_content)

    if content_width > width then
        local lines = {
            self:center(
                self:truncate(
                    title,
                    width
                ),
                width
            ),
            self:music_separator(width),
        }

        return lines, {}
    end

    local remaining =
        width - content_width

    local left_offset =
        math.floor(remaining / 2)

    local right_offset =
        remaining - left_offset

    local line =
        string.rep(" ", left_offset)
        .. line_content
        .. string.rep(" ", right_offset)

    local highlights = {}

    --------------------------------------------------------------------------
    -- Highlight del fondo.
    --
    -- IMPORTANTE:
    --
    -- nvim_buf_add_highlight() utiliza COLUMNAS EN BYTES.
    --
    -- Por eso aquí NO usamos display_width().
    --------------------------------------------------------------------------
    local background_start =
        left_offset
        + #left

    local background_end =
        background_start
        + #background_content

    local highlight_group =
        self:get_title_highlight()

    highlights[#highlights + 1] = {
        line = 0,
        start_col = background_start,
        end_col = background_end,
        hl = highlight_group,
    }

    --------------------------------------------------------------------------
    -- Glyph izquierdo.
    --
    -- Debe tener como foreground exactamente el color del background.
    --------------------------------------------------------------------------
    if left ~= "" then
        local glyph_highlight =
            self:get_title_glyph_highlight()

        highlights[#highlights + 1] = {
            line = 0,
            start_col = left_offset,
            end_col = left_offset + #left,
            hl = glyph_highlight,
        }
    end

    --------------------------------------------------------------------------
    -- Glyph derecho.
    --
    -- Empieza EXACTAMENTE donde termina el background.
    --------------------------------------------------------------------------
    if right ~= "" then
        local glyph_highlight =
            self:get_title_glyph_highlight()

        highlights[#highlights + 1] = {
            line = 0,
            start_col = background_end,
            end_col = background_end + #right,
            hl = glyph_highlight,
        }
    end

    local lines = {
        line,
        self:music_separator(width),
    }

    return lines, highlights
end

---@param width number Ancho de contenido.
function Player:_build_section_artwork(width)
    local lines, highlights = self:build_music_artwork(width)
    -- Copiamos para no mutar la tabla devuelta por build_music_artwork.
    local section_lines = {}
    for _, line in ipairs(lines) do
        section_lines[#section_lines + 1] = line
    end
    self:add_music_spacing(section_lines, self.config.music.spacing)
    return section_lines, highlights
end

---@param width number Ancho de contenido.
function Player:_build_section_meta(width)
    local config = self.config.music
    local metadata = self.music_metadata or {}
    local provider = metadata.provider or "Unknown"
    local status = metadata.status or "Stopped"
    local title = metadata.title or config.empty_title
    local artist = metadata.artist or config.empty_artist
    local album = metadata.album or config.empty_album
    local lines = {}
    local status_icon = self:music_status_icon(status)
    local status_line = status_icon .. " " .. status .. "  " .. provider
    lines[#lines + 1] = self:center(status_line, width)
    self:add_music_spacing(lines, config.spacing)
    lines[#lines + 1] = self:center(self:truncate(title, width), width)
    lines[#lines + 1] = self:center(self:truncate(artist, width), width)
    if album ~= "" then
        lines[#lines + 1] = self:center(self:truncate(album, width), width)
    end
    self:add_music_spacing(lines, config.spacing)
    return lines, {}
end

---@param width number Ancho de contenido.
function Player:_build_section_progress(width)
    local config = self.config.music
    local metadata = self.music_metadata or {}
    local position = tonumber(metadata.position) or 0
    local duration = tonumber(metadata.duration) or 0
    local lines = {}
    local progress = self:music_progress(position, duration, width)
    if progress ~= "" then
        lines[#lines + 1] = self:center(progress, width)
    end
    local time_line = self:format_time(position) .. " / " .. self:format_time(duration)
    lines[#lines + 1] = self:center(time_line, width)
    self:add_music_spacing(lines, config.spacing)
    return lines, {}
end

---@param width number Ancho de contenido.
function Player:_build_section_controls(width)
    local config = self.config.music
    local metadata = self.music_metadata or {}
    local status = metadata.status or "Stopped"
    local play_control = status == "Playing" and config.controls.pause or config.controls.play
    local controls = table.concat({ config.controls.previous, play_control, config.controls.next }, "  ")
    local lines = {
        self:center(controls, width),
        self:music_separator(width),
    }
    return lines, {}
end

---@param width number Ancho de contenido.
function Player:_build_section_tracklist(width)
    return self:build_music_tracklist(self.tracklist, width)
end

-- ============================================================================
--                        DIRTY TRACKING / RENDER PIPELINE
-- ============================================================================

---@param section string Nombre de una sección válida (`Player.SECTIONS`).
function Player:mark_dirty(section)
    if section and self._dirty[section] ~= nil then
        self._dirty[section] = true
    end
end

--- Marca todas las secciones como pendientes de recalcular.
function Player:mark_all_dirty()
    for _, section in ipairs(Player.SECTIONS) do
        self._dirty[section] = true
    end
end

--- Marca una o varias secciones como "dirty" y dispara un render
--- incremental (sólo esas secciones se reconstruyen; el resto se reutiliza
--- de la caché).
---
---@param sections string|table|nil Nombre de sección, lista de nombres, o
---nil/{} si no hay nada que recalcular (aun así se intentará escribir por
---si hubiera cambios pendientes).
function Player:_refresh(sections)
    if type(sections) == "string" then
        sections = { sections }
    end
    for _, section in ipairs(sections or {}) do
        self:mark_dirty(section)
    end
    self:_render_now()
end

--- Ensambla el layout final concatenando las secciones cacheadas, ajusta
--- los `line` de los highlights según el offset de cada sección y aplica
--- el padding horizontal (incluyendo el corrimiento de columnas de los
--- highlights, que en el layout original no se ajustaba).
---
---@return table lines Líneas finales del buffer.
---@return table highlights Highlights finales (line/col absolutos).
function Player:_assemble()
    local lines = {}
    local highlights = {}
    for _, section in ipairs(Player.SECTIONS) do
        local cache = self._section_cache[section]
        if cache then
            local offset = #lines
            for _, line in ipairs(cache.lines) do
                lines[#lines + 1] = line
            end
            for _, highlight in ipairs(cache.highlights) do
                highlights[#highlights + 1] = {
                    line = offset + highlight.line,
                    start_col = highlight.start_col,
                    end_col = highlight.end_col,
                    hl = highlight.hl,
                    fg = highlight.fg,
                    bg = highlight.bg,
                }
            end
        end
    end
    local padding = math.max(0, tonumber(self.config.music.padding) or 0)
    if padding > 0 then
        local pad = string.rep(" ", padding)
        for index, line in ipairs(lines) do
            lines[index] = pad .. line .. pad
        end
        for _, highlight in ipairs(highlights) do
            highlight.start_col = highlight.start_col + padding
            highlight.end_col = highlight.end_col + padding
        end
    end
    return lines, highlights
end

--- Aplica un único highlight resolviendo colores dinámicos de artwork.
function Player:_apply_highlight(highlight)
    local highlight_name = highlight.hl
    if (highlight.fg and highlight.fg ~= vim.NIL) or (highlight.bg and highlight.bg ~= vim.NIL) then
        highlight_name = self:get_artwork_highlight(highlight.fg, highlight.bg)
    end
    if highlight_name then
        vim.api.nvim_buf_add_highlight(
            self.bufnr,
            self.namespace,
            highlight_name,
            highlight.line,
            highlight.start_col,
            highlight.end_col
        )
    end
end

--- Escribe `lines`/`highlights` en el buffer de forma incremental: calcula
--- el prefijo y sufijo de líneas que NO cambiaron respecto al último
--- render y sólo reescribe (y sólo re-highlightea) el rango intermedio que
--- sí cambió. Si nada cambió, no toca el buffer.
---
---@param lines table Líneas finales (ya con padding aplicado).
---@param highlights table Highlights finales (línea/columna absolutos).
function Player:_write_lines_and_highlights(lines, highlights)
    -- Primer render: no hay nada previo con qué diffear.
    if not self._last_rendered_lines then
        vim.api.nvim_set_option_value("modifiable", true, { buf = self.bufnr })
        vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_clear_namespace(self.bufnr, self.namespace, 0, -1)
        for _, highlight in ipairs(highlights) do
            self:_apply_highlight(highlight)
        end
        vim.api.nvim_set_option_value("modifiable", false, { buf = self.bufnr })
        self._last_rendered_lines = lines
        return
    end

    local old = self._last_rendered_lines
    local old_len = #old
    local new_len = #lines

    -- Prefijo común.
    local max_common = math.min(old_len, new_len)
    local prefix = 0
    while prefix < max_common and old[prefix + 1] == lines[prefix + 1] do
        prefix = prefix + 1
    end

    if prefix == old_len and prefix == new_len then
        -- No hay ningún cambio real: no tocamos el buffer.
        self._last_rendered_lines = lines
        return
    end

    -- Sufijo común (sin solaparse con el prefijo).
    local max_suffix = max_common - prefix
    local suffix = 0
    while suffix < max_suffix and old[old_len - suffix] == lines[new_len - suffix] do
        suffix = suffix + 1
    end

    local replace_start = prefix             -- 0-indexed, inclusive
    local replace_end_old = old_len - suffix -- 0-indexed, exclusive (buffer viejo)
    local new_slice = {}
    for i = prefix + 1, new_len - suffix do
        new_slice[#new_slice + 1] = lines[i]
    end
    local replace_end_new = prefix + #new_slice -- exclusivo, ya en el buffer nuevo

    vim.api.nvim_set_option_value("modifiable", true, { buf = self.bufnr })
    vim.api.nvim_buf_set_lines(self.bufnr, replace_start, replace_end_old, false, new_slice)

    -- Sólo limpiamos highlights en el rango que efectivamente cambió; el
    -- resto son extmarks y se desplazan solos si hubo inserciones/borrados.
    vim.api.nvim_buf_clear_namespace(self.bufnr, self.namespace, replace_start, replace_end_new)
    for _, highlight in ipairs(highlights) do
        if highlight.line >= replace_start and highlight.line < replace_end_new then
            self:_apply_highlight(highlight)
        end
    end

    vim.api.nvim_set_option_value("modifiable", false, { buf = self.bufnr })
    self._last_rendered_lines = lines
end

--- Núcleo del render incremental: reconstruye sólo las secciones "dirty",
--- ensambla el layout completo y lo escribe con diff. Detecta cambios de
--- ancho de ventana automáticamente y, en ese caso, fuerza el recálculo de
--- todo (el ancho afecta centrado/truncado de cada sección).
function Player:_render_now()
    if not self:is_valid() then
        return
    end

    local window_width = self:get_width()
    if window_width <= 0 then
        window_width = 40
    end
    if window_width ~= self._last_width then
        self:mark_all_dirty()
        self._last_width = window_width
    end

    local any_dirty = false
    for _, section in ipairs(Player.SECTIONS) do
        if self._dirty[section] then
            any_dirty = true
            break
        end
    end
    -- Si nada cambió y ya habíamos renderizado antes, no hay nada que hacer.
    if not any_dirty and self._last_rendered_lines ~= nil then
        return
    end

    local padding = math.max(0, tonumber(self.config.music.padding) or 0)
    local content_width = math.max(window_width - (padding * 2), 1)

    for _, section in ipairs(Player.SECTIONS) do
        if self._dirty[section] then
            local builder = self["_build_section_" .. section]
            local section_lines, section_highlights = builder(self, content_width)
            self._section_cache[section] = {
                lines = section_lines,
                highlights = section_highlights,
            }
            self._dirty[section] = false
        end
    end

    local lines, highlights = self:_assemble()
    self:_write_lines_and_highlights(lines, highlights)
end

-- ============================================================================
--                              RENDER (API PÚBLICA)
-- ============================================================================
--- Renderiza la metadata actual en el buffer del Music Manager, forzando
--- el recálculo de TODAS las secciones (portada, meta, progreso, controles
--- y tracklist). La escritura al buffer sigue siendo incremental: si tras
--- recalcular todo el contenido resulta idéntico al anterior, no se toca
--- el buffer.
---
--- Para actualizaciones puntuales (lo normal en cada tick) usa
--- `update_music`, `set_artwork`, `update_tracklist`, etc. — esos métodos
--- sólo recalculan la sección afectada.
function Player:render()
    self:mark_all_dirty()
    self:_render_now()
end

--- Actualiza la tracklist y refresca sólo la sección "tracklist".
---
---@param tracklist table|nil Nueva tracklist normalizada.
function Player:update_tracklist(tracklist)
    if tracklist ~= nil and type(tracklist) ~= "table" then
        return
    end
    self.tracklist = tracklist
    self:_refresh("tracklist")
end

--- Actualiza la metadata y refresca únicamente las secciones afectadas:
---
---   - `provider` / `status`       -> "meta" + "controls"
---   - `title` / `artist` / `album` -> "meta"
---   - `position` / `duration`     -> "progress"
---
--- Esto es lo que hace que actualizar sólo el tiempo/progreso (el caso más
--- frecuente) no toque la portada ni la tracklist.
---
---@param metadata table|nil Nueva metadata.
function Player:update_music(metadata)
    if metadata ~= nil and type(metadata) ~= "table" then
        return
    end
    local old = self.music_metadata or {}
    local new = metadata or {}
    local dirty_sections = {}

    if old.provider ~= new.provider or old.status ~= new.status then
        dirty_sections[#dirty_sections + 1] = "meta"
        dirty_sections[#dirty_sections + 1] = "controls"
    end
    if old.title ~= new.title or old.artist ~= new.artist or old.album ~= new.album then
        dirty_sections[#dirty_sections + 1] = "meta"
    end
    if old.position ~= new.position or old.duration ~= new.duration then
        dirty_sections[#dirty_sections + 1] = "progress"
    end
    -- Primera metadata que se establece: aseguramos que todo lo relacionado
    -- se calcule (por si algún campo "coincide" por casualidad con el
    -- default, ej. status = "Stopped" ya presente en la sección vacía).
    if self.music_metadata == nil and metadata ~= nil then
        dirty_sections = { "meta", "controls", "progress" }
    end

    self.music_metadata = metadata
    self:_refresh(dirty_sections)
end

--- Elimina la metadata actual y muestra el estado vacío.
function Player:clear_music()
    self.music_metadata = nil
    self:_refresh({ "meta", "controls", "progress" })
end

--- Reemplaza directamente el contenido del buffer (API de bajo nivel; se
--- recomienda usar `update_music()` en lugar de esto). No participa del
--- sistema de diff/dirty-tracking.
---
---@param lines table Lista de líneas.
function Player:set_lines(lines)
    if not self:is_valid() then
        return
    end
    vim.api.nvim_set_option_value("modifiable", true, { buf = self.bufnr })
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines or {})
    vim.api.nvim_set_option_value("modifiable", false, { buf = self.bufnr })
end

-- ============================================================================
--                              FOCUS / LIFECYCLE
-- ============================================================================
--- Coloca el foco en la ventana del Music Manager.
function Player:focus()
    if not self:is_window_valid() then
        return
    end
    vim.api.nvim_set_current_win(self.winid)
end

--- Oculta la ventana sin eliminar el buffer.
---
---@return boolean `true` si se ocultó una ventana.
function Player:hide()
    if not self:is_window_valid() then
        return false
    end
    vim.api.nvim_win_hide(self.winid)
    return true
end

--- Cierra la ventana (si existe) y elimina el buffer.
function Player:close()
    if self.winid and vim.api.nvim_win_is_valid(self.winid) then
        pcall(vim.api.nvim_win_close, self.winid, true)
    end
    if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
        pcall(vim.api.nvim_buf_delete, self.bufnr, { force = true })
    end
    self.winid = nil
    self.bufnr = nil
    -- Al perder el buffer, el próximo render debe partir de cero.
    self._last_rendered_lines = nil
    self:mark_all_dirty()
end

-- ============================================================================
--                              MODULE
-- ============================================================================
return Player
