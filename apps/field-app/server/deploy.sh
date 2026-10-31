#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
[[ $(id -u) -eq 0 && $# -eq 1 ]] || { echo 'Expected sudo bash deploy.sh STAGE' >&2; exit 2; }
bundle=$(readlink -f -- "$1")
[[ -f "$bundle/server.py" && -f "$bundle/patch_upstream.py" && -f "$bundle/patch_dynamic.py" && -f "$bundle/dynamic.py" && -f "$bundle/cam.py" && -f "$bundle/nginx.conf" && -f "$bundle/rice-hololens-app.service" ]] || exit 2
root=/opt/rice-hololens-app
state=/var/lib/rice-hololens-app
config=/etc/nginx/conf.d/rice-srt.conf
snippet=/etc/nginx/snippets/rice-hololens-app.conf
unit=/etc/systemd/system/rice-hololens-app.service
upstream=/opt/rice_disease/api/app_v2.py
upstream_dir=/opt/rice_disease/api
manifest=/opt/rice_disease/configs/dynamic-model.json
[[ -f "$config" && -f "$upstream" ]] || exit 2
checkpoint=/opt/rice_disease/checkpoints/convnextv2_v2_best.pth
expected_checkpoint=1ae2e8678431a4533aba61f49b085b5c72914e56e1cf78268d709be313f6dd8b
[[ "$(sha256sum "$checkpoint" | cut -d' ' -f1)" == "$expected_checkpoint" ]] || { echo 'Unexpected live checkpoint; stopped before changes' >&2; exit 2; }
current_source=$(sha256sum "$upstream" | cut -d' ' -f1)
if [[ "$current_source" != 683b040055c5686eb219d10fed4194127333d09d51ec7f10902d0bcc02a1a3b3 ]] && ! grep -qF '# Rice HoloLens application: authenticated independent result channel' "$upstream";then echo 'Unexpected live API source; stopped before changes' >&2;exit 2;fi
curl --fail --silent --max-time 10 http://127.0.0.1:8002/health >/dev/null
if [[ -n "$(ss -ltnH 'sport = :9013')" ]] && ! systemctl is-active --quiet rice-hololens-app.service; then echo '9013 is occupied by another service' >&2; exit 2; fi
python3 "$bundle/patch_upstream.py" "$upstream"
python3 "$bundle/patch_dynamic.py" "$upstream"
stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
backup="$state/backups/$stamp"
release="$root/releases/$stamp"
install -d -m 0755 "$root" "$root/releases" "$release" /etc/nginx/snippets
install -d -o admin -g admin -m 0700 "$state"
install -d -m 0700 "$state/backups" "$backup"
cp -p -- "$config" "$backup/nginx.conf"
cp -p -- "$upstream" "$backup/app_v2.py"
for name in dynamic.py cam.py;do [[ ! -f "$upstream_dir/$name" ]] || cp -p -- "$upstream_dir/$name" "$backup/upstream-$name";done
[[ ! -f "$manifest" ]] || cp -p -- "$manifest" "$backup/dynamic-model.json"
[[ ! -f "$snippet" ]] || cp -p -- "$snippet" "$backup/snippet.conf"
[[ ! -f "$unit" ]] || cp -p -- "$unit" "$backup/unit.service"
previous=$(readlink -- "$root/current" 2>/dev/null || true)
previous_active=$(systemctl is-active rice-hololens-app.service 2>/dev/null || true)
changed=0
rollback(){
 code=$?;trap - ERR
 systemctl stop rice-hololens-app.service || true
 cp -p -- "$backup/nginx.conf" "$config"
 cp -p -- "$backup/app_v2.py" "$upstream"
 for name in dynamic.py cam.py;do if [[ -f "$backup/upstream-$name" ]];then cp -p -- "$backup/upstream-$name" "$upstream_dir/$name";elif [[ -f "$upstream_dir/$name" ]];then unlink -- "$upstream_dir/$name";fi;done
 if [[ -f "$backup/dynamic-model.json" ]];then cp -p -- "$backup/dynamic-model.json" "$manifest";elif [[ -f "$manifest" ]];then unlink -- "$manifest";fi
 if [[ -f "$backup/snippet.conf" ]];then cp -p -- "$backup/snippet.conf" "$snippet";elif [[ -f "$snippet" ]];then unlink -- "$snippet";fi
 if [[ -f "$backup/unit.service" ]];then cp -p -- "$backup/unit.service" "$unit";else systemctl disable rice-hololens-app.service || true;[[ ! -f "$unit" ]] || unlink -- "$unit";fi
 if [[ -n "$previous" ]];then ln -sfn -- "$previous" "$root/current";elif [[ -L "$root/current" ]];then unlink -- "$root/current";fi
 systemctl daemon-reload
 if [[ "$changed" == 1 ]];then systemctl restart rice-disease.service || true;fi
 if [[ "$previous_active" == active ]];then systemctl restart rice-hololens-app.service || true;fi
 nginx -t && systemctl reload nginx
 echo "ROLLBACK_BACKUP=$backup" >&2
 exit "$code"
}
trap rollback ERR
if [[ ! -f "$state/upstream.key" ]];then
 python3 - "$state/upstream.key" <<'PY'
import os,secrets,sys
fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as stream:stream.write(secrets.token_urlsafe(48))
PY
 chown admin:admin "$state/upstream.key"
fi
for name in server.py patch_upstream.py patch_dynamic.py dynamic.py cam.py rice-hololens-app.service nginx.conf;do install -m 0644 "$bundle/$name" "$release/$name";done
install -m 0644 "$bundle/dynamic.py" "$upstream_dir/dynamic.py"
install -m 0644 "$bundle/cam.py" "$upstream_dir/cam.py"
python3 -m py_compile "$release/server.py" "$release/patch_upstream.py" "$release/patch_dynamic.py" "$release/dynamic.py" "$release/cam.py" "$upstream_dir/dynamic.py" "$upstream_dir/cam.py"
before=$(sha256sum "$upstream" | cut -d' ' -f1)
python3 "$release/patch_upstream.py" "$upstream" --apply
python3 "$release/patch_dynamic.py" "$upstream" --apply
python3 -m py_compile "$upstream"
after=$(sha256sum "$upstream" | cut -d' ' -f1)
manifest_before=$( [[ -f "$manifest" ]] && sha256sum "$manifest" | cut -d' ' -f1 || echo missing )
class_indices=/opt/rice_disease/configs/class_indices_v2.json
python3 - "$manifest" "$checkpoint" "$class_indices" "$upstream" "$release/dynamic-model.json" <<'PY'
import datetime,hashlib,json,os,re,shutil,sys,tempfile
manifest,checkpoint,class_indices,upstream,release=sys.argv[1:6]
def digest(path):
    h=hashlib.sha256()
    with open(path,'rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()
checkpoint_sha=digest(checkpoint)
class_sha=digest(class_indices)
classes=json.load(open(class_indices,encoding='utf-8'))
names=[classes[str(i)] for i in range(len(classes))]
source=open(upstream,encoding='utf-8').read()
match=re.search(r'^CONFIDENCE_THRESHOLD\s*=\s*([0-9.]+)\s*$',source,re.M)
threshold=float(match.group(1)) if match else 0.85
mtime=datetime.datetime.fromtimestamp(os.path.getmtime(checkpoint),datetime.timezone.utc).isoformat()
value={
 'schema':1,
 'version':'v2-'+checkpoint_sha[:12],
 'checkpoint':checkpoint,
 'checkpoint_sha256':checkpoint_sha,
 'checkpoint_bytes':os.path.getsize(checkpoint),
 'checkpoint_mtime':mtime,
 'architecture':'convnextv2_base.fcmae_ft_in1k',
 'class_indices':class_indices,
 'class_indices_sha256':class_sha,
 'classes':names,
 'threshold':threshold,
 'input_sizes':[128,160,192,224],
 'default_size':160,
 'cam':True,
 'frames_stored':False,
 'deployed_by':'apps/field-app/server/deploy.sh',
}
data=json.dumps(value,ensure_ascii=False,indent=2,sort_keys=True)+'\n'
folder=os.path.dirname(manifest);os.makedirs(folder,exist_ok=True)
fd,temp=tempfile.mkstemp(prefix='.dynamic-model.',dir=folder)
try:
    with os.fdopen(fd,'w',encoding='utf-8') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
    os.chmod(temp,0o644);os.replace(temp,manifest)
finally:
    if os.path.exists(temp):os.unlink(temp)
with open(release,'w',encoding='utf-8') as stream:stream.write(data)
print('DYNAMIC_MODEL='+value['version']+' '+checkpoint_sha)
PY
manifest_after=$(sha256sum "$manifest" | cut -d' ' -f1)
if [[ "$before" != "$after" || "$manifest_before" != "$manifest_after" ]];then
 changed=1
 systemctl restart rice-disease.service
 for attempt in {1..40};do if curl --fail --silent --max-time 2 http://127.0.0.1:8002/health >/dev/null;then break;fi;sleep 0.5;done
 curl --fail --silent --max-time 10 http://127.0.0.1:8002/health >/dev/null
 curl --fail --silent --max-time 10 http://127.0.0.1:8002/dynamic/health >/dev/null
fi
ln -sfn -- "$release" "$root/current"
install -m 0644 "$release/nginx.conf" "$snippet"
install -m 0644 "$release/rice-hololens-app.service" "$unit"
python3 - "$config" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text();line='    include /etc/nginx/snippets/rice-hololens-app.conf;\n'
if line not in s:
 needle='    listen 443 ssl default_server;'
 if s.count(needle)!=1:raise SystemExit('Unexpected TLS server layout')
 s=s.replace(needle,line+needle,1);p.write_text(s)
PY
systemctl daemon-reload
systemctl enable rice-hololens-app.service
systemctl restart rice-hololens-app.service
for attempt in {1..20};do if curl --fail --silent --max-time 2 http://127.0.0.1:9013/hololens-app/api/health >/dev/null;then break;fi;sleep 0.5;done
curl --fail --silent --max-time 5 http://127.0.0.1:9013/hololens-app/api/health
nginx -t
systemctl reload nginx
for attempt in {1..20};do if curl --fail --silent --max-time 3 https://rice-srt.cn/hololens-app/api/health;then break;fi;sleep 0.5;done
curl --fail --silent --max-time 10 https://rice-srt.cn/hololens-app/api/health
curl --fail --silent --max-time 10 https://rice-srt.cn/hololens-app/api/dynamic/health >/dev/null
curl --fail --silent --max-time 10 https://rice-srt.cn/health >/dev/null
curl --fail --silent --max-time 10 https://rice-srt.cn/hololens/api/health >/dev/null
[[ "$(sha256sum "$checkpoint" | cut -d' ' -f1)" == "$expected_checkpoint" ]]
trap - ERR
printf '\nDEPLOYED_RELEASE=%s\nROLLBACK_BACKUP=%s\nUPSTREAM_SOURCE_SHA256=%s\n' "$release" "$backup" "$after"
