"""
Music Orchestrator HTTP endpoints.
"""


# ============================================================================
# PLAYER INFORMATION
# ============================================================================

def get_status(orchestrator):
    """
    Return orchestrator status.
    """

    return {
        "running": orchestrator.is_running(),
        "available": orchestrator.is_available(),
        "provider": orchestrator.get_active_backend_name(),
    }


def get_metadata(orchestrator):
    """
    Return current orchestrator metadata.
    """

    return {
        "metadata": orchestrator.metadata(),
    }


def get_artwork(orchestrator):
    """
    Return combined artwork information.

    Includes the remote artwork URL and, when available, the local
    cached artwork path.
    """

    metadata = orchestrator.metadata() or {}

    artwork_url = (
        metadata.get("art_url")
        or metadata.get("artwork")
    )

    local_path = orchestrator.get_local_artwork()

    return {
        "artwork": artwork_url,
        "path": local_path,
    }


def get_info(orchestrator):
    """
    Return complete orchestrator information.
    """

    return {
        "running": orchestrator.is_running(),
        "available": orchestrator.is_available(),
        "provider": orchestrator.get_active_backend_name(),
        "metadata": orchestrator.metadata(),
        "artwork": get_artwork(orchestrator)["artwork"],
    }


# ============================================================================
# PROVIDERS
# ============================================================================

def get_providers(orchestrator):
    """
    Return all available providers from the orchestrator.
    """

    providers = []

    if hasattr(orchestrator, "get_providers"):
        try:
            providers = orchestrator.get_providers()
        except Exception:
            pass

    return {
        "providers": providers,
        "provider": orchestrator.get_active_backend_name(),
    }


def set_provider(orchestrator, provider):
    """
    Set the current active provider using the orchestrator method.
    """

    success = False

    if hasattr(orchestrator, "set_provider"):
        try:
            success = orchestrator.set_provider(provider)
        except Exception:
            success = False

    return {
        "success": success,
        "provider": orchestrator.get_active_backend_name(),
    }


def auto_provider(orchestrator):
    """
    Automatically select an available provider.
    """

    provider = None

    if hasattr(orchestrator, "auto_provider"):
        try:
            provider = orchestrator.auto_provider()
        except Exception:
            pass

    return {
        "success": provider is not None,
        "provider": orchestrator.get_active_backend_name(),
    }


def next_provider(orchestrator):
    """
    Select the next available provider.
    """

    provider = None

    if hasattr(orchestrator, "next_provider"):
        try:
            provider = orchestrator.next_provider()
        except Exception:
            pass

    return {
        "success": provider is not None,
        "provider": orchestrator.get_active_backend_name(),
    }


def previous_provider(orchestrator):
    """
    Select the previous available provider.
    """

    provider = None

    if hasattr(orchestrator, "previous_provider"):
        try:
            provider = orchestrator.previous_provider()
        except Exception:
            pass

    return {
        "success": provider is not None,
        "provider": orchestrator.get_active_backend_name(),
    }


# ============================================================================
# TRACKLIST
# ============================================================================

def get_tracklist(orchestrator):
    """
    Return the current tracklist.

    Artwork resolution and association are handled by the
    active provider.
    """

    tracklist = orchestrator.tracklist()

    return {
        "tracklist": tracklist or [],
    }


# ============================================================================
# PLAYBACK
# ============================================================================

def play(orchestrator):
    """
    Start or resume playback.
    """

    return {
        "success": bool(
            orchestrator.play()
        ),
    }


def pause(orchestrator):
    """
    Pause playback.
    """

    return {
        "success": bool(
            orchestrator.pause()
        ),
    }


def play_pause(orchestrator):
    """
    Toggle playback.
    """

    return {
        "success": bool(
            orchestrator.play_pause()
        ),
    }


def stop_playback(orchestrator):
    """
    Stop playback.

    This is different from orchestrator.stop(), which stops
    the MusicManager background monitor.
    """

    return {
        "success": bool(
            orchestrator.stop_playback()
        ),
    }


