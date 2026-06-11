#!/usr/bin/env python3
"""Filter narrow-arith fuzz corpus entries down to WebGPU/WebGL API-reachable
ones and re-evaluate whether the 32-bit narrow arithmetic still wraps.

Hard public-API limits used (stricter of WebGPU spec defaults and WebGL2 common
values):
  maxTextureDimension2D = 16384      (width, height)
  maxTextureDimension3D = 2048       (depth when used as 3D texture)
  maxTextureArrayLayers = 2048       (layerCount, arrayLayer)
  maxBufferSize         = 4*1024**3 - 4   (bytesPerRow, offset)
  pixelBytes_max        = 32         (largest supported uncompressed bpp)
  blockByteSize_max     = 32
  dispatch_id_max       = 65535
"""
from __future__ import annotations

import os
import sys
from dataclasses import dataclass

REPO = os.path.dirname(os.path.abspath(__file__)) + "/.."

MAX_DIM_2D = 16384
MAX_DIM_3D = 2048
MAX_ARRAY_LAYERS = 2048
MAX_BUFFER = (4 * 1024 ** 3) - 4
MAX_PIXEL_BYTES = 32
MAX_BLOCK_BYTES = 32
MAX_DISPATCH = 65535


def parse(path):
    d = {}
    try:
        with open(path, "rb") as f:
            for line in f.read().splitlines():
                try:
                    line = line.decode("latin-1")
                except Exception:
                    return None
                if "=" in line:
                    k, v = line.split("=", 1)
                    k = k.strip()
                    v = v.strip()
                    if v and all(c in "0123456789" for c in v):
                        try:
                            d[k] = int(v)
                        except ValueError:
                            pass
    except Exception:
        return None
    return d


def check_limits(d):
    w = d.get("width", 0)
    h = d.get("height", 0)
    if w > MAX_DIM_2D or h > MAX_DIM_2D:
        return False
    if d.get("depth", 0) > MAX_DIM_3D:
        return False
    if d.get("layer", 0) > MAX_ARRAY_LAYERS:
        return False
    if d.get("layerCount", 0) > MAX_ARRAY_LAYERS:
        return False
    if d.get("arrayLayer", 0) > MAX_ARRAY_LAYERS:
        return False
    if d.get("rowsPerImage", 0) > MAX_DIM_2D:
        return False
    for k in ("pixelBytes", "srcPixelBytes", "dstPixelBytes"):
        if d.get(k, 0) > MAX_PIXEL_BYTES:
            return False
    if d.get("blockByteSize", 0) > MAX_BLOCK_BYTES:
        return False
    # WebGPU spec §GPUImageDataLayout: bytesPerRow must be a multiple of 256
    bpr = d.get("bytesPerRow", 0)
    if bpr > 0 and bpr % 256 != 0:
        return False
    if bpr > MAX_BUFFER:
        return False
    if d.get("offset", 0) > MAX_BUFFER:
        return False
    if d.get("hostBpr", 0) > MAX_BUFFER:
        return False
    if d.get("hostRows", 0) > MAX_DIM_2D:
        return False
    if d.get("uploadBpr", 0) > MAX_BUFFER:
        return False
    if d.get("uploadRows", 0) > MAX_DIM_2D:
        return False
    if d.get("hostOffset", 0) > MAX_BUFFER:
        return False
    if d.get("uploadOffset", 0) > MAX_BUFFER:
        return False
    if d.get("hostUnit", 0) > MAX_PIXEL_BYTES:
        return False
    if d.get("uploadUnit", 0) > MAX_PIXEL_BYTES:
        return False
    if d.get("outputUnitSize", 0) > MAX_PIXEL_BYTES:
        return False
    for k in ("idX", "idY", "idZ"):
        if d.get(k, 0) > MAX_DISPATCH:
            return False
    return True


def n32(x):
    return x & 0xFFFFFFFF


