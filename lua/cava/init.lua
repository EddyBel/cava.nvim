local M = {}

----------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------

---@param opts table|nil
---@return nil
function M.setup(opts)
    opts = opts or {}

    opts.cava = opts.cava or {}

    if opts.cava.enabled == nil then
        opts.cava.enabled = false
    end

    local CORE =
        require("cava.core.init")

    CORE.setup(opts or {})

    ------------------------------------------------------------------
    -- UI commands
    ------------------------------------------------------------------

    vim.api.nvim_create_user_command(
        "CavaOpen",
        function()
            CORE.start()
        end,
        {
            desc = "Open MusicManager",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaClose",
        function()
            CORE.close()
        end,
        {
            desc = "Close MusicManager",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaToggle",
        function()
            CORE.toggle()
        end,
        {
            desc = "Toggle MusicManager",
        }
    )

    ------------------------------------------------------------------
    -- Server helpers
    ------------------------------------------------------------------

    local function player_command(
        endpoint,
        body
    )
        local SERVER =
            require("cava.core.server")

        SERVER.post(
            endpoint,
            body or {},
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
    -- Playback
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
        "CavaStop",
        function()
            player_command(
                "/player/stop"
            )
        end,
        {
            desc = "Stop playback",
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
    -- Seek
    ------------------------------------------------------------------

    vim.api.nvim_create_user_command(
        "CavaSeek",
        function(command)
            local seconds =
                tonumber(command.args)

            if not seconds then
                vim.notify(
                    "CavaSeek requires seconds",
                    vim.log.levels.ERROR
                )
                return
            end

            player_command(
                "/player/seek",
                {
                    seconds = seconds,
                }
            )
        end,
        {
            nargs = 1,
            desc = "Seek relative to current position",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaSeekForward",
        function(command)
            local seconds =
                tonumber(command.args)

            if not seconds then
                vim.notify(
                    "CavaSeekForward requires seconds",
                    vim.log.levels.ERROR
                )
                return
            end

            player_command(
                "/player/seek/forward",
                {
                    seconds = seconds,
                }
            )
        end,
        {
            nargs = 1,
            desc = "Seek forward",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaSeekBackward",
        function(command)
            local seconds =
                tonumber(command.args)

            if not seconds then
                vim.notify(
                    "CavaSeekBackward requires seconds",
                    vim.log.levels.ERROR
                )
                return
            end

            player_command(
                "/player/seek/backward",
                {
                    seconds = seconds,
                }
            )
        end,
        {
            nargs = 1,
            desc = "Seek backward",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaPosition",
        function(command)
            local seconds =
                tonumber(command.args)

            if not seconds then
                vim.notify(
                    "CavaPosition requires seconds",
                    vim.log.levels.ERROR
                )
                return
            end

            player_command(
                "/player/position",
                {
                    position = seconds,
                }
            )
        end,
        {
            nargs = 1,
            desc = "Set playback position",
        }
    )

    ------------------------------------------------------------------
    -- Volume
    ------------------------------------------------------------------

    vim.api.nvim_create_user_command(
        "CavaVolume",
        function(command)
            local volume =
                tonumber(command.args)

            if not volume then
                vim.notify(
                    "CavaVolume requires a value",
                    vim.log.levels.ERROR
                )
                return
            end

            player_command(
                "/player/volume",
                {
                    volume = volume,
                }
            )
        end,
        {
            nargs = 1,
            desc = "Set volume",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaVolumeUp",
        function(command)
            local amount =
                tonumber(command.args)

            player_command(
                "/player/volume/up",
                amount and {
                    amount = amount,
                } or {}
            )
        end,
        {
            nargs = "?",
            desc = "Increase volume",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaVolumeDown",
        function(command)
            local amount =
                tonumber(command.args)

            player_command(
                "/player/volume/down",
                amount and {
                    amount = amount,
                } or {}
            )
        end,
        {
            nargs = "?",
            desc = "Decrease volume",
        }
    )

    ------------------------------------------------------------------
    -- Shuffle
    ------------------------------------------------------------------

    vim.api.nvim_create_user_command(
        "CavaShuffle",
        function(command)
            local value =
                command.args

            if value == "on" then
                player_command(
                    "/player/shuffle",
                    {
                        shuffle = true,
                    }
                )
                return
            end

            if value == "off" then
                player_command(
                    "/player/shuffle",
                    {
                        shuffle = false,
                    }
                )
                return
            end

            vim.notify(
                "Usage: :CavaShuffle on|off",
                vim.log.levels.ERROR
            )
        end,
        {
            nargs = 1,
            complete = function()
                return {
                    "on",
                    "off",
                }
            end,
            desc = "Enable or disable shuffle",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaShuffleToggle",
        function()
            player_command(
                "/player/shuffle/toggle"
            )
        end,
        {
            desc = "Toggle shuffle",
        }
    )

    ------------------------------------------------------------------
    -- Loop
    ------------------------------------------------------------------

    vim.api.nvim_create_user_command(
        "CavaLoop",
        function(command)
            local value =
                command.args

            if value == "" then
                vim.notify(
                    "Usage: :CavaLoop off|track|playlist",
                    vim.log.levels.ERROR
                )
                return
            end

            player_command(
                "/player/loop",
                {
                    loop = value,
                }
            )
        end,
        {
            nargs = 1,
            complete = function()
                return {
                    "off",
                    "track",
                    "playlist",
                }
            end,
            desc = "Set loop mode",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaLoopToggle",
        function()
            player_command(
                "/player/loop/toggle"
            )
        end,
        {
            desc = "Toggle loop mode",
        }
    )

    ------------------------------------------------------------------
    -- Provider
    ------------------------------------------------------------------

    vim.api.nvim_create_user_command(
        "CavaProvider",
        function(command)
            local provider =
                command.args

            if provider == "" then
                vim.notify(
                    "Usage: :CavaProvider <provider>",
                    vim.log.levels.ERROR
                )
                return
            end

            player_command(
                "/player/provider",
                {
                    provider = provider,
                }
            )
        end,
        {
            nargs = 1,
            desc = "Set music provider",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaProviderAuto",
        function()
            player_command(
                "/player/provider/auto"
            )
        end,
        {
            desc = "Automatically select music provider",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaProviderNext",
        function()
            player_command(
                "/player/provider/next"
            )
        end,
        {
            desc = "Select next provider",
        }
    )

    vim.api.nvim_create_user_command(
        "CavaProviderPrevious",
        function()
            player_command(
                "/player/provider/previous"
            )
        end,
        {
            desc = "Select previous provider",
        }
    )
end

return M
