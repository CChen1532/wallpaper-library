#!/usr/bin/env python3
import hashlib,json,pathlib,sys
root=pathlib.Path(__file__).resolve().parent.parent/'Scenes/LunarObservatory'
spec=json.loads((root/'asset-manifest.json').read_text());path=root/spec['localFile']
if not path.is_file():sys.exit('NASA Moon asset missing: '+str(path)+'; source: '+spec['sourceFile'])
h=hashlib.sha256()
with path.open('rb') as f:
 for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
if path.stat().st_size!=spec['bytes'] or h.hexdigest()!=spec['sha256']:sys.exit('NASA Moon asset size/SHA-256 mismatch')
print('NASA Moon asset verified:',spec['bytes'],'bytes;',spec['sha256'])
