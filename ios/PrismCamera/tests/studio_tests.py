from pathlib import Path
import json
import struct
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="spectral-studio-") as directory:
    output = Path(directory)
    subprocess.run(["xcrun","swiftc","-module-cache-path",str(output/"cache"),
                    str(root/"PrismCamera/InteractionMath.swift"),str(root/"PrismCamera/StoredZIP.swift"),
                    str(root/"tests/studio_tests.swift"),"-o",str(output/"test")],check=True)
    subprocess.run([str(output/"test"),str(output/"capture.zip")],check=True)
    with zipfile.ZipFile(output/"capture.zip") as archive:
        assert archive.testzip() is None, "ZIP CRC or directory corruption"
        assert json.loads(archive.read("metadata.json"))["schema"] == "test"
        assert struct.unpack("<4f", archive.read("depth.f32")) == (1,2,3,4)
        assert archive.read("empty.bin") == b""
        assert archive.read("unicode-é.txt") == b"prism"
    print("PASS: exported ZIP recognized by Python, checksums, JSON, lossless depth, Unicode and empty files")
