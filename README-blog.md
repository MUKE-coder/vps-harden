# Securing Your First VPS (and Installing Dokploy) — A Beginner's Guide

If you've just rented your first VPS from somewhere like Contabo or Hetzner and you're planning to deploy apps with [Dokploy](https://dokploy.com), there's something nobody warns you about: **the moment your server gets a public IP address, bots on the internet start trying to break into it.** Within minutes. They guess passwords, scan for open ports, and probe for known weaknesses, around the clock.

A fresh server is like a house with every door and window unlocked. This guide walks you through `vps-harden.sh` — a single, friendly script that locks all those doors, optionally installs Dokploy, and then gives you a **security score out of 100** so you can actually *see* that your server is safe.

This is written for beginners. If you've never hardened a server before, you're in the right place.

---

## First, the one thing that confuses everyone

There are **two separate computers** in this whole process, and keeping them straight is the key to not getting lost:

- 💻 **Your laptop** — the computer physically in front of you.
- ☁️ **Your server (VPS)** — the remote machine you rented. You can't touch it; you control it over the internet.

**The script runs on the SERVER, not on your laptop.** What you do is connect *from* your laptop *to* the server using a tool called SSH, and then you run the script while you're "inside" that connection.

A helpful way to picture it: it's like a phone call. Your laptop is *you*, the server is the *person you called*. The work happens on their end — you're just talking to them through the call. Throughout this guide I'll mark each step with 💻 (do this on your laptop) or ☁️ (do this on the server) so it's always clear where you are.

---

## TL;DR for the impatient

```bash
# 💻 On your laptop: connect to the server
ssh root@YOUR-SERVER-IP

# ☁️ Now on the server: download and run
git clone https://github.com/MUKE-coder/vps-harden.git
cd vps-harden
chmod +x vps-harden.sh
sudo ./vps-harden.sh
```

Answer a few questions, then **don't close anything** until you've tested your new login (explained below). That last part matters — skip it and you can lock yourself out.

---

## What the script actually does (in plain English)

You don't need to understand every detail, but here's the gist of what's happening to your server:

1. **Installs security updates** — and sets it up to keep installing them automatically forever. Most break-ins exploit old bugs that already have fixes; this closes that gap.
2. **Creates a normal user for you** — so you stop logging in as "root," the all-powerful account that's dangerous to use day-to-day.
3. **Locks down SSH** — the doorway you use to connect. After this, only *you*, holding your secret key, can get in. No passwords, no root login.
4. **Turns on a firewall** — blocks every incoming connection except the few you actually need.
5. **Adds Fail2ban** — automatically bans any IP address that keeps guessing your password.
6. **Fixes a sneaky Docker problem** — Docker (which Dokploy uses) secretly bypasses your firewall and can expose your apps to the world. The script patches this.
7. **Optionally installs Dokploy** — the dashboard you'll use to deploy your apps. Totally optional; you can say no.
8. **Hardens the system internals** — sensible kernel and memory settings that block common attacks.
9. **Scores your security out of 100** — so you finish with proof that your server is locked down.

Everything the script changes is commented in the source in plain language, so you can read along if you're curious.

---

## The full walkthrough

### Step 1 — Make your SSH key 💻

An SSH key is a pair of files: a **public** key (safe to share, goes on the server) and a **private** key (a secret, stays on your laptop). Together they let you log in securely without ever typing a password — much safer than a password a bot could guess.

On **your laptop**, open a terminal and run:

```bash
ssh-keygen -t ed25519 -C "you@laptop"
```

Press Enter at each question to accept the defaults. When it's done, display your **public** key:

```bash
cat ~/.ssh/id_ed25519.pub
```

It prints one long line starting with `ssh-ed25519`. **Copy that entire line** — you'll paste it into the script shortly. Leave this terminal open.

> Already made a key before? You can skip the `ssh-keygen` part and just run the `cat` command to copy your existing public key.

### Step 2 — Connect to your server 💻 ➜ ☁️

Your VPS provider emailed you an **IP address** and login details for your server. From your laptop's terminal, connect like this (swap in your real IP):

```bash
ssh root@YOUR-SERVER-IP
```

If it asks about a "fingerprint," type `yes` and press Enter. You may be asked for the root password your provider gave you.

🎉 You're now **inside the server**. Every command you type from here on runs on the server, not your laptop.

### Step 3 — Download and run the script ☁️

You're on the server now. First make sure `git` is installed (this is harmless if it already is):

```bash
sudo apt update && sudo apt install -y git
```

Now download the script and run it:

```bash
git clone https://github.com/MUKE-coder/vps-harden.git
cd vps-harden
chmod +x vps-harden.sh
sudo ./vps-harden.sh
```

The script will ask you some easy questions:

- **A username** for your new account — something simple like `deploy`.
- **An SSH port** — just press Enter to accept the suggestion (using a non-standard port quietly hides you from most bots).
- **Your SSH public key** — paste the line you copied in Step 1.
- **Install Dokploy?** — type `y` for yes or `n` for no.

It'll then chug away for a few minutes (updating, configuring, maybe installing Dokploy) and finish by printing your **security score**.

### Step 4 — ⚠️ The step you must NOT skip ⚠️

The script just changed how you log in to your server. Before you disconnect, you have to **prove the new login works** — otherwise, if something went wrong, you'd have no way back in. This is the single most common way beginners accidentally lock themselves out.

Here's the safe way to test it:

1. **Keep your current server window open.** Don't touch it.
2. Open a **brand-new terminal window on your laptop** 💻.
3. Try logging in the new way. The script prints the exact command for you at the end — it looks like this:

```bash
ssh -p YOUR-SSH-PORT YOUR-USERNAME@YOUR-SERVER-IP
```

- ✅ **If you get in:** perfect. You can now safely close the old window. You're finished and your server is secured.
- ❌ **If it fails:** stay calm. Switch back to your **still-open** original window — you never lost access — and you can investigate or re-run the script. This is exactly why we kept it open.

---

## How to reach Dokploy (if you installed it)

You might expect to just visit `http://your-server-ip:3000` to see the Dokploy dashboard. The script deliberately **blocks that**, because leaving an admin panel open to the whole internet is asking for trouble.

Instead, you create a private, encrypted tunnel from your laptop to the server. On **your laptop** 💻:

```bash
ssh -p YOUR-SSH-PORT YOUR-USERNAME@YOUR-SERVER-IP -L 3000:localhost:3000
```

Leave that window running. Then open **http://localhost:3000** in your laptop's browser. The dashboard appears — but only *you* can reach it, because it travels through your secure SSH connection. Create your admin account (the first user to sign up becomes the admin) and turn on two-factor authentication for good measure.

---

## Checking your security score anytime

Your security isn't "set and forget" — updates pile up, things drift. You can re-check your score whenever you like. On the **server** ☁️:

```bash
cd vps-harden
sudo ./vps-harden.sh --audit-only
```

The `--audit-only` part means it *only looks* and changes nothing. You'll see:

```
============================================================
SECURITY SCORE: 92/100  (A - Excellent)
============================================================
```

Aim for an **A (90 or above)**. Each item is scored and weighted:

| Check | Points |
|-------|-------:|
| Root login over SSH disabled | 10 |
| Password login disabled (key only) | 10 |
| Using a non-standard SSH port | 5 |
| Firewall turned on | 15 |
| Fail2ban running | 10 |
| Automatic security updates on | 10 |
| No updates pending | 10 |
| Kernel hardening applied | 5 |
| You have a non-root user | 5 |
| Docker firewall fix in place | 5 |

A warning gives you half the points; a failure gives zero. A detailed report is also saved on the server at `/root/vps-harden-report-<date>.txt`. Running it weekly (or on a schedule) is a good habit.

---

## Quick reference: the commands you'll actually use

All of these run **on the server**:

| Command | What it does |
|---------|--------------|
| `sudo ./vps-harden.sh` | The normal run — asks you questions, secures everything |
| `sudo ./vps-harden.sh --audit-only` | Just check the score, change nothing |
| `sudo ./vps-harden.sh --no-dokploy` | Secure the server but skip Dokploy |
| `sudo ./vps-harden.sh --help` | Show the help text |
| `git pull` | Get the newest version of the script later (run inside the `vps-harden` folder) |

---

## A few honest words before you go

- This script is a **strong starting point**, not a force field. Keep your apps updated, make backups, and don't reuse passwords.
- You can always read the script before running it — it's all commented in plain language, and reading code you're about to run as root is a great habit.
- It's built and tested for Ubuntu/Debian. On other systems it'll warn you, and results aren't guaranteed.

Secure the house before you move the furniture in. Harden first, deploy second — your future self will thank you.
