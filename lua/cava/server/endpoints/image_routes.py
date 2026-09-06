"""
Image HTTP endpoints.

Combines Image inspection and Chafa rendering into a
single HTTP-facing image interface.
"""

from libs.image import Image


def get_info(path):
    image = Image(path)

    return {
        "image": image.get_info(),
    }


def get_size(
    path,
    size,
    font_ratio="1/2",
):
    image = Image(path)

    result = image.calculate_size(
        size,
        font_ratio=font_ratio,
    )

    return {
        "image": {
            "path": image.path,
            "width": image.width,
            "height": image.height,
            "aspect_ratio": image.get_aspect_ratio(),
        },
        "size": result,
    }


def render(
    path,
    size,
    chafa,
    font_ratio="1/2",
):
    image = Image(path)

    info = image.inspect()

    calculated_size = image.calculate_size(
        size,
        font_ratio=font_ratio,
    )

    result = chafa.render(
        image.path,
        calculated_size,
    )

    return {
        "image": info,
        "size": calculated_size,
        "render": result,
    }
