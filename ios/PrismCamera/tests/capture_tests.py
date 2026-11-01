"""Check exported conventions with an independently constructed tiny capture."""
from pathlib import Path
import importlib.util
import json
import struct
import tempfile
import zipfile
import zlib

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("capture_inspector", root/"inspect_capture.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def png():
    def chunk(name, data):
        return struct.pack(">I",len(data))+name+data+struct.pack(">I",zlib.crc32(name+data)&0xffffffff)
    return b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",2,2,8,2,0,0,0))+chunk(b"IDAT",zlib.compress(bytes(14)))+chunk(b"IEND",b"")

metadata = {
    "schema":"spectral-studio.capture.v1", "ar_frame_timestamp_seconds":1.25, "tracking_state":"normal",
    "camera_image":{"width":2,"height":2}, "display":{"width":2,"height":2},
    "camera_to_world_column_major":[1,0,0,0,0,1,0,0,0,0,1,0,1,2,3,1],
    "depth":{"width":2,"height":2,"row_stride_bytes":8,"file":"depth.f32",
             "intrinsics_column_major":[2,0,0,0,2,0,0,0,1],"confidence":{"file":"confidence.u8"}}
}
with tempfile.TemporaryDirectory() as directory:
    path=Path(directory)/"capture.zip"
    with zipfile.ZipFile(path,"w") as archive:
        archive.writestr("metadata.json",json.dumps(metadata))
        archive.writestr("camera.png",png())
        archive.writestr("render.png",png())
        archive.writestr("depth.f32",struct.pack("<4f",1,2,float("nan"),4))
        archive.writestr("confidence.u8",bytes([2,1,2,0]))
    _, points = module.inspect(path,Path(directory)/"cloud.ply")
    assert points == [(1.0,2.0,2.0,2),(2.0,2.0,1.0,1)], points
    assert "element vertex 2" in (Path(directory)/"cloud.ply").read_text()
print("PASS: calibration convention, world-space unprojection, NaN/low-confidence rejection, PLY export")
