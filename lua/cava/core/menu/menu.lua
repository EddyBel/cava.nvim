-- ============================================================================
-- MENU
-- ============================================================================
--
-- Este módulo es el orquestador de la interfaz completa. NO dibuja contenido
-- por sí mismo: delega en `Player` (buffer superior, info de la canción) y
-- `Cava` (buffer inferior, espectro de audio).
--
-- Responsabilidades de Menu:
--
--   - Crear Player siempre.
--   - Crear Cava únicamente cuando `cava.enabled ~= false`.
--   - Crear las ventanas en el ORDEN correcto:
--
--         ┌──────────────────────────────┐
--         │        Music Manager         │   <- Player
--         │                              │
--         ├──────────────────────────────┤
--         │            CAVA              │   <- Cava (opcional)
--         └──────────────────────────────┘
--
--   - Calcular y aplicar el ancho horizontal máximo del panel completo.
--   - Repartir la altura disponible cuando Cava está habilitado.
--   - Mostrar (`show`/`create`) y ocultar (`hide`) el menú completo.
--   - Cerrar (`close`) y liberar todos los recursos.
--   - Reaccionar a resize del editor / ventanas y a cierres externos.
--
-- Menu NO sabe cómo se construye el layout de la canción ni cómo se dibuja
-- un frame de CAVA; eso es responsabilidad exclusiva de cada submódulo.
--
-- La configuración es GLOBAL:
--
--     config.menu
--     config.player
--     config.cava
--
-- Menu solamente consume la sección correspondiente.
-- ============================================================================

local Player = require("cava.core.menu.player")
local Cava = require("cava.core.menu.cava")

local Menu = {}
Menu.__index = Menu

-- ============================================================================
--                              CONFIGURATION
-- ============================================================================

---@type table
Menu.config = {
    --- Ancho máximo permitido para el panel completo.
    max_width = 40,

    --- Ancho mínimo permitido para el panel completo.
    min_width = 20,

    --- Porcentaje del ancho total del editor que se intenta utilizar.
    width = 30,

    --- Recalcular dimensiones cuando cambia el tamaño del editor.
    resize = true,

    --- Indica si el menú debe mantenerse visible al cambiar de buffer.
    persistent = true,
}

-- ============================================================================
--                              CONSTRUCTOR
-- ============================================================================

--- Crea una nueva instancia de Menu.
---
--- Ejemplo:
---
---     local menu = Menu.new({
---         menu = {
---             max_width = 50,
---         },
---
---         player = {
---             music = {
---                 spacing = 2,
---             },
---         },
---
---         cava = {
---             enabled = false,
---             max_height = 12,
---         },
---     })
---
---@param opts table|nil
---@return table self
function Menu.new(opts)
    opts = opts or {}

    local self =
        setmetatable({}, Menu)

    --------------------------------------------------------------------------
    -- Menu configuration
    --------------------------------------------------------------------------
    --
    -- Esta es exclusivamente la configuración de Menu.
    --
    -- CAVA no pertenece a esta tabla.
    --------------------------------------------------------------------------

    self.config =
        vim.tbl_deep_extend(
            "force",
            Menu.config,
            opts.menu or {}
        )

    --------------------------------------------------------------------------
    -- Cava configuration
    --------------------------------------------------------------------------
    --
    -- `opts.cava` es la sección GLOBAL de Cava.
    --
    -- Menu solamente la consume para decidir si debe existir el componente.
    --
    -- Por defecto Cava está habilitado.
    --
    -- Por eso:
    --
    --     opts.cava == nil
    --         -> enabled
    --
    --     opts.cava.enabled == nil
    --         -> enabled
    --
    --     opts.cava.enabled == true
    --         -> enabled
    --
    --     opts.cava.enabled == false
    --         -> disabled
    --------------------------------------------------------------------------

    self.cava_config =
        opts.cava or {}

    self.cava_enabled =
        self.cava_config.enabled ~= false

    --------------------------------------------------------------------------
    -- Modules
    --------------------------------------------------------------------------

    -- Player siempre existe.
    self.player =
        Player.new(opts.player)

    -- Cava solamente existe cuando está habilitado.
    self.cava = nil

    if self.cava_enabled then
        self.cava =
            Cava.new(self.cava_config)
    end

    --------------------------------------------------------------------------
    -- State
    --------------------------------------------------------------------------

    self.initialized = false

    -- Se utiliza durante close() para evitar que los autocmds respondan
    -- mientras el módulo está destruyendo sus recursos.
    self.closing = false

    self.autocmd_group = nil

    --- Callback ejecutado tras un resize.
    ---
    --- Cuando Cava está habilitado:
    ---     callback(cava_width, cava_height)
    ---
    --- Cuando Cava está deshabilitado:
    ---     callback(nil, nil)
    self.on_resize_callback = nil

    return self