def wrap_check_bytes_per_image(d):
    bpr = d.get("bytesPerRow", 0)
    rows = d.get("rowsPerImage", 0)
    layer = d.get("arrayLayer", 0)
    narrow = n32(n32(bpr) * n32(rows))
    wide = bpr * rows
    if narrow != wide:
        return True
    narrow_pa = n32(n32(layer) * n32(narrow))
    wide_pa = layer * wide
    return narrow_pa != wide_pa


def wrap_check_d3d11(d):
    bpr = d.get("bytesPerRow", 0)
    rows = d.get("rowsPerImage", 0)
    layer = d.get("layer", 0)
    h = d.get("height", 0)
    n_depth = n32(n32(bpr) * n32(rows))
    w_depth = bpr * rows
    if n_depth != w_depth:
        return True
    n_la = n32(n32(layer) * n32(n_depth))
    w_la = layer * w_depth
    if n_la != w_la:
        return True
    n_cb = n32(n32(bpr) * n32(h))
    w_cb = bpr * h
    return n_cb != w_cb


def wrap_check_texture_vk(d):
    w = d.get("width", 0)
    h = d.get("height", 0)
    depth = d.get("depth", 0)
    pb = d.get("pixelBytes", 0)
    n_row = n32(n32(w) * n32(pb))
    w_row = w * pb
    if n_row != w_row:
        return True
    n_depth = n32(n_row * n32(h))
    w_depth = w_row * h
    if n_depth != w_depth:
        return True
    n_layer = n32(n_depth * n32(depth))
    w_layer = w_depth * depth
    return n_layer != w_layer


def wrap_check_image11(d):
    w = d.get("width", 0)
    h = d.get("height", 0)
    pb = d.get("pixelBytes", 0)
    n_row = n32(n32(pb) * n32(w))
    w_row = pb * w
    if n_row != w_row:
        return True
    n_buf = n32(n_row * n32(h))
    w_buf = w_row * h
    return n_buf != w_buf


def wrap_check_blit_gl(d):
    w = d.get("width", 0)
    h = d.get("height", 0)
    pb = d.get("pixelBytes", 0)
    n_buf = n32(n32(w) * n32(h))
    n_buf = n32(n_buf * n32(pb))
    w_buf = w * h * pb
    return n_buf != w_buf


def wrap_check_vk_helpers(d):
    # Actual code (reformatStagedBufferUpdates): only step 1 is narrowed.
    #   const size_t srcDataRowPitch = copy.imageExtent.width * srcFormat.pixelBytes;
    #     ↑ uint32_t × GLuint → uint32_t then widened to size_t
    #   const size_t srcDataDepthPitch = srcDataRowPitch * copy.imageExtent.height;
    #     ↑ size_t × uint32_t → size_t (64-bit, no narrowing)
    #   size_t dstBufferSize = dstDataDepthPitch * copy.imageExtent.depth;
    #     ↑ size_t × uint32_t → size_t (64-bit, no narrowing)
    # So only the row multiplication can be a true 32-bit overflow.
    w = d.get("width", 0)
    h = d.get("height", 0)
    depth = d.get("depth", 0)
    src_pb = d.get("srcPixelBytes", 0)
    dst_pb = d.get("dstPixelBytes", 0)
    for pb in (src_pb, dst_pb):
        # Step 1: uint32_t narrowing
        n_row = n32(n32(w) * n32(pb))
        w_row = w * pb
        if n_row != w_row:
            return True
        # Steps 2-3: size_t (64-bit) — no 32-bit narrowing possible
        # These cannot wrap under API limits on 64-bit platforms
    return False


def wrap_check_texture_mtl(d):
    w = d.get("width", 0)
    h = d.get("height", 0)
    src_pb = d.get("srcPixelBytes", 0)
    dst_pb = d.get("dstPixelBytes", 0)
    for pb in (src_pb, dst_pb):
        n_row_u = (pb * w) & 0xFFFFFFFF
        n_row = n_row_u - 2 ** 32 if n_row_u >= 2 ** 31 else n_row_u
        n_img_u = (n_row * h) & 0xFFFFFFFF
        n_img = n_img_u - 2 ** 32 if n_img_u >= 2 ** 31 else n_img_u
        w_img = (pb * w) * h
        if n_img != w_img:
            return True
    return False


