#!/usr/bin/env bash
# Execute explicitly as root after reviewing this script and the staged bundle.
# Only /hololens/, its new service and its state are added. Existing model stays running.
set -Eeuo pipefail
umask 027

[[ $(id -u) -eq 0 ]] || { echo 'Run with sudo bash deploy.sh STAGED_BUNDLE' >&2; exit 2; }
[[ $# -eq 1 ]] || { echo 'Expected the staged apps/capture-app directory' >&2; exit 2; }
bundle=$(readlink -f -- "$1")
[[ -d "$bundle/server" && -d "$bundle/web" ]] || { echo 'Invalid bundle layout' >&2; exit 2; }
for file in server.py hololens-capture.service hololens-nginx.conf patch_nginx.py; do
    [[ -f "$bundle/server/$file" ]] || { echo "Missing server/$file" >&2; exit 2; }
done
for file in index.html styles.css app.bundle.js; do
    [[ -f "$bundle/web/$file" ]] || { echo "Missing web/$file" >&2; exit 2; }
done

app_root=/opt/hololens-capture
state_root=/var/lib/hololens-capture
nginx_config=/etc/nginx/conf.d/rice-srt.conf
snippet=/etc/nginx/snippets/hololens-capture.conf
unit_file=/etc/systemd/system/hololens-capture.service
unit_name=hololens-capture.service
[[ -f "$nginx_config" ]] || { echo 'The verified Nginx config is absent' >&2; exit 2; }
if [[ -e "$app_root/current" && ! -L "$app_root/current" ]]; then
    echo 'Refusing to replace an existing non-symlink current directory' >&2
    exit 2
fi
if [[ -n "$(ss -ltnH 'sport = :9012')" ]] && ! systemctl is-active --quiet "$unit_name"; then
    echo 'Port 9012 belongs to another process; refusing to replace it' >&2
    exit 2
fi
python3 "$bundle/server/patch_nginx.py" --config "$nginx_config"
curl --fail --silent --show-error --max-time 10 http://127.0.0.1:8002/health >/dev/null

stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
backup="$state_root/deploy-backups/$stamp"
release="$app_root/releases/$stamp"
case "$release" in /opt/hololens-capture/releases/*) ;; *) exit 2 ;; esac
install -d -m 0755 "$app_root" "$app_root/releases"
install -d -o admin -g admin -m 0700 "$state_root" "$state_root/evidence"
install -d -m 0700 "$state_root/deploy-backups" "$backup"
cp -p -- "$nginx_config" "$backup/nginx.conf"
old_link=$(readlink -- "$app_root/current" 2>/dev/null || true)
old_active=$(systemctl is-active "$unit_name" 2>/dev/null || true)
old_enabled=$(systemctl is-enabled "$unit_name" 2>/dev/null || true)
[[ ! -f "$snippet" ]] || cp -p -- "$snippet" "$backup/snippet.conf"
[[ ! -f "$unit_file" ]] || cp -p -- "$unit_file" "$backup/unit.service"
printf '%s\n' "$old_link" >"$backup/previous-current"
printf '%s\n' "$old_active" >"$backup/previous-active"
printf '%s\n' "$old_enabled" >"$backup/previous-enabled"

rollback() {
    local code=$?
    trap - ERR
    echo "Deployment failed; restoring Nginx and gateway configuration from $backup" >&2
    systemctl stop "$unit_name" || true
    cp -p -- "$backup/nginx.conf" "$nginx_config"
    if [[ -f "$backup/snippet.conf" ]]; then
        cp -p -- "$backup/snippet.conf" "$snippet"
    elif [[ -f "$snippet" ]]; then
        unlink -- "$snippet"
    fi
    if [[ -n "$old_link" ]]; then
        ln -sfn -- "$old_link" "$app_root/current"
    elif [[ -L "$app_root/current" ]]; then
        unlink -- "$app_root/current"
    fi
    if [[ -f "$backup/unit.service" ]]; then
        cp -p -- "$backup/unit.service" "$unit_file"
    else
        systemctl disable --now "$unit_name" || true
        [[ ! -f "$unit_file" ]] || unlink -- "$unit_file"
    fi
    systemctl daemon-reload
    if [[ "$old_active" == active ]]; then systemctl restart "$unit_name" || true; fi
    if [[ "$old_enabled" == enabled ]]; then
        systemctl enable "$unit_name" || true
    else
        systemctl disable "$unit_name" || true
    fi
    nginx -t && systemctl reload nginx
    exit "$code"
}
trap rollback ERR

install -d -m 0755 "$release" "$release/server" "$release/web"
for file in server.py hololens-capture.service hololens-nginx.conf patch_nginx.py; do
    install -m 0644 "$bundle/server/$file" "$release/server/$file"
done
for file in index.html styles.css app.bundle.js; do
    install -m 0644 "$bundle/web/$file" "$release/web/$file"
done
python3 -m py_compile "$release/server/server.py" "$release/server/patch_nginx.py"
python3 "$release/server/server.py" issue-session --session-file "$state_root/session.json"
chown admin:admin "$state_root/session.json"
chmod 0600 "$state_root/session.json"
ln -sfn -- "$release" "$app_root/current"
install -d -m 0755 /etc/nginx/snippets
install -m 0644 "$release/server/hololens-nginx.conf" "$snippet"
install -m 0644 "$release/server/hololens-capture.service" "$unit_file"
python3 "$release/server/patch_nginx.py" --config "$nginx_config" --apply
systemctl daemon-reload
systemctl enable "$unit_name"
systemctl restart "$unit_name"
for attempt in {1..20}; do
    if curl --fail --silent --max-time 2 http://127.0.0.1:9012/hololens/api/health >/dev/null; then break; fi
    sleep 0.5
done
curl --fail --silent --show-error --max-time 3 http://127.0.0.1:9012/hololens/api/health
nginx -t
systemctl reload nginx
# A successful reload returns before the new workers necessarily accept requests.
# Probe the new route with fresh requests instead of treating the old worker's
# transient 404 as a failed deployment and rolling back a healthy new service.
for attempt in {1..20}; do
    if curl --fail --silent --max-time 3 https://rice-srt.cn/hololens/api/health; then break; fi
    sleep 0.5
done
curl --fail --silent --show-error --max-time 10 https://rice-srt.cn/hololens/api/health
curl --fail --silent --show-error --max-time 10 https://rice-srt.cn/health >/dev/null
trap - ERR
printf '\nDEPLOYED_RELEASE=%s\nROLLBACK_BACKUP=%s\n' "$release" "$backup"
echo 'No existing model service, checkpoint, relay or port 8003 was changed.'
echo 'Fetch the task session link explicitly with server.py session-info --launch-url.'
