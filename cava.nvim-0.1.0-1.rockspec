package = "cava.nvim"
version = "0.1.0-1"

source = {
    url = "git+https://github.com/EddyBel/cava.nvim.git",
}

description = {
    summary = "CAVA visualizer and music player UI for Neovim",

    detailed = [[
        A music visualization and music player interface for Neovim.

        Requirements:
        - Neovim >= 0.12
        - Lua >= 5.1
        - playerctl (required, generic media player source)
        - chafa (required, image-to-ASCII converter)
        - CAVA (optional, can be disabled in the Neovim configuration)

        playerctl provides the generic media player backend, allowing
        cava.nvim to interact with players that expose an MPRIS interface.

        CAVA provides real-time audio visualization and can be disabled
        when visualization is not required.
    ]],

    homepage = "https://github.com/EddyBel/cava.nvim",
    license = "MIT",
}

dependencies = {
    "lua >= 5.1",
}
