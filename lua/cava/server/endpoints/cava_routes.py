"""
CAVA HTTP endpoints.

This module contains the HTTP endpoint handlers related to CAVA.
"""

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
    Return the latest CAVA frame.
    """

    return {
        "frame": cava.get_frame(),
    }


def get_info(cava: Cava):
    """
    Return CAVA state and current frame.
    """

    return {
        "running": cava.is_running(),
        "frame": cava.get_frame(),
    }
