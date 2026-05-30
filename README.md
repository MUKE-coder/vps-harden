# vps-harden

> One simple script to secure a brand-new Ubuntu/Debian VPS — and optionally install [Dokploy](https://dokploy.com). It cleans up your server's security, then gives you a **0–100 score** so you can see how safe it is.

## 🛑 Read this first (especially if you're new)

There are **two different computers** involved, and mixing them up is the #1 mistake beginners make:

| | What it is | What you do here |
|---|---|---|
| 💻 **Your laptop** | The computer in front of you | Connect to the server, make your SSH key |
| ☁️ **Your VPS / server** | The remote machine you rented (Contabo, Hetzner, etc.) | **This is where the script runs** |

👉 **You run this script ON THE SERVER, not on your laptop.** You first connect to the server from your laptop using SSH, and then you run everything inside that connection.

Think of it like a video call: your laptop is *you*, the server is the *person you called*. The script does its work on their side, you're just controlling it through the call.

---

## Why you need this

The moment your new server gets a public IP, bots on the internet start trying to break into it — guessing passwords, scanning for open doors. A fresh server is wide open. This script closes those doors before the bots get in.

---

## What it does, in plain English

- ✅ Installs all the latest security updates (and keeps installing them automatically)
- ✅ Creates a normal user for you so you stop logging in as the all-powerful "root"
- ✅ Locks down SSH (how you remotely connect) so only **you** with your key can get in
- ✅ Turns on a firewall that blocks everything except what you actually need
- ✅ Adds Fail2ban, which auto-bans anyone trying to guess your password
- ✅ Fixes a hidden flaw where Docker quietly pokes holes in your firewall
- ✅ **Optionally** installs Dokploy (the tool you use to deploy your apps)
- ✅ Gives you a **security score out of 100** at the end so you know you're safe

---

## Step-by-step guide (start to finish)

### Step 1 — Make an SSH key on your laptop 💻

An SSH key is like a digital lock-and-key. The **public** half goes on the server; the **private** half stays secret on your laptop. This is what lets you log in without a password.

Open a terminal **on your laptop** and run:

```bash
ssh-keygen -t ed25519 -C "you@laptop"
```

Press Enter to accept the defaults. Then show your **public** key (the safe one to share):

```bash
cat ~/.ssh/id_ed25519.pub
```

Copy the whole line it prints (starts with `ssh-ed25519 ...`). You'll paste it later. **Keep this terminal handy.**

> Already have a key? Skip to Step 2 — just run that `cat` command to grab your public key.

### Step 2 — Connect to your server 💻 ➜ ☁️

Your VPS provider gave you an IP address and (usually) a root password or key. From your laptop:

```bash
ssh root@YOUR-SERVER-IP
```

Replace `YOUR-SERVER-IP` with your real IP. Type `yes` if it asks about a fingerprint. **You are now "inside" the server** — every command from here runs on the server.

### Step 3 — Download and run the script ☁️

Now that you're on the server, grab the script and run it:

```bash
# Install git if it's missing (harmless if already there)
sudo apt update && sudo apt install -y git

# Download the script
git clone https://github.com/MUKE-coder/vps-harden.git
cd vps-harden
chmod +x vps-harden.sh

# Run it
sudo ./vps-harden.sh
```

The script will ask you a few simple questions:
- A username for your new account (e.g. `deploy`)
- An SSH port (just press Enter to keep the suggested one)
- Your SSH **public** key — paste the line you copied in Step 1
- Whether to install Dokploy — type `y` or `n`

Then it does its work and prints your security score.

### Step 4 — ⚠️ TEST YOUR NEW LOGIN BEFORE CLOSING ANYTHING ⚠️

This is the most important step. The script changed how you log in. You must prove the new way works **before** you disconnect, or you could lock yourself out of your own server.

**Leave your current server connection open.** Open a **brand-new terminal window on your laptop** 💻 and try the new login:

```bash
ssh -p YOUR-SSH-PORT YOUR-NEW-USERNAME@YOUR-SERVER-IP
```

(The script prints this exact command for you at the end — copy it from there.)

- ✅ **If it works:** great! You can now close the old window. You're done.
- ❌ **If it fails:** don't panic. Go back to your **still-open** first window and you can fix it. This is exactly why we keep it open.

---

## Reaching Dokploy (if you installed it)

For safety, Dokploy's control panel is **not** exposed to the public internet. You reach it through a secure tunnel from your laptop:

```bash
ssh -p YOUR-SSH-PORT -L 3000:localhost:3000 YOUR-USERNAME@YOUR-SERVER-IP
```

Leave that running, then open **http://localhost:3000** in your laptop's browser. Create your account (the first one becomes admin) and turn on two-factor authentication.

---

## Checking your security later

Run this **on the server** anytime to re-check your score (it only looks, it changes nothing):

```bash
cd vps-harden
sudo ./vps-harden.sh --audit-only
```

You'll see something like:

```
============================================================
SECURITY SCORE: 92/100  (A - Excellent)
============================================================
```

Aim for an **A (90+)**. A full report is also saved on the server at `/root/vps-harden-report-<date>.txt`.

---

## Options (for later, once you're comfortable)

| Command | What it does |
|---------|--------------|
| `sudo ./vps-harden.sh` | Normal run, asks you questions |
| `sudo ./vps-harden.sh --audit-only` | Just check the score, change nothing |
| `sudo ./vps-harden.sh --no-dokploy` | Harden the server but skip Dokploy |
| `sudo ./vps-harden.sh --help` | Show help |

To get newer versions later, run `git pull` inside the `vps-harden` folder on the server.

---

## Requirements

- A fresh Ubuntu 22.04 / 24.04 or Debian server (works best on a clean one)
- The ability to SSH into it (your provider gives you this)

---

## A few honest notes

- This is a strong **starting point**, not a magic shield. Keep your apps updated and make backups.
- Always feel free to read the script before running it — every part is commented in plain language.
- It's built for Ubuntu/Debian. On other systems it'll warn you and behaviour isn't tested.

## Contributing

Found a bug or have an idea? Open an issue or pull request — beginners welcome.

## License

MIT
