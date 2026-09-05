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
#   sudo ./vps-harden.sh --info          # "how do I log in?" - port, user, key
#   sudo ./vps-harden.sh --audit-only    # just score, change nothing
#   sudo ./vps-harden.sh --no-dokploy    # harden but skip Dokploy
#   sudo ./vps-harden.sh --yes           # non-interactive (uses env vars / defaults)
#   sudo ./vps-harden.sh --auto-port     # move SSH to a random free high port
#
# Configure with environment variables (or answer the prompts):
#   NEW_USER=deploy
#   NEW_USER_PASSWORD=...          (blank => prompt, or auto-generated under --yes)
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

# Stable path on purpose (not timestamped): this is the file you tell a stranded
# beginner to `cat` from the provider's web console. It holds the username, the
# SSH port and the key path — the three things people lose.
CREDS="/root/vps-harden-login.txt"

# Where generated key pairs live. One definition: do_user writes here and
# show_info reads here, and they must never drift apart.
KEYDIR="/root/vps-harden-keys"

AUDIT_ONLY="no"
INFO_ONLY="no"
ASSUME_YES="no"
SCORE=0
MAX_SCORE=0

# Defaults (overridable by env or prompt)
NEW_USER="${NEW_USER:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
INSTALL_DOKPLOY="${INSTALL_DOKPLOY:-}"
GENERATED_KEY_FILE=""

# Password for the new user. Empty => prompt (interactive) or generate (--yes).
# Set NEW_USER_PASSWORD in the environment to choose your own.
NEW_USER_PASSWORD="${NEW_USER_PASSWORD:-}"
USER_PASSWORD_GENERATED="no"

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
    --info|--login) INFO_ONLY="yes" ;;
    --no-dokploy) INSTALL_DOKPLOY="no" ;;
    --auto-port)  SSH_PORT="auto" ;;
    --yes|-y)     ASSUME_YES="yes" ;;
    --help|-h)
      # Print the header comment block, however long it grows: every comment
      # line after the shebang, stopping at the first line that is not one.
      # `head -n 40` used to hard-code a line count, so growing the header
      # leaked the "Colours & logging" section into --help.
      awk 'NR==1 { next }
           /^#/  { sub(/^#[[:space:]]?/, ""); print; next }
                 { exit }' "$0"
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

ask_secret() {
  # ask_secret "prompt" -> echoes a hidden-input answer ("" under --yes)
  local prompt="$1" reply
  [[ "$ASSUME_YES" == "yes" ]] && { echo ""; return; }
  read -r -s -p "${BLU}[?]${NC} $prompt: " reply
  echo >&2   # newline after the hidden input
  echo "$reply"
}

gen_password() {
  # A strong, shell-safe password: 20 chars, no symbols to trip up copy/paste.
  local p=""
  if command -v openssl >/dev/null 2>&1; then
    p="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 20)"
  fi
  [[ -z "$p" ]] && p="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
  printf '%s' "$p"
}

# The server's own public IP, so every command we print can be copy-pasted as-is.
#
# Printing "<server-ip>" placeholders is how beginners end up typing the literal
# angle brackets, or pasting a command against the wrong box. Cached after the
# first lookup because we print it many times.
SERVER_IP=""
detect_ip() {
  if [[ -n "$SERVER_IP" ]]; then printf '%s' "$SERVER_IP"; return; fi
  local ip=""
  ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || ip="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || ip="<server-ip>"
  SERVER_IP="$ip"
  printf '%s' "$SERVER_IP"
}

