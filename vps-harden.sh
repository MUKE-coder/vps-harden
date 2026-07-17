#!/usr/bin/env bash
#
# vps-harden.sh
# ----------------------------------------------------------------------------
# Update, harden, audit and (optionally) install Dokploy on a fresh
# Ubuntu / Debian VPS (tested on Ubuntu 22.04 / 24.04).
#
# What it does, in order:
#   1.  Pre-flight checks (root, OS, internet)
#   2.  Full system update + automatic security updates
#   3.  Create a non-root sudo user with your SSH key
#   4.  Harden SSH (no root login, no passwords, custom port)
#   5.  Firewall (UFW) + Dokploy-aware Docker firewall rules
#   6.  Fail2ban (brute-force protection)
#   7.  Kernel / sysctl network hardening
#   8.  Shared-memory, core-dump and misc hardening
#   9.  Optional: install Dokploy
#   10. Security audit with a 0-100 score + report file
#
# Usage:
#   chmod +x vps-harden.sh
#   sudo ./vps-harden.sh                 # interactive
#   sudo ./vps-harden.sh --audit-only    # just score, change nothing
#   sudo ./vps-harden.sh --no-dokploy    # harden but skip Dokploy
#   sudo ./vps-harden.sh --yes           # non-interactive (uses env vars / defaults)
#   sudo ./vps-harden.sh --auto-port     # move SSH to a random free high port
#
# Configure with environment variables (or answer the prompts):
#   NEW_USER=deploy
#   SSH_PORT=2222                 (or "auto" to pick a free high port)
#   SSH_PUBKEY="ssh-ed25519 AAAA... you@host"
#   INSTALL_DOKPLOY=yes|no
#   DOCKER_PUBLIC_PORTS="80 443"  published container ports to keep reachable
#                                 once ufw-docker starts filtering them
#
# License: MIT. No warranty. Read it before you run it.
# ----------------------------------------------------------------------------

set -euo pipefail

# ----------------------------------------------------------------------------
# Colours & logging
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'
  BLU=$'\033[0;34m'; BLD=$'\033[1m';   NC=$'\033[0m'
else
  RED=''; GRN=''; YLW=''; BLU=''; BLD=''; NC=''
fi

log()   { echo "${BLU}[*]${NC} $*"; }
ok()    { echo "${GRN}[+]${NC} $*"; }
warn()  { echo "${YLW}[!]${NC} $*"; }
err()   { echo "${RED}[x]${NC} $*" >&2; }
hr()    { echo "${BLD}------------------------------------------------------------${NC}"; }

# ----------------------------------------------------------------------------
# Globals
# ----------------------------------------------------------------------------
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="/root/vps-harden-report-${TIMESTAMP}.txt"
AUDIT_ONLY="no"
ASSUME_YES="no"
SCORE=0
MAX_SCORE=0

# Defaults (overridable by env or prompt)
NEW_USER="${NEW_USER:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
INSTALL_DOKPLOY="${INSTALL_DOKPLOY:-}"
GENERATED_KEY_FILE=""

# Container ports that should stay reachable from the internet once ufw-docker
# starts filtering. 80/443 by default: this box is meant to serve web traffic,
# and blocking those would break the very thing you are deploying. Anything else
# (a dashboard on 8080, a database, ...) must be opted in.
#
# These are CONTAINER ports, not published host ports. The rule is matched after
# Docker's DNAT, so `ufw route allow ... port 80` lets through ANY container
# serving on 80 no matter which host port it is published on. Verified on a real
# box: redis published as -p 6379:6379 was refused from the internet, while
# Traefik on 80/443 and Orbita on 8080 kept working.
DOCKER_PUBLIC_PORTS="${DOCKER_PUBLIC_PORTS:-80 443}"

# ----------------------------------------------------------------------------
# Arg parsing
# ----------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --audit-only) AUDIT_ONLY="yes" ;;
    --no-dokploy) INSTALL_DOKPLOY="no" ;;
    --auto-port)  SSH_PORT="auto" ;;
    --yes|-y)     ASSUME_YES="yes" ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^#\s\?//' | head -n 40
      exit 0 ;;
    *) err "Unknown option: $arg"; exit 1 ;;
  esac