def next_track(orchestrator):
    """
    Skip to the next track.
    """

    return {
        "success": bool(
            orchestrator.next()
        ),
    }


def previous_track(orchestrator):
    """
    Go to the previous track.
    """

    return {
        "success": bool(
            orchestrator.previous()
        ),
    }


# ============================================================================
# SEEK
# ============================================================================

def seek(orchestrator, seconds):
    """
    Seek relative to the current playback position.

    Positive values move forward.
    Negative values move backward.
    """

    return {
        "success": bool(
            orchestrator.seek(
                seconds
            )
        ),
    }


def seek_forward(orchestrator, seconds=10):
    """
    Seek forward.
    """

    return {
        "success": bool(
            orchestrator.seek_forward(
                seconds
            )
        ),
    }


def seek_backward(orchestrator, seconds=10):
    """
    Seek backward.
    """

    return {
        "success": bool(
            orchestrator.seek_backward(
                seconds
            )
        ),
    }


def get_position(orchestrator):
    """
    Return the current playback position.
    """

    return {
        "position": orchestrator.get_position(),
    }


def set_position(orchestrator, seconds):
    """
    Set the absolute playback position.
    """

    return {
        "success": bool(
            orchestrator.set_position(
                seconds
            )
        ),
        "position": orchestrator.get_position(),
    }


# ============================================================================
# VOLUME
# ============================================================================

def get_volume(orchestrator):
    """
    Return current volume.

    The normalized value is expected to be between 0.0 and 1.0.
    """

    return {
        "volume": orchestrator.get_volume(),
    }


def set_volume(orchestrator, volume):
    """
    Set volume.

    Parameters
    ----------
    volume : float
        Normalized value between 0.0 and 1.0.
    """

    success = orchestrator.set_volume(
        volume
    )

    return {
        "success": bool(success),
        "volume": orchestrator.get_volume(),
    }


def volume_up(orchestrator, step=0.05):
    """
    Increase volume.
    """

    success = orchestrator.volume_up(
        step
    )

    return {
        "success": bool(success),
        "volume": orchestrator.get_volume(),
    }


def volume_down(orchestrator, step=0.05):
    """
    Decrease volume.
    """

    success = orchestrator.volume_down(
        step
    )

    return {
        "success": bool(success),
        "volume": orchestrator.get_volume(),
    }


# ============================================================================
# SHUFFLE
# ============================================================================

def get_shuffle(orchestrator):
    """
    Return current shuffle state.
    """

    return {
        "shuffle": orchestrator.get_shuffle(),
    }


def set_shuffle(orchestrator, enabled):
    """
    Enable or disable shuffle.
    """

    success = orchestrator.set_shuffle(
        enabled
    )

    return {
        "success": bool(success),
        "shuffle": orchestrator.get_shuffle(),
    }


def toggle_shuffle(orchestrator):
    """
    Toggle shuffle.
    """

    success = orchestrator.toggle_shuffle()

    return {
        "success": bool(success),
        "shuffle": orchestrator.get_shuffle(),
    }


# ============================================================================
# LOOP
# ============================================================================

def get_loop_status(orchestrator):
    """
    Return current loop mode.

    Possible values:

        None
        Track
        Playlist
    """

    return {
        "loop": orchestrator.get_loop_status(),
    }


def set_loop_status(orchestrator, status):
    """
    Set loop mode.

    Supported values:

        None
        Track
        Playlist
    """

    success = orchestrator.set_loop_status(
        status
    )

    return {
        "success": bool(success),
        "loop": orchestrator.get_loop_status(),
    }


def toggle_loop(orchestrator):
    """
    Cycle loop mode.

    None -> Track -> Playlist -> None
    """

    success = orchestrator.toggle_loop()

    return {
        "success": bool(success),
        "loop": orchestrator.get_loop_status(),
    }
