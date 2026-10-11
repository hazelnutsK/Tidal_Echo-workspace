"""Relay adapter: private VPS control plus a mirror of only new VPS sessions."""
import base64
import hashlib
import json
import os
import pathlib
import threading
import time
import urllib.request

CONFIG = pathlib.Path(__file__).with_name('cc-on-vps.json')
LOCK = threading.RLock()
KNOWN = {}
LAST_SYNC = 0.0
LAST_STATE = {}
SEEDED = False

def config():
    try: return json.loads(CONFIG.read_text(encoding='utf-8-sig'))
    except (OSError,ValueError): return {}

def enabled():
    j=config();return bool(j.get('enabled') and j.get('control_token'))

def project_dir():
    return pathlib.Path(config()['mirror_dir'])/'sessions'

def forge_dir():
    return pathlib.Path(config()['mirror_dir'])/'forge'

def request(path,body=None,timeout=12):
    j=config()
    req=urllib.request.Request('http://127.0.0.1:13012'+path,data=json.dumps(body or {}).encode(),
        headers={'Authorization':'Bearer '+j['control_token'],'Content-Type':'application/json'},method='POST')
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req,timeout=timeout) as r:return json.load(r)

def sync(force=False):
    global LAST_SYNC,LAST_STATE,SEEDED
    with LOCK:
        if not force and time.monotonic()-LAST_SYNC<2:return LAST_STATE
        if not SEEDED:
            root=pathlib.Path(config()['mirror_dir'])
            for kind in ('sessions','forge'):
                for p in (root/kind).glob('*'):
                    if p.is_file() and p.suffix in ('.jsonl','.md'):
                        data=p.read_bytes();KNOWN[kind+'/'+p.name]={'size':len(data),'sha256':hashlib.sha256(data).hexdigest()}
            SEEDED=True
        j=request('/snapshot',{'known':KNOWN})
        root=pathlib.Path(config()['mirror_dir'])
        for item in j['files']:
            rel=pathlib.PurePosixPath(item['path'])
            if '..' in rel.parts or len(rel.parts)!=2 or rel.parts[0] not in ('sessions','forge'):raise ValueError('Invalid snapshot path')
            p=root.joinpath(*rel.parts);p.parent.mkdir(parents=True,exist_ok=True)
            data=base64.b64decode(item['data'],validate=True)
            start=item['start']
            if start:
                if not p.exists() or p.stat().st_size!=start:KNOWN.pop(item['path'],None);continue
                data=p.read_bytes()+data
            if len(data)!=item['size'] or hashlib.sha256(data).hexdigest()!=item['sha256']:raise ValueError('Invalid snapshot digest')
            tmp=p.with_suffix(p.suffix+'.part');tmp.write_bytes(data)
            os.utime(tmp,(item['mtime'],item['mtime']));os.replace(tmp,p)
            KNOWN[item['path']]={'size':item['size'],'sha256':item['sha256']}
        LAST_STATE={k:v for k,v in j.items() if k!='files'}
        LAST_SYNC=time.monotonic()
        return LAST_STATE

def pids():
    with LOCK:return request('/status')['pids']

def stop():
    with LOCK:
        result=request('/stop',timeout=15)
        sync(force=True)
        return result['killed']

def start(sid='',model=''):
    global LAST_STATE
    with LOCK:
        body={'sid':sid,'model':model}
        if sid:
            p=project_dir()/(sid+'.jsonl')
            if p.exists():body['session_data']=base64.b64encode(p.read_bytes()).decode()
        result=request('/start',body,timeout=20)
        LAST_STATE={**LAST_STATE,'active_sid':result['active_sid']}
        try:sync(force=True)
        except (OSError,ValueError):pass  # mirror retries must not roll back a successful start
        return result

def upload_forge(p):
    with LOCK:
        if p.is_file():request('/forge',{'name':p.name,'data':base64.b64encode(p.read_bytes()).decode()})

def write_elsewhere(callback,transcript):
    with LOCK:
        exists=callback(transcript)
        if exists:upload_forge(forge_dir()/'elsewhere.md')
        return exists

def rewrite_forge_paths(text,local_dir):
    for name in ('summary.md','note.md','elsewhere.md','redlines.md'):
        text=text.replace(str(local_dir/name),'/home/xiaoxue/workspace/forge/'+name)
    return text

def quota():
    return request('/quota',timeout=25)