done

# ----------------------------------------------------------------------------
# Audit helpers
# ----------------------------------------------------------------------------
# Read one effective value out of `sshd -T`, e.g. sshd_effective permitrootlogin
#
# Do NOT write this as `x="$(sshd -T | awk '/^port /{print $2; exit}')"`. awk's
# `exit` closes the pipe, sshd -T is killed by SIGPIPE, `set -o pipefail` makes
# the pipeline non-zero, and `set -e` then kills the script on what looks like a
# harmless assignment. That is exactly what used to abort the audit silently,
# right after the password-auth check and before it could print a score. The
# checks above it survived only because `if <cmd>` suppresses set -e.
sshd_effective() {
  local key="$1" out
  out="$(sshd -T 2>/dev/null || true)"
  awk -v k="$key" '$1 == k { v = $2 } END { if (v != "") print v }' <<<"$out"
}

# Pick a random unused high port for SSH (SSH_PORT=auto).
#
# Deliberately not the default: moving SSH is only safe if you can still reach
# the new port. Some providers filter non-standard ports at their own edge, and
# a box you cannot log into is worse than one on port 22. Opt in with
# SSH_PORT=auto or --auto-port.
pick_free_port() {
  local p listening
  listening="$(ss -ltnH 2>/dev/null || true)"
  for _ in $(seq 1 50); do
    p=$(( (RANDOM % 40000) + 20000 ))
    case "$listening" in
      *":$p "*) continue ;;
      *) printf '%s' "$p"; return 0 ;;
    esac
  done
  printf '22'   # gave up; caller keeps the default rather than guessing
}

# Allow a PUBLISHED CONTAINER port through UFW.
#
# Once ufw-docker is installed, `ufw allow <port>` is not enough: Docker's
# traffic is forwarded, not INPUT, so it needs a `ufw route` rule. Verified on a
# real box — with ufw-docker installed, `ufw allow 8080/tcp` left the port dead
# (HTTP 000) while `ufw route allow ... port 8080` brought it back (HTTP 200).
allow_docker_port() {
  local port="$1"
  ufw route allow proto tcp from any to any port "$port" >/dev/null 2>&1 || true
}

audit() {
  # audit "<weight>" "<name>" "pass|warn|fail" "<message>"
  local weight="$1" name="$2" status="$3" msg="$4" color tag
  MAX_SCORE=$(( MAX_SCORE + weight ))
  case "$status" in
    pass) SCORE=$(( SCORE + weight ));   color="$GRN"; tag="PASS" ;;
    warn) SCORE=$(( SCORE + weight/2 )); color="$YLW"; tag="WARN" ;;
    fail)                                color="$RED"; tag="FAIL" ;;
  esac
  printf '%s[%s]%s %s%-22s%s %s\n' "$color" "$tag" "$NC" "$BLD" "$name" "$NC" "$msg"
  printf '[%-4s] %-22s %s\n' "$tag" "$name" "$msg" >> "$REPORT"
}

confirm() {
  # confirm "question" -> returns 0 for yes
  [[ "$ASSUME_YES" == "yes" ]] && return 0
  local reply
  read -r -p "${YLW}[?]${NC} $1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

ask() {
  # ask "prompt" "default" -> echoes answer
  local prompt="$1" default="$2" reply
  if [[ "$ASSUME_YES" == "yes" ]]; then echo "$default"; return; fi
  read -r -p "${BLU}[?]${NC} $prompt [$default]: " reply
  echo "${reply:-$default}"
}

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
preflight() {
  hr; log "Pre-flight checks"
  if [[ "$EUID" -ne 0 ]]; then err "Run as root (use sudo)."; exit 1; fi

  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    case "$ID" in
      ubuntu|debian) ok "Detected $PRETTY_NAME" ;;
      *) warn "OS '$ID' is untested. This script targets Ubuntu/Debian." ;;
    esac
  else
    warn "Cannot detect OS (no /etc/os-release)."
  fi

  if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then ok "Internet reachable"
  else err "No internet connectivity."; exit 1; fi

  echo "VPS Harden Report - $TIMESTAMP" > "$REPORT"
  echo "Host: $(hostname)  |  $PRETTY_NAME" >> "$REPORT"
  hr >> "$REPORT" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# 1. System update
