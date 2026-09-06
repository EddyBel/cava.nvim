"""
Playerctl HTTP endpoints.
"""


def get_status(playerctl):
    """
    Return playerctl status.
    """

    return {
        "running": playerctl.is_running(),
        "available": playerctl.is_available(),
        "provider": playerctl.provider,
    }


def get_metadata(playerctl):
    """
    Return current player metadata.
    """

    return {
        "metadata": playerctl.get_current(),
    }


def get_artwork(playerctl):
    """
    Return current artwork information.
    """

    return {
        "artwork": playerctl.get_artwork_info(),
    }


def get_info(playerctl):
    """
    Return complete player information.
    """

    return {
        "running": playerctl.is_running(),
        "available": playerctl.is_available(),
        "provider": playerctl.provider,
        "metadata": playerctl.get_current(),
        "artwork": playerctl.get_artwork_info(),
    }


def play(playerctl):
    """
    Start playback.
    """

    return {
        "success": playerctl.play(),
    }


def pause(playerctl):
    """
    Pause playback.
    """

    return {
        "success": playerctl.pause(),
    }


def play_pause(playerctl):
    """
    Toggle playback.
    """

    return {
        "success": playerctl.play_pause(),
    }


def next_track(playerctl):
    """
    Skip to the next track.
    """

    return {
        "success": playerctl.next(),
    }


def previous_track(playerctl):
    """
    Go to the previous track.
    """

    return {
        "success": playerctl.previous(),
    }

