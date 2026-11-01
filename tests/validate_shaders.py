"""Validate every stage and link every program without requiring a window or GPU."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
root = Path(sys.argv[1])
validator = sys.argv[2]
with tempfile.TemporaryDirectory() as temp:
    stages = {}
    for name, source in re.findall(r'//#(\w+)\s*([\s\S]*?)(?=//#|$)', (root/'engine.glsl').read_text()):
        path = Path(temp)/(name+('.vert' if 'VERTEX' in name else '.frag'))
        path.write_text('#version 330 core\n'+source)
        stages[name] = path
        subprocess.run([validator, str(path)], check=True)
    for vert, frag in [('MESH','SCENE'), ('FULLSCREEN','BLUR'), ('FULLSCREEN','TEMPORAL'), ('FULLSCREEN','COMPOSITE'), ('BACKGROUND','BACKGROUND'), ('BEAM','BEAM')]:
        subprocess.run([validator, '-l', str(stages[vert+'_VERTEX_SHADER']), str(stages[frag+'_FRAGMENT_SHADER'])], check=True)
    for name in ['caustic','receiver','incident','shadow','camera']:
        subprocess.run([validator, '-l', str(root/'shaders'/(name+'.vert')), str(root/'shaders'/(name+'.frag'))], check=True)
print('All eleven shader programs compile and link in glslang.')
