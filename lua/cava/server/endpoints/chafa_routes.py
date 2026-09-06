"""
Chafa HTTP endpoints.
"""


def get_status(chafa):
    """
    Return Chafa status.
    """
    return {
        "running": chafa.is_running(),
        "installed": chafa.is_installed(),
    }


def get_info(chafa):
    """
    Return complete Chafa information.
    """
    return {
        "running": chafa.is_running(),
        "installed": chafa.is_installed(),
        "config": chafa.get_config(),
    }


def get_output(chafa):
    """
    Return the latest raw Chafa output.
    """
    return {
        "output": chafa.get_output(),
    }