end

-- ============================================================================
--                              STATE
-- ============================================================================

--- Indica si CAVA está habilitado.
---
--- El valor pertenece a la configuración GLOBAL:
---
---     config.cava.enabled
---
--- Si no se especifica, Cava está habilitado.
---
---@return boolean
function Menu:is_cava_enabled()
    return self.cava_enabled == true
end

--- El menú se considera abierto cuando Player existe y su ventana es válida.
---
--- Si CAVA está habilitado, su ventana también debe ser válida.
---
---@return boolean
function Menu:is_open()
    if not self.player:is_window_valid() then
        return false
    end

    if self:is_cava_enabled() then
        return self.cava ~= nil
            and self.cava:is_window_valid()
    end

    return true
end

--- Limpia referencias a buffers/ventanas que ya no existen.
function Menu:cleanup_invalid_state()
    self.player:cleanup_invalid_state()

    if self.cava then
        self.cava:cleanup_invalid_state()
    end
end

-- ============================================================================
--                              WIDTH
-- ============================================================================

--- Calcula el ancho deseado del panel completo.
---
--- ancho = clamp(columnas_del_editor * porcentaje / 100, min_width, max_width)
---
---@return number width
function Menu:calculate_width()
    local editor_width =
        vim.o.columns

    local percentage =
        math.floor(
            editor_width
            * (self.config.width / 100)
        )

    return math.max(
        self.config.min_width,
        math.min(
            percentage,
            self.config.max_width
        )
    )
end

--- Aplica el ancho calculado a Player.
---
--- Cava comparte la misma columna, por lo que no necesita recibir el ancho
--- directamente desde Menu.
function Menu:apply_width()
    self.player:apply_width(
        self:calculate_width()
    )
end

-- ============================================================================
--                              CREATION
-- ============================================================================

--- Crea toda la interfaz del menú.
---
--- Player siempre se crea.
---
--- Cava solamente se crea cuando:
---
---     config.cava.enabled ~= false
---
---@return boolean
function Menu:create()
    if self.closing then
        return false
    end

    if self:is_open() then
        self:focus()
        return true
    end

    self:cleanup_invalid_state()

    local original_win =
        vim.api.nvim_get_current_win()

    if not vim.api.nvim_win_is_valid(original_win) then
        return false
    end

    --------------------------------------------------------------------------
    -- 1. Player
    --------------------------------------------------------------------------

    if not self.player:create_buffer() then
        return false
    end

    vim.cmd("botright vsplit")

    self.player:attach_window(
        vim.api.nvim_get_current_win()
    )

    self:apply_width()

    --------------------------------------------------------------------------
    -- 2. Cava
    --------------------------------------------------------------------------

    if self:is_cava_enabled() then
        if not self.cava then
            self.cava =
                Cava.new(self.cava_config)
        end

        if not self.cava:create_buffer() then
            self:close()
            return false
        end

        vim.cmd("split")

        self.cava:attach_window(
            vim.api.nvim_get_current_win()
        )
    end

    --------------------------------------------------------------------------
    -- Restore original focus
    --------------------------------------------------------------------------

    if vim.api.nvim_win_is_valid(original_win) then
        vim.api.nvim_set_current_win(
            original_win
        )
    end

    --------------------------------------------------------------------------
    -- Dimensions
    --------------------------------------------------------------------------

    self:resize()

    self.initialized = true

    self:setup_autocmds()

    return true
end

--- Alias semántico de `create()`.
function Menu:show()
    return self:create()
end

-- ============================================================================
--                              RESIZE
-- ============================================================================

--- Recalcula las dimensiones del menú.
---
--- Cuando Cava está habilitado:
---
---     Player
---       ↓
---     Cava
---
--- Cuando está deshabilitado:
---
---     Player
---
function Menu:resize()
    if self.closing then
        return
    end

    if not self:is_open() then
        return
    end

    --------------------------------------------------------------------------
    -- Player
    --------------------------------------------------------------------------

    self:apply_width()

    --------------------------------------------------------------------------
    -- Cava
    --------------------------------------------------------------------------

    if self:is_cava_enabled()
        and self.cava
    then
        self.cava:apply_height(
            self.player:get_height()
        )
    end

    --------------------------------------------------------------------------
    -- Player layout
    --------------------------------------------------------------------------

    self.player:render()

    --------------------------------------------------------------------------
    -- Resize callback
    --------------------------------------------------------------------------

    if self.on_resize_callback then
        if self:is_cava_enabled()
            and self.cava
        then
            self.on_resize_callback(
                self.cava:get_dimensions()
            )
        else
            self.on_resize_callback(
                nil,
                nil
            )
        end
    end
end

--- Registra el callback ejecutado después de un resize.
---
---@param callback function|nil
function Menu:on_resize_callback_set(callback)
    self.on_resize_callback = callback
