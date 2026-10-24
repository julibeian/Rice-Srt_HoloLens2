#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
[[ $(id -u) -eq 0 && $# -eq 1 ]] || { echo 'Expected sudo bash deploy.sh STAGE' >&2; exit 2; }
bundle=$(readlink -f -- "$1")
[[ -f "$bundle/server.py" && -f "$bundle/patch_upstream.py" && -f "$bundle/nginx.conf" && -f "$bundle/rice-hololens-app.service" ]] || exit 2
root=/opt/rice-hololens-app
state=/var/lib/rice-hololens-app
config=/etc/nginx/conf.d/rice-srt.conf
snippet=/etc/nginx/snippets/rice-hololens-app.conf
unit=/etc/systemd/system/rice-hololens-app.service
upstream=/opt/rice_disease/api/app_v2.py
[[ -f "$config" && -f "$upstream" ]] || exit 2
checkpoint=/opt/rice_disease/checkpoints/convnextv2_v2_best.pth
expected_checkpoint=1ae2e8678431a4533aba61f49b085b5c72914e56e1cf78268d709be313f6dd8b
[[ "$(sha256sum "$checkpoint" | cut -d' ' -f1)" == "$expected_checkpoint" ]] || { echo 'Unexpected live checkpoint; stopped before changes' >&2; exit 2; }
current_source=$(sha256sum "$upstream" | cut -d' ' -f1)
if [[ "$current_source" != 683b040055c5686eb219d10fed4194127333d09d51ec7f10902d0bcc02a1a3b3 ]] && ! grep -qF '# Rice HoloLens application: authenticated independent result channel' "$upstream";then echo 'Unexpected live API source; stopped before changes' >&2;exit 2;fi
curl --fail --silent --max-time 10 http://127.0.0.1:8002/health >/dev/null
if [[ -n "$(ss -ltnH 'sport = :9013')" ]] && ! systemctl is-active --quiet rice-hololens-app.service; then echo '9013 is occupied by another service' >&2; exit 2; fi
python3 "$bundle/patch_upstream.py" "$upstream"
stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
backup="$state/backups/$stamp"
release="$root/releases/$stamp"
install -d -m 0755 "$root" "$root/releases" "$release" /etc/nginx/snippets
install -d -o admin -g admin -m 0700 "$state"
install -d -m 0700 "$state/backups" "$backup"
cp -p -- "$config" "$backup/nginx.conf"
cp -p -- "$upstream" "$backup/app_v2.py"
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
for name in server.py patch_upstream.py rice-hololens-app.service nginx.conf;do install -m 0644 "$bundle/$name" "$release/$name";done
python3 -m py_compile "$release/server.py" "$release/patch_upstream.py"
before=$(sha256sum "$upstream" | cut -d' ' -f1)
python3 "$release/patch_upstream.py" "$upstream" --apply
python3 -m py_compile "$upstream"
after=$(sha256sum "$upstream" | cut -d' ' -f1)
if [[ "$before" != "$after" ]];then
 changed=1
 systemctl restart rice-disease.service
 for attempt in {1..40};do if curl --fail --silent --max-time 2 http://127.0.0.1:8002/health >/dev/null;then break;fi;sleep 0.5;done
 curl --fail --silent --max-time 10 http://127.0.0.1:8002/health >/dev/null
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
curl --fail --silent --max-time 10 https://rice-srt.cn/health >/dev/null
curl --fail --silent --max-time 10 https://rice-srt.cn/hololens/api/health >/dev/null
[[ "$(sha256sum "$checkpoint" | cut -d' ' -f1)" == "$expected_checkpoint" ]]
trap - ERR
printf '\nDEPLOYED_RELEASE=%s\nROLLBACK_BACKUP=%s\nUPSTREAM_SOURCE_SHA256=%s\n' "$release" "$backup" "$after"
