# Hardening a Fresh VPS (and Installing Dokploy) with One Script

If you rent VPS boxes from providers like Contabo, Hetzner or DigitalOcean and drop your apps on them with [Dokploy](https://dokploy.com), you already know the uncomfortable truth: a brand-new VPS is exposed to automated attacks within *minutes* of getting a public IP. Bots scan the entire IPv4 space constantly, hammering port 22 with credential-stuffing attempts and probing every open port for known vulnerabilities.

This post walks through `vps-harden.sh` — a single, readable Bash script that takes a fresh Ubuntu/Debian server, locks it down to a sensible baseline, optionally installs Dokploy, and then **audits itself and prints a 0–100 security score** so you can see exactly where you stand.

It draws on well-known community hardening checklists (vps-audit, vps-harden, the Anyone relay hardening guide, and others) and folds them into one workflow that is aware of one critical gotcha: **Docker bypasses your firewall**, and Dokploy runs on Docker Swarm. More on that below.

---

## TL;DR

```bash
# On a fresh Ubuntu 22.04 / 24.04 VPS:
git clone https://github.com/MUKE-coder/vps-harden.git
cd vps-harden
chmod +x vps-harden.sh
sudo ./vps-harden.sh
```

Answer a handful of prompts, keep your current SSH window open, test the new login, and you're done. Re-check the score anytime with:

```bash
sudo ./vps-harden.sh --audit-only
```

---

## What the script actually does

The script runs through nine stages. Every change is deliberate and explained inline in the source — nothing is hidden. Here is the full picture.

### 1. Pre-flight checks

Before touching anything it confirms it is running as root, detects the OS (warning you if it isn't Ubuntu/Debian), and verifies the box has internet. It then opens a timestamped report file in `/root/` that every audit result is written to.

### 2. System update + automatic security patches

It runs a full `apt update`, `upgrade` and `dist-upgrade`, installs the base tooling it needs (`ufw`, `fail2ban`, `unattended-upgrades`, `curl`, `auditd` and friends), and then **enables unattended security upgrades**. This is the single highest-value, lowest-effort thing you can do: most real-world compromises exploit known bugs that already have patches. Automatic security updates close that window without you having to remember.

### 3. A non-root sudo user with your SSH key

Logging in as `root` over SSH is a bad habit. The script creates a dedicated sudo user (you choose the name), drops your public key into `~/.ssh/authorized_keys` with correct `700`/`600` permissions, and adds the user to the `sudo` group. You provide the key either through the `SSH_PUBKEY` environment variable or by pasting it at the prompt.

> If no key is found anywhere, the script **refuses to disable password login** later — that's a deliberate guard against locking yourself out.

### 4. SSH hardening

It writes a drop-in config to `/etc/ssh/sshd_config.d/99-hardening.conf` (rather than mangling the main file) that:

- Moves SSH to a non-default port of your choosing (cuts background noise dramatically)
- Disables root login (`PermitRootLogin no`)
- Disables password authentication — **only** when a key is present
- Turns off X11 and agent forwarding, empty passwords, and challenge-response
- Limits auth tries to 3 and tightens session/timeout settings

Crucially, it runs `sshd -t` to validate the config *before* restarting SSH, and reverts automatically if the test fails. It then reminds you to **test a new login in a separate terminal before closing your current session**.

### 5. Firewall — and the Docker/Dokploy trap

The script resets UFW to a deny-by-default posture, then opens only what you need: your SSH port, and (if you're installing Dokploy) ports 80, 443 and 443/UDP for Traefik.

Here's the part most tutorials get wrong. **Docker publishes container ports by writing its own `iptables` rules, completely bypassing UFW.** If you `ufw deny` a port but a Docker container publishes it, the world can still reach it. Since Dokploy runs everything on Docker Swarm, this matters a lot.

The script fixes this by installing [`ufw-docker`](https://github.com/chaifeng/ufw-docker), which inserts rules into the `DOCKER-USER` chain so that Docker traffic finally respects UFW. After this, published container ports are no longer automatically exposed to the internet.

It also keeps the **Dokploy admin panel on port 3000 closed to the public**. You reach it through an SSH tunnel instead:

```bash
ssh -p <your-ssh-port> -L 3000:localhost:3000 <user>@<server-ip>
# then open http://localhost:3000 in your browser
```

This means your admin dashboard is never exposed to bots — only people with SSH access can reach it.

### 6. Fail2ban

Brute-force protection. A jail watches the SSH log and bans an IP for 24 hours after 3 failed attempts. The jail is configured for whatever custom SSH port you chose.

### 7. Kernel / network hardening (sysctl)

A `sysctl` profile enables reverse-path filtering (anti-spoofing), SYN-cookie flood protection, ignores ICMP redirects and source routing, logs martian packets, ignores broadcast pings, and enforces full ASLR (`kernel.randomize_va_space = 2`).

### 8. Misc hardening

Core dumps are disabled (they can leak secrets from memory) and `/run/shm` is mounted `noexec,nosuid` on the next boot.

### 9. Optional Dokploy install

If you opt in, the script first checks that ports 80, 443 and 3000 are free (the official installer fails loudly if they aren't), then runs the official installer:

```bash
curl -sSL https://dokploy.com/install.sh | sh
```

This installs Docker if needed, initialises Docker Swarm, sets up the overlay network, and deploys Dokploy along with Postgres, Redis and Traefik. **Installing Dokploy is entirely optional** — pass `--no-dokploy`, answer "no" at the prompt, or set `INSTALL_DOKPLOY=no`.

---

## How to set it up

### Step 1 — Clone the repo onto the server

SSH into your VPS, then clone it straight from GitHub:

```bash
git clone https://github.com/MUKE-coder/vps-harden.git
cd vps-harden
chmod +x vps-harden.sh
```

> If `git` isn't installed yet on a bare image: `sudo apt update && sudo apt install -y git`

### Step 2 — Prepare your SSH public key

On your **local** machine, if you don't already have a key:

```bash
ssh-keygen -t ed25519 -C "you@laptop"
cat ~/.ssh/id_ed25519.pub   # this is what you'll paste / pass in
```

### Step 3 — Run it

**Interactive (recommended the first time):**

```bash
sudo ./vps-harden.sh
```

It will ask for the new username, SSH port, your public key, and whether to install Dokploy.

**Non-interactive (for automation):**

```bash
sudo NEW_USER=deploy \
     SSH_PORT=2222 \
     SSH_PUBKEY="ssh-ed25519 AAAA... you@laptop" \
     INSTALL_DOKPLOY=yes \
     ./vps-harden.sh --yes
```

### Available flags

| Flag | Effect |
|------|--------|
| *(none)* | Full interactive hardening |
| `--audit-only` | Only run the audit and print the score; changes nothing |
| `--no-dokploy` | Harden but skip Dokploy |
| `--yes` / `-y` | Non-interactive; uses env vars and defaults |
| `--help` | Show usage |

### Configuration via environment variables

| Variable | Meaning | Example |
|----------|---------|---------|
| `NEW_USER` | Name of the non-root sudo user | `deploy` |
| `SSH_PORT` | Port SSH will listen on | `2222` |
| `SSH_PUBKEY` | Public key installed for the new user | `ssh-ed25519 AAAA...` |
| `INSTALL_DOKPLOY` | `yes` or `no` | `yes` |

---

## How to check everything is good

### 1. Read the score

At the end of every run (and on every `--audit-only`) the script prints a weighted **security score out of 100** with a letter grade:

```
============================================================
SECURITY SCORE: 92/100  (A - Excellent)
============================================================
```

A full report is saved to `/root/vps-harden-report-<timestamp>.txt`. The checks and their weights:

| Check | Weight | Pass condition |
|-------|-------:|----------------|
| SSH root login | 10 | `PermitRootLogin no` |
| SSH password auth | 10 | Disabled (keys only) |
| SSH port | 5 | Non-default port |
| Firewall (UFW) | 15 | UFW active |
| Fail2ban | 10 | Service running |
| Auto security updates | 10 | `unattended-upgrades` enabled |
| Pending updates | 10 | System up to date |
| Kernel hardening | 5 | sysctl profile present |
| Non-root sudo user | 5 | Dedicated user exists |
| Docker firewall | 5 | `ufw-docker` rules present |

A `WARN` earns half marks; a `FAIL` earns zero. Aim for an A (≥90).

### 2. Verify the new login *before* you disconnect

This is the one rule you must not skip. In a **separate** terminal:

```bash
ssh -p <your-ssh-port> <new-user>@<server-ip>
```

If that works, you can safely close your original session. If it doesn't, you still have the old window open to fix things.

### 3. Spot-check the individual pieces

```bash
# SSH effective config
sudo sshd -T | grep -Ei 'port|permitrootlogin|passwordauthentication'

# Firewall
sudo ufw status verbose

# Fail2ban status and the SSH jail
sudo fail2ban-client status
sudo fail2ban-client status sshd

# Pending updates
apt list --upgradable 2>/dev/null

# Kernel hardening applied
sudo sysctl net.ipv4.tcp_syncookies kernel.randomize_va_space
```

### 4. Confirm Docker is respecting the firewall

If you installed Dokploy, make sure the `ufw-docker` fix is actually in place:

```bash
sudo iptables -L DOCKER-USER -n
```

You should see rules there, not an empty chain. From an **outside** machine, scan the box and confirm only your intended ports answer:

```bash
nmap -Pn <server-ip>          # run from your laptop, not the server
```

You should see your SSH port plus 80/443 if Dokploy is installed — and **not** 3000.

### 5. Reach the Dokploy panel safely

```bash
ssh -p <your-ssh-port> -L 3000:localhost:3000 <user>@<server-ip>
```

Then visit `http://localhost:3000`, create your admin account (the first user becomes admin), and turn on two-factor authentication. Point your apps' domains at the server, and let Traefik handle HTTPS automatically.

---

## A few honest caveats

- This is a **baseline**, not a guarantee. It dramatically reduces your attack surface but it isn't a substitute for ongoing patching, good app-level security, off-site backups, and monitoring.
- Re-run `--audit-only` periodically (a weekly cron is a good idea) so a creeping pile of pending updates or a service that died doesn't quietly drag your score down.
- Grab the latest version anytime with `git pull` inside the cloned `vps-harden` directory.
- Always read a script before running it as root — including this one. Every section is commented for exactly that reason.
- The script targets Ubuntu/Debian. It will warn but not stop on other distros; behaviour there is untested.

Harden first, deploy second. Your future self — and your apps — will thank you.