def wrap_check_blit_texture_to_buffer(d):
    bpr = d.get("uploadBpr", d.get("hostBpr", 0))
    rows = d.get("uploadRows", d.get("hostRows", 0))
    offset = d.get("uploadOffset", d.get("hostOffset", 0))
    idx = d.get("idX", 0)
    idy = d.get("idY", 0)
    idz = d.get("idZ", 0)
    unit = d.get("uploadUnit", d.get("hostUnit", 0))
    n_plane = n32(n32(bpr) * n32(rows))
    w_plane = bpr * rows
    if n_plane != w_plane:
        return True
    n_off = n32(
        n32(offset)
        + n32(idx) * n32(unit)
        + n32(idy) * n32(bpr)
        + n32(idz) * n_plane
    )
    w_off = offset + idx * unit + idy * bpr + idz * w_plane
    return n_off != w_off


@dataclass
class Site:
    name: str
    corpus_dir: str
    wrap_check: callable


SITES = [
    Site(
        "dawn_bytes_per_image_narrow",
        "fuzz/corpus/dawn_bytes_per_image_narrow_remote_20260414",
        wrap_check_bytes_per_image,
    ),
    Site(
        "dawn_d3d11_bytes_per_row_narrow",
        "fuzz/corpus/dawn_d3d11_bytes_per_row_narrow_remote_20260414",
        wrap_check_d3d11,
    ),
    Site(
        "angle_texture_vk_pitch_narrow",
        "fuzz/corpus/angle_texture_vk_pitch_narrow_remote_20260414",
        wrap_check_texture_vk,
    ),
    Site(
        "angle_image11_scratch_narrow",
        "fuzz/corpus/angle_image11_scratch_narrow_fuzzer_remote_20260414",
        wrap_check_image11,
    ),
    Site(
        "angle_blit_gl_scratch_narrow",
        "fuzz/corpus/angle_blit_gl_scratch_narrow_fuzzer_remote_20260414",
        wrap_check_blit_gl,
    ),
    Site(
        "angle_vk_helpers_reformat_narrow",
        "fuzz/corpus/angle_vk_helpers_reformat_narrow_fuzzer_remote_20260414",
        wrap_check_vk_helpers,
    ),
    Site(
        "angle_texture_mtl_image_size_narrow",
        "fuzz/corpus/angle_texture_mtl_image_size_narrow_fuzzer_remote_20260414",
        wrap_check_texture_mtl,
    ),
    Site(
        "dawn_blit_texture_to_buffer_u32_offset",
        "fuzz/corpus/dawn_blit_texture_to_buffer_u32_offset_narrow_fuzzer_remote_20260414",
        wrap_check_blit_texture_to_buffer,
    ),
]


def main():
    print(f"{'site':<42} total   reachable  still_wrap")
    print("-" * 80)
    total_all = 0
    reach_all = 0
    wrap_all = 0
    for s in SITES:
        full = os.path.join(REPO, s.corpus_dir)
        if not os.path.isdir(full):
            print(f"{s.name:<42} MISSING  {full}")
            continue
        files = [f for f in os.listdir(full) if not f.startswith(".")]
        n_total = len(files)
        n_reach = 0
        n_wrap = 0
        survivors = []
        for fn in sorted(files):
            d = parse(os.path.join(full, fn))
            if d is None:
                continue
            if check_limits(d):
                n_reach += 1
                if s.wrap_check(d):
                    n_wrap += 1
                    survivors.append((fn, d))
        total_all += n_total
        reach_all += n_reach
        wrap_all += n_wrap
        print(f"{s.name:<42} {n_total:>5}   {n_reach:>8}   {n_wrap:>9}")
        for fn, d in survivors[:3]:
            print(f"    WRAP witness: {fn[:16]} {d}")
    print("-" * 80)
    print(f"{'TOTAL':<42} {total_all:>5}   {reach_all:>8}   {wrap_all:>9}")


if __name__ == "__main__":
    main()
