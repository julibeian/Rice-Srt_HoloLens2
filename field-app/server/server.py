#!/usr/bin/env python3
"""Independent headset application channel; reuses the existing V2 model.

No model weights are loaded here. Device credentials are provisioned once;
photos are forwarded in memory and never retained by this gateway.
"""
from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import hmac
import http.client
import json
import math
import os
import re
import secrets
import threading
import time
import uuid
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

PREFIX='/hololens-app/api'
VERSION='1.0.0'
MAX_UPLOAD=8*1024*1024
ID=re.compile(r'^[A-Za-z0-9._-]{1,80}$')

def now():return dt.datetime.now(dt.timezone.utc).isoformat()
def digest(text):return hashlib.sha256(text.encode('utf-8')).hexdigest()
def atomic(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    temporary=path.with_name(path.name+'.'+uuid.uuid4().hex+'.tmp')
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as f:
            json.dump(value,f,ensure_ascii=False,separators=(',',':'),allow_nan=False);f.flush();os.fsync(f.fileno())
        os.replace(temporary,path)
    finally:
        if temporary.exists():temporary.unlink()

class Error(Exception):
    def __init__(self,status,code,message):self.status,self.code,self.message=status,code,message

def photo(body,content_type):
    if not content_type.lower().startswith('multipart/form-data') or 'boundary=' not in content_type or '\r' in content_type or '\n' in content_type:
        raise Error(415,'multipart_required','请选择照片后上传')
    try:message=BytesParser(policy=policy.default).parsebytes(('Content-Type: '+content_type+'\r\nMIME-Version: 1.0\r\n\r\n').encode('ascii')+body)
    except (ValueError,UnicodeError):raise Error(422,'invalid_multipart','照片上传格式无效') from None
    if not message.is_multipart() or message.defects:raise Error(422,'invalid_multipart','照片上传格式无效')
    parts=list(message.iter_parts())
    if len(parts)!=1 or parts[0].get_param('name',header='content-disposition')!='file':raise Error(422,'one_photo_required','请逐张上传照片')
    data=parts[0].get_payload(decode=True)
    if not data:raise Error(422,'empty_photo','照片为空，请重新拍摄')
    if not (data.startswith(b'\xff\xd8\xff') or data.startswith(b'\x89PNG\r\n\x1a\n') or (data[:4]==b'RIFF' and data[8:12]==b'WEBP')):raise Error(415,'image_format','支持 JPEG、PNG 和 WebP 照片')
    return data

class Store:
    def __init__(self,folder,upstream='http://127.0.0.1:8002',upstream_key=None):
        self.folder=Path(folder);self.folder.mkdir(parents=True,exist_ok=True)
        self.path=self.folder/'devices.json';self.lock=threading.RLock();self.inference=threading.BoundedSemaphore(1)
        self.data=json.loads(self.path.read_text()) if self.path.exists() else {'devices':{},'pairs':{},'sessions':{},'predictions':{},'events':[]}
        target=urlsplit(upstream)
        if target.scheme!='http' or target.hostname not in ('127.0.0.1','localhost') or target.path not in ('','/'):raise ValueError('Upstream must be loopback HTTP')
        self.upstream_host=target.hostname;self.upstream_port=target.port or 80
        self.upstream_key=upstream_key or secrets.token_urlsafe(48)
        self.attempts={}
    def save(self):atomic(self.path,self.data)
    def issue_pair(self):
        code=''.join(secrets.choice('0123456789') for _ in range(8));expires=time.time()+900
        # Separate one-use files let the local administration CLI issue a code
        # while the HTTP service is running without overwriting its device store.
        folder=self.folder/'pair-codes';folder.mkdir(mode=0o700,exist_ok=True)
        with self.lock:
            for item in folder.glob('*.json'):
                try:
                    if json.loads(item.read_text())['expires_epoch']<=time.time():item.unlink()
                except (OSError,ValueError,KeyError):continue
            atomic(folder/(digest(code)+'.json'),{'expires_epoch':expires})
        return {'pair_code':code,'expires_epoch':expires}
    def register(self,value,peer):
        code=value.get('pair_code');label=value.get('device_label','HoloLens 2')
        if not isinstance(code,str) or not re.fullmatch(r'\d{8}',code) or not isinstance(label,str) or len(label)>80:raise Error(422,'invalid_pair','请输入有效的设备配对码')
        with self.lock:
            stamp=time.time();attempts=[t for t in self.attempts.get(peer,[]) if stamp-t<60]
            if len(attempts)>=6:raise Error(429,'pair_rate_limit','配对尝试过多，请稍后重试')
            attempts.append(stamp)
            if len(self.attempts)>256:self.attempts.clear()
            self.attempts[peer]=attempts
            pair_path=self.folder/'pair-codes'/(digest(code)+'.json')
            try:pair=json.loads(pair_path.read_text())
            except (OSError,ValueError):pair=None
            if not pair or pair['expires_epoch']<=stamp:raise Error(401,'invalid_pair','配对码已失效，请使用新的配对码')
            pair_path.unlink()
            device_id='hl-'+secrets.token_hex(12);key=secrets.token_urlsafe(48)
            self.data['devices'][device_id]={'key_hash':digest(key),'label':label,'created_at':now(),'revoked':False}
            self.save()
        return {'device_id':device_id,'device_key':key}
    def session(self,value):
        device_id=value.get('device_id');key=value.get('device_key')
        if not isinstance(device_id,str) or not isinstance(key,str) or len(key)>256:raise Error(401,'device_auth','请重新连接识别服务')
        with self.lock:
            row=self.data['devices'].get(device_id)
            if not row or row.get('revoked') or not hmac.compare_digest(row['key_hash'],digest(key)):raise Error(401,'device_auth','设备连接已失效，请重新配对')
            token=secrets.token_urlsafe(40);expires=time.time()+3600
            self.data['sessions']={k:v for k,v in self.data['sessions'].items() if v['expires_epoch']>time.time()}
            self.data['sessions'][digest(token)]={'device_id':device_id,'expires_epoch':expires};self.save()
        return {'access_token':token,'expires_epoch':expires,'device_id':device_id}
    def authenticate(self,authorization):
        if not authorization.startswith('Bearer ') or len(authorization)>300:raise Error(401,'auth_required','请先连接识别服务')
        with self.lock:
            session=self.data['sessions'].get(digest(authorization[7:]))
            if not session or session['expires_epoch']<=time.time():raise Error(401,'session_expired','连接已过期，请重试')
            row=self.data['devices'].get(session['device_id'])
            if not row or row.get('revoked'):raise Error(401,'device_revoked','设备连接已失效')
            return session['device_id']
    def record(self,device,event,details):
        if not isinstance(event,str) or not re.fullmatch(r'[a-z][a-z0-9_]{0,63}',event) or not isinstance(details,dict):raise Error(422,'invalid_event','状态记录格式无效')
        cleaned={}
        for key,value in details.items():
            if len(cleaned)>=16:break
            if isinstance(key,str) and re.fullmatch(r'[a-z_]{1,40}',key) and not any(x in key for x in ('token','password','key','image_data','url')):
                if isinstance(value,str):cleaned[key]=value[:180]
                elif value is None or type(value) in (int,bool) or (type(value) is float and math.isfinite(value)):cleaned[key]=value
        with self.lock:self.data['events']=(self.data['events']+[{'device_id':device,'event':event,'at':now(),'details':cleaned}])[-100:];self.save()
    def predict(self,device,request_id,image_hash,body,content_type):
        if not ID.fullmatch(request_id) or not re.fullmatch(r'[a-f0-9]{64}',image_hash):raise Error(422,'invalid_capture_id','照片校验信息缺失')
        data=photo(body,content_type)
        if not hmac.compare_digest(hashlib.sha256(data).hexdigest(),image_hash):raise Error(422,'photo_hash','照片校验失败，请重新上传')
        key=device+':'+request_id
        def previous():
            with self.lock:
                row=self.data['predictions'].get(key)
                if row:
                    if row['image_sha256']!=image_hash:raise Error(409,'request_reused','本次编号对应的照片已改变')
                    return row['result']
        cached=previous()
        if cached:return cached
        if not self.inference.acquire(False):raise Error(429,'busy','识别服务正在处理照片，请稍后重试')
        try:
            cached=previous()
            if cached:return cached
            received=now();started=time.monotonic();connection=http.client.HTTPConnection(self.upstream_host,self.upstream_port,timeout=45)
            try:
                connection.request('POST','/predict',body=body,headers={'Content-Type':content_type,'Content-Length':str(len(body)),'X-Rice-Channel-Key':self.upstream_key,'X-Request-ID':request_id})
                response=connection.getresponse();payload=response.read(262145)
                if response.status!=200 or len(payload)>262144:raise Error(502,'upstream_failed','识别服务暂时无法处理照片')
                result=json.loads(payload)
            except (OSError,TimeoutError,http.client.HTTPException):raise Error(504,'upstream_timeout','识别超时，请稍后重试') from None
            except (ValueError,UnicodeError):raise Error(502,'upstream_response','识别服务返回格式异常') from None
            finally:connection.close()
            if (not isinstance(result,dict) or not isinstance(result.get('predicted_class'),str) or type(result.get('is_valid')) is not bool or type(result.get('confidence')) not in (int,float) or not math.isfinite(result['confidence']) or not 0<=result['confidence']<=1):raise Error(502,'upstream_response','识别服务返回格式异常')
            result={k:result[k] for k in ('predicted_class','confidence','is_valid','message','top3_predictions') if k in result}
            result['capture_evidence']={'channel':'hololens-app','device_id':device,'request_id':request_id,'image_sha256':image_hash,'prediction_id':uuid.uuid4().hex,'received_at':received,'completed_at':now(),'upstream_elapsed_ms':round((time.monotonic()-started)*1000,2)}
            with self.lock:
                self.data['predictions'][key]={'image_sha256':image_hash,'result':result}
                while len(self.data['predictions'])>64:del self.data['predictions'][next(iter(self.data['predictions']))]
                self.save()
            return result
        finally:self.inference.release()

class Server(ThreadingHTTPServer):
    daemon_threads=True
    allow_reuse_address=True
    def __init__(self,address,store):self.store=store;super().__init__(address,Handler)

class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    server_version='RiceHoloLensField/'+VERSION
    sys_version=''
    def log_message(self,format,*args):print(json.dumps({'at':now(),'method':self.command,'path':urlsplit(self.path).path,'status':str(args[1]) if len(args)>1 else ''}),flush=True)
    def send(self,status,value):
        body=json.dumps(value,ensure_ascii=False,allow_nan=False,separators=(',',':')).encode('utf-8')
        self.send_response(status);self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-store');self.send_header('X-Content-Type-Options','nosniff');self.end_headers();self.wfile.write(body)
    def read(self,limit):
        if self.headers.get('Transfer-Encoding'):raise Error(411,'length_required','上传需要明确文件大小')
        try:length=int(self.headers.get('Content-Length','-1'))
        except ValueError:raise Error(400,'invalid_length','上传大小无效') from None
        if length<0:raise Error(411,'length_required','上传大小缺失')
        if length>limit:raise Error(413,'too_large','照片过大，请重新拍摄')
        self.connection.settimeout(60);body=self.rfile.read(length)
        if len(body)!=length:raise Error(400,'incomplete_upload','照片传输未完成')
        return body
    def json_body(self):
        if not self.headers.get('Content-Type','').lower().startswith('application/json'):raise Error(415,'json_required','请求格式无效')
        try:value=json.loads(self.read(16384))
        except (ValueError,UnicodeError):raise Error(422,'invalid_json','请求格式无效') from None
        if not isinstance(value,dict):raise Error(422,'invalid_json','请求格式无效')
        return value
    def do_GET(self):
        path=urlsplit(self.path).path
        try:
            if path==PREFIX+'/health':self.send(200,{'status':'ok','channel':'hololens-app','version':VERSION});return
            if path==PREFIX+'/diagnostics':
                device=self.server.store.authenticate(self.headers.get('Authorization',''))
                with self.server.store.lock:rows=[x for x in self.server.store.data['events'] if x['device_id']==device]
                self.send(200,{'events':rows});return
            raise Error(404,'not_found','接口不存在')
        except Error as e:self.send(e.status,{'error':e.code,'message':e.message})
    def do_POST(self):
        path=urlsplit(self.path).path;store=self.server.store
        try:
            if path==PREFIX+'/register':self.send(200,store.register(self.json_body(),self.headers.get('X-Real-IP',self.client_address[0])));return
            if path==PREFIX+'/session':self.send(200,store.session(self.json_body()));return
            device=store.authenticate(self.headers.get('Authorization',''))
            if path==PREFIX+'/events':
                value=self.json_body();store.record(device,value.get('event'),value.get('details',{}));self.send(200,{'ok':True});return
            if path==PREFIX+'/predict':
                result=store.predict(device,self.headers.get('X-Request-ID',''),self.headers.get('X-Image-SHA256',''),self.read(MAX_UPLOAD),self.headers.get('Content-Type',''));self.send(200,result);return
            raise Error(404,'not_found','接口不存在')
        except Error as e:
            self.close_connection=True;self.send(e.status,{'error':e.code,'message':e.message})
        except (OSError,TimeoutError):self.close_connection=True
        except Exception:
            self.close_connection=True;self.send(500,{'error':'internal_error','message':'服务暂不可用，请稍后重试'})

def main():
    parser=argparse.ArgumentParser();parser.add_argument('command',choices=['serve','pair-code']);parser.add_argument('--data-dir',required=True);parser.add_argument('--port',type=int,default=9013);parser.add_argument('--upstream',default='http://127.0.0.1:8002');parser.add_argument('--upstream-key-file')
    args=parser.parse_args();key=Path(args.upstream_key_file).read_text().strip() if args.upstream_key_file else None
    store=Store(args.data_dir,args.upstream,key)
    if args.command=='pair-code':print(json.dumps(store.issue_pair()));return
    if not key or len(key)<32:raise SystemExit('Provide a private upstream channel key')
    Server(('127.0.0.1',args.port),store).serve_forever()
if __name__=='__main__':main()
