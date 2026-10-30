#!/usr/bin/env python3
"""Add one authenticated relay bypass to /predict; never touch weights."""
import argparse
import ast
from pathlib import Path

MARKER='# Rice HoloLens application: authenticated independent result channel'
HELPER='''
# Rice HoloLens application: authenticated independent result channel
def _rice_hololens_channel(channel_key):
    import hmac
    try:
        expected = Path("/var/lib/rice-hololens-app/upstream.key").read_text().strip()
        return bool(channel_key and len(expected) >= 32 and hmac.compare_digest(channel_key, expected))
    except OSError:
        return False

'''

def patch(source):
    ast.parse(source)
    if MARKER in source:
        if 'x_rice_channel_key: str = Header(default="")' not in source or 'if not _rice_hololens_channel(x_rice_channel_key):' not in source:
            raise ValueError('Partially changed upstream; manual inspection required')
        return source
    tree=ast.parse(source)
    predictions=[n for n in tree.body if isinstance(n,ast.AsyncFunctionDef) and n.name=='predict']
    if len(predictions)!=1:raise ValueError('Expected exactly one existing predict function')
    node=predictions[0]
    lines=source.splitlines(keepends=True)
    block=''.join(lines[node.lineno-1:node.end_lineno])
    signature='async def predict(file: UploadFile = File(...)):'
    forward='        _forward_to_pc_safe(file, result)'
    if block.count(signature)!=1 or block.count(forward)!=1:raise ValueError('Upstream predict contract changed')
    changed=block.replace(signature,'async def predict(file: UploadFile = File(...), x_rice_channel_key: str = Header(default="")):').replace(forward,'        if not _rice_hololens_channel(x_rice_channel_key):\n    '+forward)
    source=source.replace(block,changed,1)
    import_line='from fastapi import FastAPI, UploadFile, File, HTTPException'
    if source.count(import_line)!=1:raise ValueError('Expected known FastAPI import')
    source=source.replace(import_line,import_line+', Header',1)
    route='@app.post("/predict")'
    if source.count(route)!=1:raise ValueError('Expected known predict route')
    source=source.replace(route,HELPER+route,1)
    ast.parse(source)
    return source

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('source');parser.add_argument('--apply',action='store_true');args=parser.parse_args()
    path=Path(args.source);old=path.read_text(encoding='utf-8');new=patch(old)
    if args.apply and new!=old:path.write_text(new,encoding='utf-8')
    print('relay_bypass_ready' if new!=old else 'relay_bypass_already_present')