# ----------------------------------------------------------------------------
do_update() {
  hr; log "Updating system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
  apt-get dist-upgrade -y
  apt-get install -y \
    ufw fail2ban unattended-upgrades apt-listchanges \
    curl wget ca-certificates gnupg lsb-release \
    net-tools auditd >/dev/null 2>&1 || \
    apt-get install -y ufw fail2ban unattended-upgrades curl wget
  ok "Packages updated and base tooling installed"

  log "Enabling unattended security upgrades"
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  ok "Automatic security updates enabled"
}

# ----------------------------------------------------------------------------
# 2. Non-root sudo user + SSH key
# ----------------------------------------------------------------------------
do_user() {
  hr; log "Setting up a non-root sudo user"

  [[ -z "$NEW_USER" ]] && NEW_USER="$(ask 'Username for new sudo user (blank to skip)' '')"
  if [[ -z "$NEW_USER" ]]; then warn "Skipping user creation."; return; fi

  if id "$NEW_USER" >/dev/null 2>&1; then
    ok "User '$NEW_USER' already exists"
  else
    adduser --disabled-password --gecos "" "$NEW_USER"
    ok "Created user '$NEW_USER'"
  fi
  usermod -aG sudo "$NEW_USER"

  # Being in the sudo group is not enough to be able to USE sudo.
  #
  # The account is created with --disabled-password, so it has no password to
  # type at sudo's prompt — every attempt fails with "sudo: a password is
  # required". do_ssh() then sets PermitRootLogin no. The combination leaves a
  # box with no route to root at all: sudo rejects you, and `su` wants a root
  # password that a key-only VPS (Hetzner, DigitalOcean, ...) never had. The
  # only way back in is the provider's rescue console.
  #
  # Ubuntu's own cloud images grant their default user exactly this rule, in
  # /etc/sudoers.d/90-cloud-init-users, for precisely this reason.
  local sudoers="/etc/sudoers.d/90-${NEW_USER}"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$NEW_USER" >"$sudoers"
  chmod 440 "$sudoers"
  if visudo -cf "$sudoers" >/dev/null 2>&1; then
    ok "Granted '$NEW_USER' passwordless sudo"
  else
    rm -f "$sudoers"
    err "sudoers rule failed its syntax check - not installed."
    err "Do NOT close this session: '$NEW_USER' cannot reach root yet."
  fi

  if [[ -z "$SSH_PUBKEY" ]]; then
    echo
    warn "No SSH key was provided."
    echo "An SSH key is what lets you log in securely without a password."
    echo "You have two options:"
    echo "  ${BLD}A)${NC} You already made a key on your laptop - paste the PUBLIC key now."
    echo "     (On your laptop it's shown by: cat ~/.ssh/id_ed25519.pub)"
    echo "  ${BLD}B)${NC} You have no key yet - let this script make one FOR you."
    echo
    SSH_PUBKEY="$(ask 'Paste your public key, or leave BLANK to have one generated for you' '')"
  fi

  # Option B: no key pasted -> generate a fresh pair on the server.
  if [[ -z "$SSH_PUBKEY" ]]; then
    log "Generating a new SSH key pair for you..."
    local keydir="/root/vps-harden-keys"
    local keyfile="$keydir/${NEW_USER}_key"
    install -d -m 700 "$keydir"
    if [[ ! -f "$keyfile" ]]; then
      ssh-keygen -t ed25519 -N "" -C "${NEW_USER}@$(hostname)" -f "$keyfile" >/dev/null
    fi
    SSH_PUBKEY="$(cat "${keyfile}.pub")"
    GENERATED_KEY_FILE="$keyfile"
    ok "Created a key pair for you."
    echo
    echo "${BLD}>>> ACTION REQUIRED: save your PRIVATE key to your laptop <<<${NC}"
    echo "This secret key is your ONLY way to log in after this. Copy it now."
    echo
    echo "${BLD}Easiest way:${NC} on your LAPTOP, open a new terminal and run this single line"
    echo "(replace the IP with your server's IP). It copies the key down for you:"
    echo
    echo "    ${BLD}scp root@<server-ip>:${keyfile} ~/.ssh/${NEW_USER}_key${NC}"
    echo
    echo "Then fix its permissions on your laptop so SSH will accept it:"
    echo "    ${BLD}chmod 600 ~/.ssh/${NEW_USER}_key${NC}"
    echo
    echo "After that you'll log in from your laptop with:"
    echo "    ${BLD}ssh -i ~/.ssh/${NEW_USER}_key -p <ssh-port> ${NEW_USER}@<server-ip>${NC}"
    echo
    warn "Do this BEFORE you close your current connection. The script will remind you again at the end."
    echo
    if [[ "$ASSUME_YES" != "yes" ]]; then
      read -r -p "${YLW}[?]${NC} Press Enter once you understand (you'll copy the key shortly)... " _
    fi
  fi

  if [[ -n "$SSH_PUBKEY" ]]; then
    local home; home="$(eval echo "~$NEW_USER")"
    install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$home/.ssh"
    echo "$SSH_PUBKEY" >> "$home/.ssh/authorized_keys"
    sort -u "$home/.ssh/authorized_keys" -o "$home/.ssh/authorized_keys"
    chmod 600 "$home/.ssh/authorized_keys"
    chown "$NEW_USER:$NEW_USER" "$home/.ssh/authorized_keys"
    ok "Installed SSH key for '$NEW_USER'"
  else
    warn "No key installed. Password auth will stay ON to avoid locking you out."
  fi
}

