"""
MusicManager server endpoints.
"""

from endpoints.cava_routes import get_frame
from endpoints.cava_routes import get_info
from endpoints.cava_routes import get_status


__all__ = [
    "get_frame",
    "get_info",
    "get_status",
]
