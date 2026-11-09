#!/bin/bash
# dsserver Phase G, axel's part: GitHub SSH key (account axelsamuelsson88) and client config.
# Run as axel, in his VS Code Remote-SSH terminal:  bash ~/phaseG-axel.sh
# Never overwrites existing files. No global Git author identity is set.
set -euo pipefail
GH_LINE='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'
GH_FPR='SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU'
K=$HOME/.ssh/github-axelsamuelsson88; C=$HOME/.ssh/config; KH=$HOME/.ssh/known_hosts
stop() { echo "STOPPED: $*"; exit 1; }
[ "$(id -un)" = axel ] || stop "run as axel"
umask 077
for f in "$K" "$K.pub" "$C"; do [ -e "$f" ] && stop "$f already exists"; done
[ "$(ssh-keygen -lf - <<<"$GH_LINE" | awk '{print $2}')" = "$GH_FPR" ] || stop "GitHub host key mismatch"
G=$(git config --global --get user.name || true); E=$(git config --global --get user.email || true)
[ -z "$G$E" ] || stop "a global Git identity already exists"
ssh-keygen -t ed25519 -a 100 -f "$K" -C "dsserver axel -> github axelsamuelsson88"
if ! { [ -e "$KH" ] && grep -qxF "$GH_LINE" "$KH"; }; then printf '%s\n' "$GH_LINE" >> "$KH"; fi
chmod 600 "$KH"
printf '%s\n' '# GitHub, account axelsamuelsson88. Passphrase-protected key.' 'Host github.com' \
  '    User git' '    IdentityFile ~/.ssh/github-axelsamuelsson88' '    IdentitiesOnly yes' > "$C"
chmod 600 "$C"
git config --global user.useConfigOnly true
if ssh-keygen -y -P '' -f "$K" >/dev/null 2>&1; then stop "key has NO passphrase"; fi
echo "key is passphrase-protected (OK)"
stat -c '%a %U %n' "$HOME/.ssh" "$K" "$K.pub" "$C" "$KH"
echo "git global config:"; git config --global --list
echo "--- axelsamuelsson88 > Settings > SSH and GPG keys > New SSH key (Authentication), title: dsserver - axel"
ssh-keygen -lf "$K.pub"; cat "$K.pub"
echo "PHASE G (axel) DONE"
