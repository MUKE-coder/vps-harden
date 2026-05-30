# vps-harden

> One Bash script to update, harden, audit and (optionally) install [Dokploy](https://dokploy.com) on a fresh Ubuntu/Debian VPS — with a 0–100 security score at the end.

A brand-new VPS (Contabo, Hetzner, DigitalOcean, etc.) is hit by automated attacks within minutes of getting a public IP. `vps-harden.sh` takes a clean server, locks it down to a sensible baseline, optionally installs Dokploy, and then **audits itself and prints a security score** so you can see exactly where you stand.

It's aware of one trap most tutorials miss: **Docker bypasses UFW**, and Dokploy runs on Docker Swarm. The script fixes that with `ufw-docker` and keeps the Dokploy panel off the public internet.

---

## Features

- Full system update + automatic security patches (`unattended-upgrades`)
- Creates a non-root sudo user and installs your SSH key
- SSH hardening — no root login, key-only auth, custom port (validated before restart, auto-reverts on failure)
- UFW firewall with a deny-by-default posture
- **Docker/UFW fix** so published container ports aren't silently exposed
- Fail2ban brute-force protection
- Kernel/network hardening via `sysctl` (anti-spoofing, SYN cookies, ASLR, …)
- Core-dump and shared-memory hardening
- **Optional** Dokploy install (port-conflict checked first)
- Self-audit with a weighted **0–100 score**, letter grade, and saved report

---

## Quick start

```bash
git clone https://github.com/MUKE-coder/vps-harden.git
cd vps-harden
chmod +x vps-harden.sh
sudo ./vps-harden.sh
```

Answer the prompts, **keep your current SSH window open**, test a new login, and you're done.

Re-check the score anytime (changes nothing):

```bash
sudo ./vps-harden.sh --audit-only
```

---

## Before you start

Generate an SSH key on your **local** machine if you don't have one — you'll paste the public key during setup:

```bash
ssh-keygen -t ed25519 -C "you@laptop"
cat ~/.ssh/id_ed25519.pub
```

---

## Usage

### Interactive (recommended first time)

```bash
sudo ./vps-harden.sh
```

### Non-interactive (automation)

```bash
sudo NEW_USER=deploy \
     SSH_PORT=2222 \
     SSH_PUBKEY="ssh-ed25519 AAAA... you@laptop" \
     INSTALL_DOKPLOY=yes \
     ./vps-harden.sh --yes
```

### Flags

| Flag | Effect |
|------|--------|
| *(none)* | Full interactive hardening |
| `--audit-only` | Only run the audit and print the score; changes nothing |
| `--no-dokploy` | Harden but skip Dokploy |
| `--yes` / `-y` | Non-interactive; uses env vars and defaults |
| `--help` | Show usage |

### Environment variables

| Variable | Meaning | Example |
|----------|---------|---------|
| `NEW_USER` | Name of the non-root sudo user | `deploy` |
| `SSH_PORT` | Port SSH will listen on | `2222` |
| `SSH_PUBKEY` | Public key installed for the new user | `ssh-ed25519 AAAA...` |
| `INSTALL_DOKPLOY` | `yes` or `no` | `yes` |

---

## The security score

At the end of every run (and on `--audit-only`) you get a weighted score out of 100:

```
============================================================
SECURITY SCORE: 92/100  (A - Excellent)
============================================================
```

A full report is saved to `/root/vps-harden-report-<timestamp>.txt`.

| Check | Weight |
|-------|-------:|
| SSH root login disabled | 10 |
| SSH password auth disabled | 10 |
| Non-default SSH port | 5 |
| UFW active | 15 |
| Fail2ban running | 10 |
| Auto security updates | 10 |
| No pending updates | 10 |
| Kernel hardening (sysctl) | 5 |
| Non-root sudo user | 5 |
| Docker firewall (ufw-docker) | 5 |

`WARN` = half marks, `FAIL` = zero. Aim for an A (≥90).

---

## After hardening — verify before you disconnect

**Always test a new login in a separate terminal before closing your current session:**

```bash
ssh -p <your-ssh-port> <new-user>@<server-ip>
```

Spot-check the pieces:

```bash
sudo sshd -T | grep -Ei 'port|permitrootlogin|passwordauthentication'
sudo ufw status verbose
sudo fail2ban-client status sshd
sudo iptables -L DOCKER-USER -n     # should have rules if Dokploy installed
```

From your **laptop**, confirm only intended ports answer (SSH + 80/443, *not* 3000):

```bash
nmap -Pn <server-ip>
```

---

## Reaching the Dokploy panel

Port 3000 stays closed to the public. Reach the dashboard through an SSH tunnel:

```bash
ssh -p <your-ssh-port> -L 3000:localhost:3000 <user>@<server-ip>
# then open http://localhost:3000
```

The first user becomes admin — create your account and enable 2FA.

---

## Requirements

- Ubuntu 22.04 / 24.04 or Debian (tested on Ubuntu)
- Root / sudo access
- A fresh server is ideal

---

## Caveats

This is a **baseline**, not a guarantee. It's no substitute for ongoing patching, app-level security, off-site backups, and monitoring. Read the script before running it as root — every section is commented. On non-Ubuntu/Debian distros it warns but doesn't stop; behaviour there is untested.

---

## Contributing

Issues and pull requests welcome.

## License

MIT
