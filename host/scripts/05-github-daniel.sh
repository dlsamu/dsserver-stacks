#!/bin/bash
# dsserver Phase G, daniel's part: GitHub SSH keys and client config.
# Run as daniel, WITHOUT sudo:  bash phaseG-daniel.sh
# Creates: ~/.ssh/github-dlsamu (passphrase), ~/.ssh/github-stacks-deploy (no passphrase, decision G1),
#          ~/.ssh/config (two Host blocks), GitHub's pinned host key in ~/.ssh/known_hosts,
#          git global user.useConfigOnly=true (no global author identity).
# Never overwrites an existing file. Does not touch SSH login settings, sudo, firewall or Docker.
set -euo pipefail

GH_LINE='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'
GH_FPR='SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU'   # docs.github.com, checked 2026-11-09
PERSONAL=$HOME/.ssh/github-dlsamu
DEPLOY=$HOME/.ssh/github-stacks-deploy
CONFIG=$HOME/.ssh/config
KNOWN=$HOME/.ssh/known_hosts

stop() { echo; echo "STOPPED: $*"; exit 1; }

[ "$(id -u)" != 0 ] || stop "do not run with sudo"
[ "$(id -un)" = daniel ] || stop "run as daniel"
umask 077
[ -d "$HOME/.ssh" ] || stop "~/.ssh missing"

echo "=== 0. Pre-flight"
for f in "$PERSONAL" "$PERSONAL.pub" "$DEPLOY" "$DEPLOY.pub" "$CONFIG"; do
    [ -e "$f" ] && stop "$f already exists; not overwriting"
done
GOT=$(ssh-keygen -lf - <<<"$GH_LINE" | awk '{print $2}')
[ "$GOT" = "$GH_FPR" ] || stop "pinned GitHub host key fingerprint mismatch ($GOT)"
G=$(git config --global --get user.name || true); E=$(git config --global --get user.email || true)
[ -z "$G$E" ] || stop "a global Git identity already exists (user.name='$G' user.email='$E')"
echo "pre-flight OK"

echo; echo "=== 1. Personal key for GitHub account dlsamu (choose a passphrase)"
ssh-keygen -t ed25519 -a 100 -f "$PERSONAL" -C "dsserver daniel -> github dlsamu"

echo; echo "=== 2. Deploy key for dlsamu/dsserver-stacks (no passphrase, by decision G1)"
ssh-keygen -t ed25519 -N '' -f "$DEPLOY" -C "dsserver /srv/stacks -> dlsamu/dsserver-stacks (deploy)"

echo; echo "=== 3. Pin GitHub's host key"
if [ -e "$KNOWN" ] && grep -qxF "$GH_LINE" "$KNOWN"; then
    echo "already present in known_hosts"
else
    printf '%s\n' "$GH_LINE" >> "$KNOWN"
    echo "added to known_hosts"
fi
chmod 600 "$KNOWN"

echo; echo "=== 4. SSH client config"
cat > "$CONFIG" <<'EOF'
# GitHub, account dlsamu (personal projects). Passphrase-protected key.
Host github.com
    User git
    IdentityFile ~/.ssh/github-dlsamu
    IdentitiesOnly yes

# GitHub, deploy key for dlsamu/dsserver-stacks ONLY (/srv/stacks remote: git@github-stacks:dlsamu/dsserver-stacks.git)
Host github-stacks
    HostName github.com
    User git
    IdentityFile ~/.ssh/github-stacks-deploy
    IdentitiesOnly yes
EOF
chmod 600 "$CONFIG"
echo "written $CONFIG"

echo; echo "=== 5. Git: refuse commits without a per-repository identity"
git config --global user.useConfigOnly true

echo; echo "=== 6. Checks"
stat -c '%a %U %n' "$HOME/.ssh" "$PERSONAL" "$PERSONAL.pub" "$DEPLOY" "$DEPLOY.pub" "$CONFIG" "$KNOWN"
if ssh-keygen -y -P '' -f "$PERSONAL" >/dev/null 2>&1; then stop "personal key is NOT passphrase-protected"; fi
echo "personal key: passphrase-protected (OK)"
ssh-keygen -y -P '' -f "$DEPLOY" >/dev/null 2>&1 || stop "deploy key unexpectedly needs a passphrase"
echo "deploy key: no passphrase (as decided)"
ssh-keygen -lf "$KNOWN"
echo "git global config:"; git config --global --list
G=$(git config --global --get user.name || true); E=$(git config --global --get user.email || true)
[ -z "$G$E" ] || stop "global Git identity present"
echo "no global user.name / user.email (OK)"

echo; echo "=== Public keys to register on GitHub"
echo "--- dlsamu > Settings > SSH and GPG keys > New SSH key (Authentication), title: dsserver - daniel"
ssh-keygen -lf "$PERSONAL.pub"; cat "$PERSONAL.pub"
echo "--- dlsamu/dsserver-stacks > Settings > Deploy keys > Add deploy key, title: dsserver /srv/stacks, [x] Allow write access"
ssh-keygen -lf "$DEPLOY.pub"; cat "$DEPLOY.pub"
echo; echo "PHASE G (daniel) DONE. Register the keys on GitHub, then report back."