# ----------------------------------------------------------------------------
# 3. SSH hardening
# ----------------------------------------------------------------------------
do_ssh() {
  hr; log "Hardening SSH"

  [[ "$SSH_PORT" == "22" ]] && SSH_PORT="$(ask 'SSH port to use (non-default recommended, or "auto")' '22')"

  # SSH_PORT=auto / --auto-port: let the script choose a free high port.
  if [[ "$SSH_PORT" == "auto" ]]; then
    SSH_PORT="$(pick_free_port)"
    if [[ "$SSH_PORT" == "22" ]]; then
      warn "Could not find a free high port; staying on 22."
    else
      ok "Chose SSH port $SSH_PORT"
      warn "WRITE THIS DOWN. From now on you must connect with: ssh -p $SSH_PORT ${NEW_USER:-<user>}@<server-ip>"
      warn "If your provider filters non-standard ports at their edge, open $SSH_PORT there too."
    fi
  fi

  if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    err "Invalid SSH port '$SSH_PORT' - staying on 22."
    SSH_PORT=22
  fi

  local can_disable_pw="yes"
  local home; home="$(eval echo "~${NEW_USER:-root}")"
  if [[ -z "$SSH_PUBKEY" && ! -s "$home/.ssh/authorized_keys" && ! -s /root/.ssh/authorized_keys ]]; then
    can_disable_pw="no"
    warn "No SSH key detected anywhere - keeping password auth ON to avoid lockout."
  fi

  install -d -m 755 /etc/ssh/sshd_config.d

  # The file name is load-bearing. sshd_config takes the FIRST occurrence of a
  # keyword, and `Include /etc/ssh/sshd_config.d/*.conf` sits at the top of the
  # main config and pulls files in ALPHABETICAL order. Ubuntu cloud images ship
  #
  #     50-cloud-init.conf:  PasswordAuthentication yes
  #
  # so a file named 99-* is read last and silently loses every conflict. This
  # script used to write 99-hardening.conf and then report "password auth
  # disabled" while `sshd -T` still said `passwordauthentication yes`. 00-
  # sorts first, so our settings actually win — including after cloud-init
  # regenerates its own file on a later boot.
  local conf=/etc/ssh/sshd_config.d/00-hardening.conf
  rm -f /etc/ssh/sshd_config.d/99-hardening.conf   # written by older versions

  # Belt and braces: neutralise conflicting directives the image left behind so
  # that `sshd -T` and a human reading the directory tell the same story.
  local other
  for other in /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$other" && "$other" != "$conf" ]] || continue
    if grep -qE '^[[:space:]]*(PasswordAuthentication|PermitRootLogin)\b' "$other"; then
      [[ -f "$other.vps-harden.bak" ]] || cp -p "$other" "$other.vps-harden.bak"
      sed -ri 's/^([[:space:]]*)(PasswordAuthentication|PermitRootLogin)\b/#\1\2/' "$other"
      ok "Neutralised conflicting directives in $(basename "$other") (backup kept)"
    fi
  done

  cat >"$conf" <<EOF
# Managed by vps-harden.sh ($TIMESTAMP)
# Named 00- on purpose: sshd uses the FIRST value it sees for a keyword, and
# this directory is Included alphabetically. Do not rename this to 99-.
Port ${SSH_PORT}
Protocol 2
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication $([[ "$can_disable_pw" == "yes" ]] && echo no || echo yes)
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitEmptyPasswords no
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

  if sshd -t 2>/dev/null; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

    # Report what sshd ACTUALLY ended up doing, not what we asked for. The old
    # message printed our intent, which is how the 99-* precedence bug above
    # survived: it cheerfully said "password auth disabled" on a box that had
    # it enabled.
    local eff_pw eff_root eff_port
    eff_pw="$(sshd_effective passwordauthentication)"
    eff_root="$(sshd_effective permitrootlogin)"
    eff_port="$(sshd_effective port)"
    ok "SSH hardened (port ${eff_port:-$SSH_PORT}, root login ${eff_root:-unknown}, password auth ${eff_pw:-unknown})"

    if [[ "$can_disable_pw" == "yes" && "$eff_pw" == "yes" ]]; then
      err "Asked sshd to disable password auth, but it is still enabled."
      err "Something in /etc/ssh/sshd_config.d/ or sshd_config overrides us; check: sshd -T | grep -i password"
    fi

    warn "Keep this window open. From your LAPTOP, test a NEW login before closing it:"
    echo "    ssh -p ${eff_port:-$SSH_PORT} ${NEW_USER:-<user>}@<server-ip>"
  else
    err "sshd config test failed - reverting."
    rm -f "$conf"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  fi
}

