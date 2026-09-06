local M = {}

----------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------

---@param opts table|nil
---@return nil
function M.setup(opts)
    opts = opts or {}

    ------------------------------------------------------------------
    -- Dependencies.
    ------------------------------------------------------------------

    local SERVER =
        require("cava.core.server")

    local CAVA_API =
        require("cava.core.init")

    ------------------------------------------------------------------
    -- Pass configuration to each subsystem.
    --
    -- Each subsystem owns its defaults and is responsible for
    -- validating and merging its own options.
    ------------------------------------------------------------------

    SERVER.setup(
        opts.server
    )

    CAVA_API.setup(
        opts
    )

    ------------------------------------------------------------------
    -- Commands
    ------------------------------------------------------------------

    vim.api.nvim_create_user_command(
        "CavaOpen",
        function()
            CAVA_API.start()
        end,
        {
            desc = "Open MusicManager",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaClose",
        function()
            CAVA_API.close()
        end,
        {
            desc = "Close MusicManager",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaToggle",
        function()
            CAVA_API.toggle()
        end,
        {
            desc = "Toggle MusicManager",
        }
    )

    ------------------------------------------------------------------
    -- Playback helper
    ------------------------------------------------------------------

    local function player_command(endpoint)
        SERVER.post(
            endpoint,
            {},
            function(ok, data)
                if not ok then
                    vim.notify(
                        "MusicManager: "
                        .. tostring(data),
                        vim.log.levels.ERROR
                    )
                end
            end
        )
    end

    ------------------------------------------------------------------
    -- Playback commands
    ------------------------------------------------------------------

    vim.api.nvim_create_user_command(
        "CavaPlay",
        function()
            player_command(
                "/player/play"
            )
        end,
        {
            desc = "Play music",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaPause",
        function()
            player_command(
                "/player/pause"
            )
        end,
        {
            desc = "Pause music",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaPlayPause",
        function()
            player_command(
                "/player/play-pause"
            )
        end,
        {
            desc = "Toggle playback",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaNext",
        function()
            player_command(
                "/player/next"
            )
        end,
        {
            desc = "Play next track",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaPrevious",
        function()
            player_command(
                "/player/previous"
            )
        end,
        {
            desc = "Play previous track",
        }
    )


    ------------------------------------------------------------------
    -- Start server
    ------------------------------------------------------------------

    SERVER.ensure(
        function(ok, data)
            if not ok then
                vim.notify(
                    "No se pudo iniciar MusicManager:\n\n"
                    .. tostring(data),
                    vim.log.levels.ERROR
                )

                return
            end

            vim.notify(
                "MusicManager conectado",
                vim.log.levels.INFO
            )
        end
    )
end

return M
