#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
[[ $(id -u) -eq 0 && $# -eq 1 ]] || { echo 'Expected sudo bash deploy.sh STAGE' >&2; exit 2; }
bundle=$(readlink -f -- "$1")
[[ -f "$bundle/server.py" && -f "$bundle/retire_dynamic.py" ]] || exit 2
# The headset now performs YOLO locally. This deployment only retires the old
# dynamic classifier mount; it does not install an inference or image relay path.
python3 "$bundle/retire_dynamic.py" "$bundle"
