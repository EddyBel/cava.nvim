-- ============================================================================
-- INIT
-- ============================================================================
--
-- Punto de entrada / coordinador del plugin.
--
-- Su responsabilidad es:
--
--     setup()  → guarda la configuración global y configura SERVER.
--     start()  → distribuye la configuración a Menu y Poller.
--     close()  → detiene Poller y destruye Menu.
--     hide()   → detiene Poller y oculta Menu.
--     toggle() → alterna entre start() y close().
--
-- Este módulo NO implementa lógica de UI, polling ni requests HTTP.
-- Únicamente conecta los subsistemas.
--
-- Configuración global esperada:
--
--     opts = {
--         server = {},
--         menu = {},
--         player = {},
--         cava = {},
--         poller = {},
--         artwork = {},
--         tracklist_artwork = {},
--     }
--
-- Cada subsistema es responsable de sus propios valores por defecto.
-- ============================================================================

local M = {}

----------------------------------------------------------------------
-- User options
--
-- Este módulo no define defaults.
--
-- La configuración global se conserva intacta y se distribuye a los
-- subsistemas correspondientes.
----------------------------------------------------------------------
M.opts = {}

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

M.state = {
    menu = nil,
    poller = nil,
}

----------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------

--- Configure Music Manager.
---
--- Guarda las opciones globales y configura SERVER.
---
---@param opts table|nil User configuration.
---@return nil
function M.setup(opts)
    M.opts = opts or {}

    local SERVER =
        require("cava.core.server")

    SERVER.setup(
        M.opts.server,
        M.opts.cava
    )
end

----------------------------------------------------------------------
-- Controller
----------------------------------------------------------------------

--- Return the public lifecycle controller.
---
---@return table
local function controller()
    return {
        stop = M.close,
        close = M.close,
        hide = M.hide,
        toggle = M.toggle,
    }
end

----------------------------------------------------------------------
-- Close
----------------------------------------------------------------------

--- Close and destroy the Music Manager interface.
---
---@return boolean
function M.close()
    if M.state.poller then
        M.state.poller:stop()
        M.state.poller = nil
    end

    local menu = M.state.menu
    M.state.menu = nil

    if not menu then
        return false
    end

    menu:close()

    return true
end

----------------------------------------------------------------------
-- Hide
----------------------------------------------------------------------

--- Hide the Music Manager without destroying its buffers.
---
--- El polling se detiene mientras el menú está oculto; se reanuda al
--- volver a llamar `start()`.
---
---@return boolean
function M.hide()
    if M.state.poller then
        M.state.poller:stop()
    end

    if not M.state.menu then
        return false
    end

    return M.state.menu:hide()
end

----------------------------------------------------------------------
-- Toggle
----------------------------------------------------------------------

--- Toggle the Music Manager interface.
---
---@return boolean|table|nil
function M.toggle()
    if M.state.menu and M.state.menu:is_open() then
        return M.close()
    end

    return M.start()
end

----------------------------------------------------------------------
-- Start
----------------------------------------------------------------------

--- Start the Music Manager.
---
--- Init distribuye la configuración global, pero no modifica ni
--- interpreta las opciones pertenecientes a cada subsistema.
---
---@return table|nil Controller object.
function M.start()
    ------------------------------------------------------------------
    -- Prevent duplicate instances.
    ------------------------------------------------------------------

    if M.state.menu
        and M.state.poller
        and M.state.poller:is_running()
    then
        return controller()
    end

    ------------------------------------------------------------------
    -- Dependencies.
    ------------------------------------------------------------------

    local SERVER = require("cava.core.server")
    local DRAW = require("cava.core.draw")
    local Menu = require("cava.core.menu.menu")
    local Poller = require("cava.core.poller")

    local opts = M.opts or {}

    ------------------------------------------------------------------
    -- Create UI.
    --
    -- Menu recibe la configuración global necesaria para construir
    -- Player y Cava.
    --
    -- Menu:
    --     opts.menu   → configuración de Menu
    --     opts.player → configuración de Player
    --     opts.cava   → configuración de Cava
    ------------------------------------------------------------------

    local menu = Menu.new({
        menu = opts.menu,
        player = opts.player,
        cava = opts.cava,
    })

    if not menu:create() then
        return nil
    end

    M.state.menu = menu

    ------------------------------------------------------------------
    -- Create data synchronizer.
    --
    -- Poller recibe:
    --     menu   → destino de los datos
    --     server → fuente HTTP
    --     draw   → renderizado de frames
    --     config → configuración global
    --
    -- Poller es responsable de consumir:
    --
    --     config.poller
    --     config.cava
    --     config.artwork
    --     config.tracklist_artwork
    --
    -- No se reconstruye ni se duplica la configuración aquí.
    ------------------------------------------------------------------

    local poller = Poller.new({
        menu = menu,
        server = SERVER,
        draw = DRAW,
        config = opts,
    })

    M.state.poller = poller

    ------------------------------------------------------------------
    -- Start backend.
    --
    -- SERVER ya recibió su configuración durante setup().
    ------------------------------------------------------------------

    SERVER.ensure(function(ok, data)
        ----------------------------------------------------------------
        -- Ignore callbacks belonging to an old/replaced instance.
        ----------------------------------------------------------------

        if M.state.menu ~= menu then
            return
        end

        ----------------------------------------------------------------
        -- Backend unavailable.
        ----------------------------------------------------------------

        if not ok then
            vim.notify(
                "MusicManager: " .. tostring(data),
                vim.log.levels.ERROR
            )

            poller:stop()
            return
        end

        ----------------------------------------------------------------
        -- Menu was closed while SERVER was starting.
        ----------------------------------------------------------------

        if not menu:is_open() then
            poller:stop()
            return
        end

        ----------------------------------------------------------------
        -- Everything is ready.
        ----------------------------------------------------------------

        poller:start()
    end)

    return controller()
end

return M