# ----------------------------------------------------------------------------
# 4. Firewall (UFW) - Dokploy / Docker aware
# ----------------------------------------------------------------------------
do_firewall() {
  hr; log "Configuring UFW firewall"

  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp" comment 'SSH'

  if [[ "${INSTALL_DOKPLOY}" == "yes" ]]; then
    ufw allow 80/tcp   comment 'HTTP (Traefik)'
    ufw allow 443/tcp  comment 'HTTPS (Traefik)'
    ufw allow 443/udp  comment 'HTTP/3 (Traefik)'
    # Traefik runs in a container, so these also need route rules below.
    DOCKER_PUBLIC_PORTS="$DOCKER_PUBLIC_PORTS 80 443"
    warn "Dokploy panel runs on port 3000. Leave it CLOSED in UFW and reach it from your LAPTOP via SSH tunnel:"
    echo "    ssh -p ${SSH_PORT} ${NEW_USER:-root}@<server-ip> -L 3000:localhost:3000"
    echo "    then open http://localhost:3000 in your laptop's browser"
  fi

  ufw --force enable
  ok "UFW enabled"

  # --- Docker bypasses UFW. Fix it. ---
  #
  # Docker writes its own iptables rules ahead of UFW's, so ANY published
  # container port is world-reachable no matter what UFW says. Measured on a
  # real box: UFW allowed port 22 only, and http://<ip>:8080 still answered 200.
  # ufw-docker closes that gap.
  #
  # This used to be gated on `command -v docker`, which meant it almost never
  # ran: you harden a fresh VPS first and install Docker afterwards, so at this
  # point Docker isn't there yet and the fix was skipped forever. ufw-docker
  # only edits /etc/ufw/after.rules, so installing it before Docker exists is
  # fine — the rules simply take effect once Docker shows up.
  log "Applying Docker<->UFW fix (ufw-docker)"
  if [[ ! -x /usr/local/bin/ufw-docker ]]; then
    if curl -fsSL -o /usr/local/bin/ufw-docker \
         https://raw.githubusercontent.com/chaifeng/ufw-docker/master/ufw-docker 2>/dev/null; then
      chmod +x /usr/local/bin/ufw-docker
    else
      warn "Could not fetch ufw-docker; published container ports will bypass UFW."
    fi
  fi

  if [[ -x /usr/local/bin/ufw-docker ]]; then
    /usr/local/bin/ufw-docker install >/dev/null 2>&1 || true
    systemctl restart ufw 2>/dev/null || true

    # ufw-docker blocks EVERY published port by default, and `ufw allow <port>`
    # does not undo that — container traffic is forwarded, not INPUT, so it
    # needs a `ufw route` rule. Without this a hardened box silently black-holes
    # its own web server: verified on a real box, Traefik's port went from 200
    # to unreachable the moment ufw-docker was installed.
    local p
    for p in $DOCKER_PUBLIC_PORTS; do
      allow_docker_port "$p"
    done
    ufw reload >/dev/null 2>&1 || true

    ok "Docker traffic now respects UFW"
    ok "Container ports reachable from the internet: ${DOCKER_PUBLIC_PORTS:-none}"
    warn "Any OTHER container port is now refused from the internet (databases included)."
    warn "These are container ports, not published host ports. To open one:"
    echo "    sudo ufw route allow proto tcp from any to any port <CONTAINER_PORT>"
  fi
}

