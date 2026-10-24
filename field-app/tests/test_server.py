import hashlib
import http.client
import importlib.util
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);sys.modules[name]=m;spec.loader.exec_module(m);return m
app=module('field_gateway',ROOT/'server/server.py')
patcher=module('field_patcher',ROOT/'server/patch_upstream.py')

class Upstream(BaseHTTPRequestHandler):
    calls=[]
    def do_POST(self):
        body=self.rfile.read(int(self.headers['Content-Length']));self.__class__.calls.append((self.path,dict(self.headers),body))
        data=json.dumps({'predicted_class':'其他','confidence':0.9,'is_valid':False,'message':'请重拍','top3_predictions':[['其他',0.9]]}).encode()
        self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def log_message(self,*args):pass

class Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();Upstream.calls=[]
        self.upstream=ThreadingHTTPServer(('127.0.0.1',0),Upstream);threading.Thread(target=self.upstream.serve_forever,daemon=True).start()
        self.store=app.Store(self.temp.name,'http://127.0.0.1:'+str(self.upstream.server_port),'server-only-key-'*4)
        self.server=app.Server(('127.0.0.1',0),self.store);threading.Thread(target=self.server.serve_forever,daemon=True).start()
    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.upstream.shutdown();self.upstream.server_close();self.temp.cleanup()
    def req(self,path,value=None,headers=None,raw=None):
        c=http.client.HTTPConnection('127.0.0.1',self.server.server_port);h=dict(headers or {})
        body=raw
        if value is not None:body=json.dumps(value).encode();h['Content-Type']='application/json'
        c.request('POST' if body is not None else 'GET',app.PREFIX+path,body=body,headers=h);r=c.getresponse();data=json.loads(r.read());status=r.status;c.close();return status,data
    def authorize(self):
        code=self.store.issue_pair()['pair_code'];status,device=self.req('/register',{'pair_code':code});self.assertEqual(status,200)
        status,session=self.req('/session',device);self.assertEqual(status,200)
        return {'Authorization':'Bearer '+session['access_token']},device,code
    def upload(self,headers,request_id='image-1',data=b'\xff\xd8\xffphoto'):
        body=b'--test\r\nContent-Disposition: form-data; name="file"; filename="capture.jpg"\r\nContent-Type: image/jpeg\r\n\r\n'+data+b'\r\n--test--\r\n'
        h=dict(headers);h.update({'Content-Type':'multipart/form-data; boundary=test','X-Request-ID':request_id,'X-Image-SHA256':hashlib.sha256(data).hexdigest()})
        return self.req('/predict',headers=h,raw=body)
    def test_pair_is_one_use_and_device_gets_new_sessions(self):
        headers,device,code=self.authorize();status,_=self.req('/register',{'pair_code':code});self.assertEqual(status,401)
        status,_=self.req('/session',device);self.assertEqual(status,200)
        raw=self.store.path.read_text();self.assertNotIn(device['device_key'],raw);self.assertNotIn(code,raw)
    def test_administration_code_is_seen_by_the_running_service(self):
        administrator=app.Store(self.temp.name)
        code=administrator.issue_pair()['pair_code']
        status,device=self.req('/register',{'pair_code':code});self.assertEqual(status,200)
        second_code=administrator.issue_pair()['pair_code']
        status,_=self.req('/session',device);self.assertEqual(status,200)
        status,_=self.req('/register',{'pair_code':second_code});self.assertEqual(status,200)
        self.assertEqual(len(self.store.data['devices']),2)
    def test_auth_and_revocation(self):
        status,_=self.req('/predict',raw=b'x');self.assertEqual(status,401)
        headers,device,_=self.authorize();self.store.data['devices'][device['device_id']]['revoked']=True
        status,_=self.upload(headers);self.assertEqual(status,401);self.assertEqual(len(Upstream.calls),0)
    def test_image_binding_and_idempotency_without_pc_relay(self):
        headers,device,_=self.authorize();status,first=self.upload(headers);self.assertEqual(status,200);self.assertFalse(first['is_valid'])
        self.assertEqual(first['capture_evidence']['channel'],'hololens-app');self.assertEqual(first['capture_evidence']['device_id'],device['device_id'])
        status,second=self.upload(headers);self.assertEqual(first,second);self.assertEqual(len(Upstream.calls),1)
        self.assertEqual(Upstream.calls[0][1]['X-Rice-Channel-Key'],'server-only-key-'*4)
        status,_=self.upload(headers,data=b'\xff\xd8\xffchanged');self.assertEqual(status,409);self.assertEqual(len(Upstream.calls),1)
        self.assertNotIn('server-only-key',json.dumps(first))
    def test_hash_mismatch_and_busy_are_rejected(self):
        headers,_,_=self.authorize();headers['X-Image-SHA256']='0'*64
        body=b'--x\r\nContent-Disposition: form-data; name="file"; filename="a.jpg"\r\n\r\n\xff\xd8\xffx\r\n--x--\r\n'
        headers.update({'Content-Type':'multipart/form-data; boundary=x','X-Request-ID':'a'})
        status,_=self.req('/predict',headers=headers,raw=body);self.assertEqual(status,422)
        self.store.inference.acquire()
        try:status,_=self.upload(headers);self.assertEqual(status,429)
        finally:self.store.inference.release()
    def test_device_evidence_is_private_and_strips_secrets(self):
        h,_,_=self.authorize();status,_=self.req('/events',{'event':'result_rendered','details':{'prediction_id':'abc','token':'private','version':'1.0'}},h);self.assertEqual(status,200)
        status,rows=self.req('/diagnostics',headers=h);self.assertEqual(status,200);self.assertNotIn('token',rows['events'][0]['details'])
        other,_,_=self.authorize();status,rows=self.req('/diagnostics',headers=other);self.assertEqual(rows['events'],[])
    def test_patch_preserves_legacy_and_is_idempotent(self):
        source='from pathlib import Path\nfrom fastapi import FastAPI, UploadFile, File, HTTPException\n@app.post("/predict")\nasync def predict(file: UploadFile = File(...)):\n    try:\n        result = predict_single(file)\n        _forward_to_pc_safe(file, result)\n        return result\n    except Exception:\n        raise\n'
        changed=patcher.patch(source);self.assertIn('if not _rice_hololens_channel(x_rice_channel_key):',changed);self.assertEqual(patcher.patch(changed),changed)
        self.assertIn('            _forward_to_pc_safe(file, result)',changed)
        with self.assertRaises(ValueError):patcher.patch(source.replace('_forward_to_pc_safe(file, result)','another_relay(file,result)'))

if __name__=='__main__':unittest.main()