# Print a generated private key to the terminal, with save instructions.
#
# This exists because scp is a trap. The key lives in /root, and by the time the
# run finishes root SSH login is OFF and the port has moved — so the `scp
# root@...` line older versions printed at the end could never work. Copy/paste
# out of the terminal you are already sitting in always works, on every OS.
print_private_key() {
  local keyfile="$1" user="$2" port="$3" ip
  # Windows paths need a literal backslash, which is painful to get right
  # through the layers of quoting below. Hold it in a variable instead.
  local bs='\'
  ip="$(detect_ip)"
  [[ -r "$keyfile" ]] || return 0
  echo
  hr
  echo "${BLD}>>> YOUR PRIVATE KEY - COPY THIS TO YOUR LAPTOP NOW <<<${NC}"
  hr
  echo "Select EVERYTHING between the BEGIN and END lines below (including"
  echo "those two lines) and copy it."
  echo
  cat "$keyfile"
  echo
  echo "${BLD}On your LAPTOP, save it:${NC}"
  echo
  echo "  ${BLD}Mac, Linux, or Windows Git Bash / WSL:${NC}"
  echo "    mkdir -p ~/.ssh && nano ~/.ssh/${user}_key   # paste, Ctrl+O, Enter, Ctrl+X"
  echo "    chmod 600 ~/.ssh/${user}_key"
  echo
  echo "  ${BLD}Windows PowerShell${NC} (there is no chmod there - Windows uses icacls):"
  echo "    mkdir \$HOME${bs}.ssh -Force"
  echo "    notepad \$HOME${bs}.ssh${bs}${user}_key          # paste, then save and close"
  echo "    icacls \$HOME${bs}.ssh${bs}${user}_key /inheritance:r /grant:r \"\$env:USERNAME:R\""
  echo
  echo "${BLD}Then log in with:${NC}"
  echo "    ${BLD}ssh -i ~/.ssh/${user}_key -p ${port} ${user}@${ip}${NC}"
  echo "    (PowerShell: write \$HOME${bs}.ssh${bs}${user}_key instead of ~/.ssh/${user}_key)"
  hr
}

# One file that answers "how do I get back in?" - written every run, stable path.
write_credentials() {
  local port="$1" ip
  ip="$(detect_ip)"
  {
    echo "vps-harden login details  (generated $TIMESTAMP)"
    echo "============================================================"
    echo "Server IP   : $ip"
    echo "Username    : ${NEW_USER:-<none created>}"
    echo "SSH port    : $port"
    echo "Private key : ${GENERATED_KEY_FILE:-<you supplied your own key>}"
    if [[ -n "$NEW_USER_PASSWORD" ]]; then
      echo "Password    : $NEW_USER_PASSWORD"
      echo "              (console / su only - SSH is key-only)"
    fi
    echo
    echo "Log in from your laptop with:"
    if [[ -n "$GENERATED_KEY_FILE" ]]; then
      echo "  ssh -i ~/.ssh/${NEW_USER}_key -p ${port} ${NEW_USER}@${ip}"
    else
      echo "  ssh -p ${port} ${NEW_USER:-<user>}@${ip}"
    fi
    echo
    echo "Lost the key on your laptop? Get it back from this server:"
    if [[ -n "$GENERATED_KEY_FILE" ]]; then
      echo "  sudo cat $GENERATED_KEY_FILE"
      echo "  ...then paste it into ~/.ssh/${NEW_USER}_key on your laptop."
    fi
    echo
    echo "Forgot any of the above? Re-print it with:"
    echo "  cd ~/vps-harden && sudo ./vps-harden.sh --info"
  } >"$CREDS"
  chmod 600 "$CREDS"

  # A copy the user can read without sudo once they are in.
  if [[ -n "$NEW_USER" ]] && id "$NEW_USER" >/dev/null 2>&1; then
    local home; home="$(eval echo "~$NEW_USER")"
    if [[ -d "$home" ]]; then
      grep -v '^Password    :' "$CREDS" | grep -v 'console / su only' >"$home/vps-harden-login.txt" || true
      chown "$NEW_USER:$NEW_USER" "$home/vps-harden-login.txt" 2>/dev/null || true
      chmod 600 "$home/vps-harden-login.txt" 2>/dev/null || true
    fi
  fi
  ok "Login details saved to $CREDS"
}