# ----------------------------------------------------------------------------
# 5. Fail2ban
# ----------------------------------------------------------------------------
do_fail2ban() {
  hr; log "Configuring Fail2ban"
  cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 3
bantime  = 24h
EOF
  systemctl enable --now fail2ban >/dev/null 2>&1 || systemctl restart fail2ban
  ok "Fail2ban active (SSH jail, ban after 3 fails)"
}

# ----------------------------------------------------------------------------
# 6. Kernel / sysctl hardening
# ----------------------------------------------------------------------------
do_sysctl() {
  hr; log "Applying kernel network hardening"
  cat >/etc/sysctl.d/99-vps-harden.conf <<'EOF'
# Spoof protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# Ignore ICMP redirects / source routing
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
# SYN flood protection
net.ipv4.tcp_syncookies = 1
# Log martians
net.ipv4.conf.all.log_martians = 1
# Ignore broadcast pings
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# ASLR
kernel.randomize_va_space = 2
EOF
  sysctl --system >/dev/null 2>&1 || true
  ok "sysctl hardening applied"
}

# ----------------------------------------------------------------------------
# 7. Misc hardening
# ----------------------------------------------------------------------------
do_misc() {
  hr; log "Misc hardening (shared memory, core dumps)"
  if ! grep -q '/run/shm' /etc/fstab 2>/dev/null; then
    echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0" >> /etc/fstab
  fi
  cat >/etc/security/limits.d/99-no-core.conf <<'EOF'
* hard core 0
EOF
  echo "kernel.core_pattern=/dev/null" >/etc/sysctl.d/99-no-coredump.conf
  sysctl -p /etc/sysctl.d/99-no-coredump.conf >/dev/null 2>&1 || true
  ok "Core dumps disabled, /run/shm mounted noexec on next boot"
}

# ----------------------------------------------------------------------------
# 8. Optional Dokploy install
# ----------------------------------------------------------------------------
do_dokploy() {
  hr; log "Dokploy installation"
  if [[ -z "$INSTALL_DOKPLOY" ]]; then
    if confirm "Install Dokploy now?"; then INSTALL_DOKPLOY="yes"; else INSTALL_DOKPLOY="no"; fi
  fi
  if [[ "$INSTALL_DOKPLOY" != "yes" ]]; then warn "Skipping Dokploy."; return; fi

  for p in 80 443 3000; do
    if ss -tulnp 2>/dev/null | grep -q ":$p "; then
      err "Port $p is already in use. Dokploy needs 80, 443 and 3000 free. Aborting Dokploy install."
      return
    fi
  done

  log "Running official Dokploy installer (this can take a few minutes)..."
  curl -sSL https://dokploy.com/install.sh | sh
  ok "Dokploy installed. Panel: http://<server-ip>:3000 (or via SSH tunnel)."
  warn "Re-run the firewall step if you installed Docker for the first time:"
  echo "    sudo /usr/local/bin/ufw-docker install && sudo systemctl restart ufw"
}