end

-- ============================================================================
--                              AUTOCMDS
-- ============================================================================

--- Registra los autocmds necesarios para mantener el estado sincronizado.
function Menu:setup_autocmds()
    if self.autocmd_group then
        return
    end
    self.autocmd_group = vim.api.nvim_create_augroup("CavaMusicManager", { clear = true })
    --------------------------------------------------------------------------
    -- Editor resize
    --------------------------------------------------------------------------
    if self.config.resize then
        vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
            group = self.autocmd_group,
            callback = function()
                if self.closing then
                    return
                end
                vim.schedule(function()
                    if not self.closing then
                        self:resize()
                    end
                end)
            end,
        })
    end
    --------------------------------------------------------------------------
    -- Colorscheme change: recalcular el fondo oscurecido de ambas
    -- ventanas a partir del nuevo "Normal".
    --------------------------------------------------------------------------
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = self.autocmd_group,
        callback = function()
            if self.closing then
                return
            end
            vim.schedule(function()
                if self.closing then
                    return
                end
                self.player:apply_background()
                if self.cava then
                    self.cava:apply_background()
                end
            end)
        end,
    })
    --------------------------------------------------------------------------
    -- Window closed
    --------------------------------------------------------------------------

    vim.api.nvim_create_autocmd(
        "WinClosed",
        {
            group = self.autocmd_group,

            callback = function(args)
                if self.closing then
                    return
                end

                local closed =
                    tonumber(args.match)

                local player_closed =
                    closed == self.player.winid

                local cava_closed =
                    self.cava
                    and closed == self.cava.winid

                if player_closed
                    or cava_closed
                then
                    vim.schedule(function()
                        if not self.closing then
                            self:validate_windows()
                        end
                    end)
                end
            end,
        }
    )

    --------------------------------------------------------------------------
    -- Player buffer wiped
    --------------------------------------------------------------------------

    if self.player.bufnr then
        vim.api.nvim_create_autocmd(
            "BufWipeout",
            {
                group = self.autocmd_group,
                buffer = self.player.bufnr,

                callback = function()
                    if self.closing then
                        return
                    end

                    self.player.bufnr = nil
                    self.player.winid = nil
                end,
            }
        )
    end

    --------------------------------------------------------------------------
    -- Cava buffer wiped
    --------------------------------------------------------------------------

    if self.cava
        and self.cava.bufnr
    then
        vim.api.nvim_create_autocmd(
            "BufWipeout",
            {
                group = self.autocmd_group,
                buffer = self.cava.bufnr,

                callback = function()
                    if self.closing then
                        return
                    end

                    self.cava.bufnr = nil
                    self.cava.winid = nil
                end,
            }
        )
    end
end

-- ============================================================================
--                              WINDOW VALIDATION
-- ============================================================================

--- Comprueba que las ventanas necesarias continúen existiendo.
---
--- Player siempre es obligatorio.
---
--- Cava solamente es obligatorio cuando está habilitado.
function Menu:validate_windows()
    if self.closing then
        return
    end

    if not self.player:is_window_valid() then
        self:close()
        return
    end

    if self:is_cava_enabled() then
        if not self.cava
            or not self.cava:is_window_valid()
        then
            self:close()
            return
        end
    end
end

--- Elimina todos los autocmds creados por la instancia.
function Menu:cleanup_autocmds()
    if not self.autocmd_group then
        return
    end

    pcall(
        vim.api.nvim_del_augroup_by_id,
        self.autocmd_group
    )

    self.autocmd_group = nil
end

-- ============================================================================
--                              FOCUS
-- ============================================================================

--- Coloca el foco en Player.
function Menu:focus()
    self.player:focus()
end

-- ============================================================================
--                              HIDE
-- ============================================================================

--- Oculta el menú completo.
---
---@return boolean
function Menu:hide()
    local hidden_player =
        self.player:hide()

    local hidden_cava = false

    if self.cava then
        hidden_cava =
            self.cava:hide()
    end

    return hidden_player
        or hidden_cava
end

-- ============================================================================
--                              CLOSE
-- ============================================================================

--- Cierra completamente el menú.
---
--- Orden inverso al de creación:
---
---     Cava
---       ↓
---     Player
---
--- Cuando Cava está deshabilitado, simplemente se cierra Player.
function Menu:close()
    if self.closing then
        return
    end

    self.closing = true

    self:cleanup_autocmds()

    self.initialized = false

    --------------------------------------------------------------------------
    -- Cava
    --------------------------------------------------------------------------

    if self.cava then
        self.cava:close()
    end

    --------------------------------------------------------------------------
    -- Player
    --------------------------------------------------------------------------

    self.player:close()

    self.closing = false
end

-- ============================================================================
--                              MODULE
-- ============================================================================

return Menu