# --info: reconstruct the login details from the live system.
#
# The whole point is that it works when the user has lost everything and is
# sitting at the provider's rescue console, so it reads the running config
# rather than trusting variables from an earlier run.
show_info() {
  local port user_list ip keyfile
  port="$(sshd_effective port)"; port="${port:-22}"
  ip="$(detect_ip)"
  user_list="$(getent group sudo 2>/dev/null | awk -F: '{gsub(/,/, " ", $4); print $4}')"

  hr
  echo "${BLD}How to log into this server${NC}"
  hr
  echo "Server IP        : $ip"
  echo "SSH port         : ${BLD}${port}${NC}"
  echo "Sudo user(s)     : ${user_list:-none found}"
  echo "Root SSH login   : $(sshd_effective permitrootlogin)"
  echo "Password SSH auth: $(sshd_effective passwordauthentication)"
  echo

  if compgen -G "$KEYDIR/*_key" >/dev/null 2>&1; then
    echo "${BLD}Private keys this script generated:${NC}"
    for keyfile in "$KEYDIR"/*_key; do
      local u; u="$(basename "$keyfile")"; u="${u%_key}"
      echo "  $keyfile   -> for user '$u'"
      echo "      ssh -i ~/.ssh/${u}_key -p ${port} ${u}@${ip}"
    done
    echo
    echo "Don't have the key on your laptop? Print it and copy it out of this"
    echo "window (this works even with SSH locked down):"
    echo "    ${BLD}sudo cat $KEYDIR/<user>_key${NC}"
  else
    echo "No generated keys found in $KEYDIR/ (you supplied your own)."
  fi
  echo
  [[ -f "$CREDS" ]] && { echo "Full details: ${BLD}sudo cat $CREDS${NC}"; echo; }
  hr
}

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
preflight() {
  hr; log "Pre-flight checks"
  if [[ "$EUID" -ne 0 ]]; then err "Run as root (use sudo)."; exit 1; fi

  # Defaults first: `set -u` turns an unreadable /etc/os-release into an
  # "unbound variable" crash three lines later, on the exact path that is
  # supposed to warn and carry on.
  PRETTY_NAME="${PRETTY_NAME:-unknown OS}"
  ID="${ID:-unknown}"
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
    ok "Granted '$NEW_USER' passwordless sudo (so automation + the CLI work)"
  else
    rm -f "$sudoers"
    err "sudoers rule failed its syntax check - not installed."
    err "Do NOT close this session: '$NEW_USER' cannot reach root yet."
  fi

  # Give the user an actual password as well.
  #
  # The NOPASSWD rule above is what fixes the lockout for automation, but with
  # SSH about to become key-only, a lost key would still leave you stranded. A
  # real password is your recovery route: the provider's web console logs in
  # with a password even when SSH won't. This password is NOT accepted for SSH
  # (that stays key-only) — only for the console and `su`.
  if [[ -z "$NEW_USER_PASSWORD" ]]; then
    NEW_USER_PASSWORD="$(ask_secret "Set a password for '$NEW_USER' (blank = generate a strong one)")"
  fi
  if [[ -z "$NEW_USER_PASSWORD" ]]; then
    NEW_USER_PASSWORD="$(gen_password)"
    USER_PASSWORD_GENERATED="yes"
  fi
  if echo "${NEW_USER}:${NEW_USER_PASSWORD}" | chpasswd 2>/dev/null; then
    ok "Set a password for '$NEW_USER' (console / recovery login)"
  else
    warn "Could not set a password for '$NEW_USER' — set one later with: sudo passwd $NEW_USER"
    NEW_USER_PASSWORD=""
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
    local keydir="$KEYDIR"
    local keyfile="$keydir/${NEW_USER}_key"
    install -d -m 700 "$keydir"
    if [[ ! -f "$keyfile" ]]; then
      ssh-keygen -t ed25519 -N "" -C "${NEW_USER}@$(hostname)" -f "$keyfile" >/dev/null
    fi
    SSH_PUBKEY="$(cat "${keyfile}.pub")"
    GENERATED_KEY_FILE="$keyfile"
    ok "Created a key pair for you: $keyfile"

    # Also drop a copy in the user's own home.
    #
    # /root is unreadable to anyone but root, so a user who gets in through the
    # provider's console as '$NEW_USER' (the password set above is exactly for
    # that) could not reach their own key. Now they can just `cat` it.
    local home_copy; home_copy="$(eval echo "~$NEW_USER")/${NEW_USER}_key"
    if install -m 600 -o "$NEW_USER" -g "$NEW_USER" "$keyfile" "$home_copy" 2>/dev/null; then
      ok "Copy of the key placed at $home_copy (readable by '$NEW_USER')"
    fi

    echo
    warn "Your key is on the SERVER. You must get it onto your LAPTOP."
    echo "The script will print the whole key at the end so you can copy/paste it,"
    echo "along with the exact login command. ${BLD}Don't close this window until you have.${NC}"
    echo
    echo "If you'd rather download it as a file, do it ${BLD}NOW${NC}, from a second"
    echo "terminal on your laptop, while root login still works on port 22:"
    echo "    ${BLD}scp root@$(detect_ip):${keyfile} ~/.ssh/${NEW_USER}_key${NC}"
    warn "That scp stops working in a minute: this script is about to disable root"
    warn "SSH login and (maybe) move the SSH port. Copy/paste at the end always works."
    echo
    if [[ "$ASSUME_YES" != "yes" ]]; then
      read -r -p "${YLW}[?]${NC} Press Enter to continue... " _
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

  if [[ "$SSH_PORT" == "22" ]]; then
    echo "SSH currently listens on port 22. You can move it to cut down brute-force"
    echo "noise. Whatever you choose, you must use it in EVERY future ssh command"
    echo "(ssh -p <port> ...). Press Enter to stay on 22 - that is a fine choice."
    SSH_PORT="$(ask 'SSH port to use (or "auto" to pick a random one)' '22')"
  fi

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
# ('Protocol 2' is not set: it was removed in OpenSSH 7.6 and now only logs a
#  "Deprecated option" warning on every start.)
Port ${SSH_PORT}
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication $([[ "$can_disable_pw" == "yes" ]] && echo no || echo yes)
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
AllowAgentForwarding no
# Left ON deliberately. An SSH tunnel (ssh -L 3000:localhost:3000) is how you
# are meant to reach Dokploy's admin panel and any other internal service, and
# 'no' silently kills that with "channel: open failed: administratively
# prohibited" - while the alternative, publishing port 3000 to the internet, is
# far worse. It only matters to someone who already holds your private key.
AllowTcpForwarding yes
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

    # Everything downstream (UFW, Fail2ban, the final summary, the credentials
    # file) must agree with the port sshd is ACTUALLY listening on. If they
    # drift, UFW opens a port nothing is serving and closes the one that is.
    [[ -n "$eff_port" ]] && SSH_PORT="$eff_port"

    if [[ "$can_disable_pw" == "yes" && "$eff_pw" == "yes" ]]; then
      err "Asked sshd to disable password auth, but it is still enabled."
      err "Something in /etc/ssh/sshd_config.d/ or sshd_config overrides us; check: sshd -T | grep -i password"
    fi

    # Say the port out loud, on its own, right where it changes. Buried in a
    # sentence it gets scrolled past - and a port you cannot remember is the
    # same as a locked door.
    echo
    echo "${BLD}    +--------------------------------------------------+${NC}"
    printf '%s    |  YOUR SSH PORT IS NOW: %-25s |%s\n' "$BLD" "${eff_port:-$SSH_PORT}" "$NC"
    echo "${BLD}    +--------------------------------------------------+${NC}"
    echo "    Write it down. You need it in every ssh/scp command from now on."
    echo "    Forgot it later? Run:  sudo ./vps-harden.sh --info"
    echo
    warn "Keep this window open. From your LAPTOP, test a NEW login before closing it:"
    echo "    ssh -p ${eff_port:-$SSH_PORT} ${NEW_USER:-<user>}@$(detect_ip)"
  else
    err "sshd config test failed - reverting."
    rm -f "$conf"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    # We reverted, so the port we wanted never took effect. Fall back to the
    # real one or UFW will open a port nothing is listening on.
    local reverted; reverted="$(sshd_effective port)"
    SSH_PORT="${reverted:-22}"
    warn "SSH is still on port $SSH_PORT."
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
  # --info runs BEFORE preflight on purpose: preflight exits when the box has no
  # internet, and "I need to know my SSH port" is exactly the situation where
  # you are on a rescue console with limited connectivity.
  if [[ "$INFO_ONLY" == "yes" ]]; then
    if [[ "$EUID" -ne 0 ]]; then err "Run as root (use sudo)."; exit 1; fi
    show_info
    exit 0
  fi

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

  write_credentials "$SSH_PORT"

  local ip; ip="$(detect_ip)"

  hr
  ok "Done. Your server has been hardened."
  echo

  # The three facts people lose, together, in one place, before anything else.
  echo "${BLD}    +--------------------------------------------------+${NC}"
  printf '%s    |  %-46s  |%s\n' "$BLD" "SERVER   : $ip" "$NC"
  printf '%s    |  %-46s  |%s\n' "$BLD" "USERNAME : ${NEW_USER:-<none>}" "$NC"
  printf '%s    |  %-46s  |%s\n' "$BLD" "SSH PORT : $SSH_PORT" "$NC"
  echo "${BLD}    +--------------------------------------------------+${NC}"
  echo "    Saved on the server at: $CREDS"
  echo "    Show it again anytime:  sudo ./vps-harden.sh --info"
  echo

  # Show the account password. If we generated it, this is the ONLY time it's
  # shown — it's the recovery route if the SSH key is ever lost.
  if [[ "$USER_PASSWORD_GENERATED" == "yes" && -n "$NEW_USER_PASSWORD" ]]; then
    echo "${BLD}>>> SAVE THIS: recovery password for '${NEW_USER}' <<<${NC}"
    echo "    ${BLD}${NEW_USER_PASSWORD}${NC}"
    echo "    Use it to log in via your provider's web console if you lose your SSH key."
    echo "    (It is NOT used for SSH — that stays key-only.)"
    echo
  elif [[ -n "$NEW_USER_PASSWORD" ]]; then
    echo "The password you set for '${NEW_USER}' works for console / recovery login."
    echo "(SSH stays key-only — the password is not accepted for SSH.)"
    echo
  fi

  if [[ -n "$GENERATED_KEY_FILE" ]]; then
    # Note what is NOT here any more: `scp root@...`. Root SSH login was
    # disabled a few steps ago and the port may have moved, so that command
    # could never have worked at this point in the run - it just looked like it
    # should, and sent people off to fight "Permission denied" instead of
    # copying the key that was on screen in front of them.
    print_private_key "$GENERATED_KEY_FILE" "$NEW_USER" "$SSH_PORT"
    echo
    echo "${BLD}>>> THEN test the new login BEFORE closing this window <<<${NC}"
    echo "On your LAPTOP, in a NEW terminal:"
    echo "    ${BLD}ssh -i ~/.ssh/${NEW_USER}_key -p ${SSH_PORT} ${NEW_USER}@${ip}${NC}"
  else
    echo "${BLD}>>> IMPORTANT: do this BEFORE closing this window <<<${NC}"
    echo "On your LAPTOP, open a NEW terminal window and test the new login:"
    echo "    ${BLD}ssh -p ${SSH_PORT} ${NEW_USER:-<user>}@${ip}${NC}"
  fi
  echo "  - If it works: you can safely close THIS window. You're done."
  echo "  - If it fails: keep THIS window open and fix it here."
  [[ "$INSTALL_DOKPLOY" == "yes" ]] && {
    echo
    echo "To open Dokploy, run this on your LAPTOP, then visit http://localhost:3000 :"
    if [[ -n "$GENERATED_KEY_FILE" ]]; then
      echo "    ${BLD}ssh -i ~/.ssh/${NEW_USER}_key -p ${SSH_PORT} ${NEW_USER}@${ip} -L 3000:localhost:3000${NC}"
    else
      echo "    ${BLD}ssh -p ${SSH_PORT} ${NEW_USER:-root}@${ip} -L 3000:localhost:3000${NC}"
    fi
  }
  echo
  echo "Re-check your security score anytime:  sudo ./vps-harden.sh --audit-only"
}

main "$@"