# ----------------------------------------------------------------------------
# 9. Security audit / score
# ----------------------------------------------------------------------------
run_audit() {
  hr; log "Running security audit"
  echo; echo "${BLD}Security checks${NC}"; hr

  # SSH root login
  #
  # Compare the value instead of `sshd -T | grep -q`: grep exits as soon as it
  # matches, sshd -T then dies of SIGPIPE, and `set -o pipefail` turns the whole
  # pipeline non-zero — so a *correctly* hardened box was reported as FAIL. It
  # only bit the keys that appear early in sshd -T's output, which is why root
  # login failed while password auth (further down) passed.
  if [[ "$(sshd_effective permitrootlogin)" == "no" ]]; then
    audit 10 "SSH root login" pass "Root login disabled"
  else audit 10 "SSH root login" fail "Root login still permitted"; fi

  # SSH password auth
  if [[ "$(sshd_effective passwordauthentication)" == "no" ]]; then
    audit 10 "SSH password auth" pass "Password auth disabled (keys only)"
  else audit 10 "SSH password auth" warn "Password authentication still enabled"; fi

  # SSH port
  local port; port="$(sshd_effective port)"
  if [[ "$port" != "22" ]]; then audit 5 "SSH port" pass "Non-default port ($port)"
  else audit 5 "SSH port" warn "Using default port 22"; fi

  # UFW
  if ufw status 2>/dev/null | grep -qi 'Status: active'; then
    audit 15 "Firewall (UFW)" pass "UFW is active"
  else audit 15 "Firewall (UFW)" fail "UFW is not active"; fi

  # Fail2ban
  if systemctl is-active --quiet fail2ban; then audit 10 "Fail2ban" pass "Running"
  else audit 10 "Fail2ban" fail "Not running"; fi

  # Unattended upgrades
  if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
    audit 10 "Auto security updates" pass "Enabled"
  else audit 10 "Auto security updates" warn "Not enabled"; fi

  # Pending updates
  #
  # `grep -c` PRINTS "0" and exits 1 when it finds nothing, so `|| echo 0`
  # appended a second zero and upd became "0\n0" — which blew up the arithmetic
  # test below with `[[: 0\n0: syntax error` and scored the check as FAIL on a
  # fully up-to-date box. Swallow the status, don't add another value.
  local upd
  upd="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)"
  upd="${upd//[^0-9]/}"
  upd="${upd:-0}"
  if [[ "$upd" -eq 0 ]]; then audit 10 "Pending updates" pass "System up to date"
  elif [[ "$upd" -lt 10 ]]; then audit 10 "Pending updates" warn "$upd updates pending"
  else audit 10 "Pending updates" fail "$upd updates pending"; fi

  # sysctl hardening
  if [[ -f /etc/sysctl.d/99-vps-harden.conf ]]; then audit 5 "Kernel hardening" pass "sysctl profile present"
  else audit 5 "Kernel hardening" warn "No sysctl hardening profile"; fi

  # Non-root sudo user
  #
  # --audit-only runs with NEW_USER unset, so trusting the variable reported
  # "no dedicated sudo user" on a box that had one. Look at the sudo group.
  local sudo_users
  sudo_users="$(getent group sudo 2>/dev/null | awk -F: '{gsub(/,/, " ", $4); print $4}')"
  if [[ -n "${NEW_USER:-}" ]] && id "$NEW_USER" >/dev/null 2>&1; then
    audit 5 "Non-root sudo user" pass "'$NEW_USER' exists"
  elif [[ -n "${sudo_users// /}" ]]; then
    audit 5 "Non-root sudo user" pass "sudo group:${sudo_users}"
  else audit 5 "Non-root sudo user" warn "No dedicated sudo user detected"; fi

  # Docker / UFW fix
  if command -v docker >/dev/null 2>&1; then
    if [[ -x /usr/local/bin/ufw-docker ]] && iptables -L DOCKER-USER -n 2>/dev/null | grep -q .; then
      audit 5 "Docker firewall" pass "ufw-docker rules in place"
    else audit 5 "Docker firewall" warn "Docker present but UFW fix not confirmed"; fi
  fi

  echo; echo "${BLD}Resource snapshot${NC}"; hr
  printf 'Disk:   %s\n' "$(df -h / | awk 'NR==2{print $5" used of "$2}')" | tee -a "$REPORT"
  printf 'Memory: %s\n' "$(free -h | awk '/Mem:/{print $3" used of "$2}')" | tee -a "$REPORT"
  printf 'Uptime: %s\n' "$(uptime -p 2>/dev/null || uptime)" | tee -a "$REPORT"

  # Final score
  local pct=0
  [[ "$MAX_SCORE" -gt 0 ]] && pct=$(( SCORE * 100 / MAX_SCORE ))
  local grade color
  if   [[ $pct -ge 90 ]]; then grade="A - Excellent"; color="$GRN"
  elif [[ $pct -ge 75 ]]; then grade="B - Good";      color="$GRN"
  elif [[ $pct -ge 60 ]]; then grade="C - Fair";      color="$YLW"
  elif [[ $pct -ge 40 ]]; then grade="D - Weak";      color="$YLW"
  else                         grade="F - At risk";   color="$RED"; fi

  echo; hr
  echo "${BLD}SECURITY SCORE: ${color}${pct}/100  (${grade})${NC}"
  hr
  {
    echo ""
    echo "SECURITY SCORE: ${pct}/100 (${grade})  [$SCORE of $MAX_SCORE weighted points]"
  } >> "$REPORT"
  ok "Report saved to $REPORT"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  preflight

  if [[ "$AUDIT_ONLY" == "yes" ]]; then
    run_audit
    exit 0
  fi

  echo
  warn "This will modify SSH, firewall and system settings."
  warn "Keep THIS window open. After it finishes, test a new login from your LAPTOP before disconnecting."
  confirm "Continue with hardening?" || { log "Aborted."; exit 0; }

  do_update
  do_user
  do_dokploy      # decide Dokploy first so firewall opens the right ports
  do_ssh
  do_firewall
  do_fail2ban
  do_sysctl
  do_misc
  run_audit

  hr
  ok "Done. Your server has been hardened."
  echo
  if [[ -n "$GENERATED_KEY_FILE" ]]; then
    echo "${BLD}>>> FIRST: copy your private key to your laptop (if you haven't) <<<${NC}"
    echo "On your LAPTOP:"
    echo "    scp root@<server-ip>:${GENERATED_KEY_FILE} ~/.ssh/${NEW_USER}_key"
    echo "    chmod 600 ~/.ssh/${NEW_USER}_key"
    echo
    echo "${BLD}>>> THEN test the new login BEFORE closing this window <<<${NC}"
    echo "On your LAPTOP, in a NEW terminal:"
    echo "    ${BLD}ssh -i ~/.ssh/${NEW_USER}_key -p ${SSH_PORT} ${NEW_USER}@<server-ip>${NC}"
  else
    echo "${BLD}>>> IMPORTANT: do this BEFORE closing this window <<<${NC}"
    echo "On your LAPTOP, open a NEW terminal window and test the new login:"
    echo "    ${BLD}ssh -p ${SSH_PORT} ${NEW_USER:-<user>}@<server-ip>${NC}"
  fi
  echo "  - If it works: you can safely close THIS window. You're done."
  echo "  - If it fails: keep THIS window open and fix it here."
  [[ "$INSTALL_DOKPLOY" == "yes" ]] && {
    echo
    echo "To open Dokploy, run this on your LAPTOP, then visit http://localhost:3000 :"
    if [[ -n "$GENERATED_KEY_FILE" ]]; then
      echo "    ${BLD}ssh -i ~/.ssh/${NEW_USER}_key -p ${SSH_PORT} ${NEW_USER}@<server-ip> -L 3000:localhost:3000${NC}"
    else
      echo "    ${BLD}ssh -p ${SSH_PORT} ${NEW_USER:-root}@<server-ip> -L 3000:localhost:3000${NC}"
    fi
  }
  echo
  echo "Re-check your security score anytime:  sudo ./vps-harden.sh --audit-only"
}

main "$@"
