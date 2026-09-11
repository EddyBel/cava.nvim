"""
Image HTTP endpoints.

Combines Image inspection and Chafa rendering into a
single HTTP-facing image interface.
"""
import os
import shutil
import subprocess
import tempfile
from libs.image import Image
# ==============================================================================
#                              SQUARE CROP
# ==============================================================================
# Neither `Image` nor `Chafa` decode/manipulate pixels (by design — see
# libs/image.py). Cropping to a square is therefore done here, at the HTTP
# layer, by delegating the actual pixel work to an external command-line
# tool (ImageMagick's `convert`, falling back to `ffmpeg`), never a Python
# imaging library.
# ==============================================================================
def _find_crop_tool():
    """
    Return the name of the first available cropping tool
    ("convert" or "ffmpeg"), or `None` if neither is installed.
    """
    if shutil.which("convert"):
        return "convert"
    if shutil.which("ffmpeg"):
        return "ffmpeg"
    return None
def _crop_to_square_file(source_path, crop):
    """
    Produce a temporary file containing the centered square
    crop described by `crop` (as returned by
    `Image.calculate_square_crop()`).

    Parameters
    ----------
    source_path : str
        Path to the original image.
    crop : dict
        {"x": int, "y": int, "width": int, "height": int}

    Returns
    -------
    str
        Path to the cropped temporary file. The caller is
        responsible for deleting it once it's no longer needed.

    Raises
    ------
    RuntimeError
        If no supported cropping tool is installed, or the
        cropping command fails.
    """
    tool = _find_crop_tool()
    if tool is None:
        raise RuntimeError(
            "Square cropping requires 'convert' (ImageMagick) "
            "or 'ffmpeg' to be installed and available on PATH"
        )
    suffix = os.path.splitext(source_path)[1] or ".png"
    descriptor, destination_path = tempfile.mkstemp(
        prefix="cava_crop_",
        suffix=suffix,
    )
    os.close(descriptor)
    width = crop["width"]
    height = crop["height"]
    x = crop["x"]
    y = crop["y"]
    if tool == "convert":
        command = [
            "convert",
            source_path,
            "-crop",
            f"{width}x{height}+{x}+{y}",
            # Reset the canvas offset left behind by -crop, so the
            # resulting file is a plain WxH image with no virtual
            # canvas metadata for downstream readers to misinterpret.
            "+repage",
            destination_path,
        ]
    else:
        command = [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-i",
            source_path,
            "-vf",
            f"crop={width}:{height}:{x}:{y}",
            destination_path,
        ]
    try:
        subprocess.run(
            command,
            check=True,
            capture_output=True,
        )
    except (subprocess.CalledProcessError, OSError) as error:
        _safe_remove(destination_path)
        raise RuntimeError(
            f"Failed to crop image with '{tool}': {error}"
        ) from error
    return destination_path
def _safe_remove(path):
    """
    Remove a file, ignoring any error (best-effort cleanup).
    """
    try:
        os.remove(path)
    except OSError:
        pass
# ==============================================================================
#                              ENDPOINTS
# ==============================================================================
def get_info(path):
    image = Image(path)
    return {
        "image": image.get_info(),
    }
def get_size(
    path,
    size,
    font_ratio="1/2",
    square=False,
):
    """
    Calculate the target terminal size for an image.

    Parameters
    ----------
    square : bool
        When `True`, the calculation assumes the image will be
        cropped to a centered square beforehand (aspect ratio
        1:1), matching what `render(..., square=True)` produces.
        The response also includes the crop box that would be
        applied, purely as information for the caller.
    """
    image = Image(path)
    result = image.calculate_size(
        size,
        font_ratio=font_ratio,
        square=square,
    )
    response = {
        "image": {
            "path": image.path,
            "width": image.width,
            "height": image.height,
            "aspect_ratio": image.get_aspect_ratio(),
        },
        "size": result,
    }
    if square:
        response["crop"] = image.calculate_square_crop()
    return response
def render(
    path,
    size,
    chafa,
    font_ratio="1/2",
    square=False,
):
    """
    Render an image through Chafa.

    Parameters
    ----------
    square : bool
        When `True`, the image is first cropped to a centered
        square (via an external tool — see `_crop_to_square_file`)
        and Chafa renders that cropped file instead of the
        original. The terminal size is calculated accordingly
        (aspect ratio 1:1), so the result always fills the
        requested cell grid with a square image regardless of
        the original's proportions.
    """
    image = Image(path)
    info = image.inspect()
    calculated_size = image.calculate_size(
        size,
        font_ratio=font_ratio,
        square=square,
    )
    render_path = image.path
    cropped_path = None
    crop_box = None
    if square:
        crop_box = image.calculate_square_crop()
        cropped_path = _crop_to_square_file(
            image.path,
            crop_box,
        )
        render_path = cropped_path
    try:
        result = chafa.render(
            render_path,
            calculated_size,
        )
    finally:
        if cropped_path:
            _safe_remove(cropped_path)
    response = {
        "image": info,
        "size": calculated_size,
        "render": result,
    }
    if crop_box:
        response["crop"] = crop_box
    return response
