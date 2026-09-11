"""
CAVA HTTP endpoints.

This module contains the HTTP endpoint handlers related to CAVA.
"""

import time

from libs.cava import Cava


def get_status(cava: Cava):
    """
    Return the current CAVA status.
    """

    return {
        "running": cava.is_running(),
    }


def get_frame(cava: Cava):
    """
    Return the current raw CAVA frame.
    """

    t0 = time.monotonic()

    result = {
        "frame": cava.get_frame(),
    }

    elapsed = (time.monotonic() - t0) * 1000

    if elapsed > 5:  # cualquier valor > 5ms ya es sospechoso para esto
        print(
            f"WARNING /cava/frame tardó "
            f"{elapsed:.1f}ms dentro del handler"
        )

    return result


def get_render_frame(
    cava: Cava,
    width: int,
    height: int,
    columns: int,
):
    """
    Return a render-ready CAVA frame.

    The Cava class handles:
        - Raw frame processing.
        - Column resizing.
        - Height scaling.
        - Render cache.
        - Changed column detection.

    Parameters
    ----------
    cava : Cava
        CAVA instance.

    width : int
        Neovim buffer width.

    height : int
        Neovim buffer height.

    columns : int
        Number of visualization columns.

    Returns
    -------
    dict

    Example
    -------
    {
        "frame": [2, 5, 8, 12],
        "change": [
            {"column": 2, "value": 8},
            {"column": 3, "value": 12}
        ]
    }
    """

    t0 = time.monotonic()

    result = cava.get_render_frame(
        width=width,
        height=height,
        columns=columns,
    )

    elapsed = (time.monotonic() - t0) * 1000

    if elapsed > 5:
        print(
            f"WARNING /cava/render tardó "
            f"{elapsed:.1f}ms dentro del handler"
        )

    return result


def get_info(cava: Cava):
    """
    Return CAVA state and current raw frame.
    """

    return {
        "running": cava.is_running(),
        "frame": cava.get_frame(),
    }
