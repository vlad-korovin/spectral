#!/usr/bin/env python3
"""Validate a Spectral Studio capture and optionally reconstruct a confidence-filtered point cloud.

Uses Python's standard library only. No files are extracted from the ZIP.
"""
import argparse
import array
import json
import math
from pathlib import Path
import struct
import sys
import zipfile


def inspect(path, ply=None):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError("Capture ZIP checksum failure")
        metadata = json.loads(archive.read("metadata.json"))
        if metadata.get("schema") != "spectral-studio.capture.v1":
            raise ValueError("Unsupported capture schema")
        for name, spec in [("camera.png", metadata["camera_image"]), ("render.png", metadata["display"])]:
            data = archive.read(name)
            if data[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", data[16:24]) != (spec["width"], spec["height"]):
                raise ValueError(f"{name} dimensions do not match calibration")
        print(f"Frame {metadata['ar_frame_timestamp_seconds']:.6f} · {metadata['tracking_state']}")
        info = metadata.get("depth")
        if info is None:
            print("No depth in this capture; no point cloud can be reconstructed.")
            if ply:
                raise ValueError("Point cloud requires recorded depth and confidence")
            return metadata, []
        w, h = info["width"], info["height"]
        data = archive.read(info["file"])
        if len(data) != w*h*4 or info["row_stride_bytes"] != w*4:
            raise ValueError("Depth dimensions or packing are inconsistent")
        depths = array.array("f")
        depths.frombytes(data)
        if sys.byteorder != "little":
            depths.byteswap()
        confidence_info = info.get("confidence")
        if confidence_info is None:
            raise ValueError("No confidence data; refusing to label an unfiltered cloud valid")
        confidence = archive.read(confidence_info["file"])
        if len(confidence) != w*h:
            raise ValueError("Confidence dimensions do not match depth")
        k = info["intrinsics_column_major"]
        pose = metadata["camera_to_world_column_major"]
        if len(k) != 9 or len(pose) != 16 or not all(math.isfinite(v) for v in k+pose):
            raise ValueError("Calibration matrices must be finite and column major")
        if k[0] <= 0 or k[4] <= 0 or abs(k[2])+abs(k[5])+abs(k[8]-1)>1e-5:
            raise ValueError("Unsupported camera intrinsic matrix")
        points = []
        for i, z in enumerate(depths):
            if confidence[i] < 1 or not math.isfinite(z) or z <= 0:
                continue
            x, y = i % w, i // w
            # Pinhole inverse, including skew. Image camera axes -> ARKit camera axes.
            camera_y = (y-k[7])/k[4]
            camera_x = (x-k[6]-k[3]*camera_y)/k[0]
            camera = (camera_x*z, -camera_y*z, -z)
            world = tuple(sum(pose[c*4+r]*camera[c] for c in range(3))+pose[12+r] for r in range(3))
            points.append((*world, confidence[i]))
        print(f"Depth {w}×{h}: {len(points)}/{w*h} finite, positive, medium/high-confidence samples")
        if points:
            print(f"Valid depth range: {min(z for z,c in zip(depths,confidence) if c>=1 and math.isfinite(z) and z>0):.3f}–"
                  f"{max(z for z,c in zip(depths,confidence) if c>=1 and math.isfinite(z) and z>0):.3f} m")
        if ply:
            with Path(ply).open("w") as output:
                output.write("ply\nformat ascii 1.0\ncomment ARKit world coordinates in meters\n")
                output.write(f"element vertex {len(points)}\nproperty float x\nproperty float y\nproperty float z\n")
                output.write("property uchar confidence\nend_header\n")
                for x,y,z,c in points:
                    output.write(f"{x:.6f} {y:.6f} {z:.6f} {c}\n")
            print(f"Point cloud written to {ply}")
        return metadata, points


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--ply", type=Path, help="Write the reconstructed world-space point cloud")
    arguments = parser.parse_args()
    try:
        inspect(arguments.capture, arguments.ply)
    except (ValueError, KeyError, OSError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Invalid capture: {error}\n")
