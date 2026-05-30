# vps-harden

> One simple script to secure a brand-new Ubuntu/Debian VPS — and optionally install [Dokploy](https://dokploy.com). It cleans up your server's security, then gives you a **0–100 score** so you can see how safe it is.

**Made for total beginners.** If all you have is your server's **IP address** and **root password** from Contabo (or Hetzner, DigitalOcean, etc.), this guide is for you. You don't need to know anything about SSH keys — the script can make one for you.

---

## 🛑 The one thing to understand before anything else

There are **two different computers** involved. Mixing them up is the #1 beginner mistake:

| | What it is | Your role |
|---|---|---|
| 💻 **Your laptop / PC** | The computer in front of you right now | You type commands here to control the server |
| ☁️ **Your VPS (server)** | The remote machine you rented | **This is where the script runs** |

👉 You connect *from* your laptop *to* the server, then run the script **on the server**.

Think of it like a phone call: your laptop is *you*, the server is the *person you called*. The work happens on their side — you're just talking to them through the call. Below, every step is marked 💻 (do on your laptop) or ☁️ (do on the server) so you always know where you are.

---

## Why bother?

The second your new server goes live, bots across the internet start trying to break into it — guessing passwords, scanning for open doors, 24/7. A fresh server is wide open. This script locks the doors before they get in.

---

## Step-by-step (from "I just got my server" to "it's secured")

### Step 1 — Open a terminal on your laptop 💻

- **Windows:** press the Start button, type **PowerShell**, open it.
- **Mac:** press `Cmd + Space`, type **Terminal**, open it.
- **Linux:** open your **Terminal** app.

### Step 2 — Connect to your server 💻 ➜ ☁️

Contabo gave you an **IP address** and a **root password**. In the terminal, type (replace `YOUR-SERVER-IP` with your real IP):

```bash
ssh root@YOUR-SERVER-IP
```

- If it asks `Are you sure you want to continue connecting?`, type `yes` and press Enter.
- It will ask for your **root password** — type it (you won't see anything as you type, that's normal) and press Enter.

✅ You're now **inside the server**. Everything you type from here runs on the server.

### Step 3 — Download and run the script ☁️

Copy and paste these lines one block at a time:

```bash
# Make sure git is available (safe to run even if it already is)
sudo apt update && sudo apt install -y git

# Download the script
git clone https://github.com/MUKE-coder/vps-harden.git
cd vps-harden
chmod +x vps-harden.sh

# Run it
sudo ./vps-harden.sh
```

The script asks you a few easy questions:

- **A username** for your everyday account — type something simple like `deploy`.
- **An SSH port** — just press Enter to accept the suggestion.
- **An SSH key** — here you have two choices:
  - If you've never made one, **just leave it blank and press Enter** → the script makes a key *for you*. ⭐ (recommended for beginners)
  - If you already have a key on your laptop, paste your public key instead.
- **Install Dokploy?** — type `y` for yes or `n` for no.

### Step 4 — If the script made a key for you: save it to your laptop ☁️ ➜ 💻

If you left the key blank, the script created one on the server and showed you instructions. You must copy the **private key** down to your laptop — it's your only way back in.

Open a **new terminal window on your laptop** 💻 and run the line the script showed you (it looks like this):

```bash
scp root@YOUR-SERVER-IP:/root/vps-harden-keys/deploy_key ~/.ssh/deploy_key
chmod 600 ~/.ssh/deploy_key
```

(`deploy` will be whatever username you chose. On Windows PowerShell, `scp` works the same way.)

> Skipped the key and let the script generate one? This step is required. If you pasted your own key, you can skip it.

### Step 5 — ⚠️ TEST YOUR NEW LOGIN BEFORE CLOSING ANYTHING ⚠️

This is the most important step. The script changed how you log in. You must prove the new way works **before** disconnecting, or you could lock yourself out of your own server.

**Keep your original server window open.** In the **new laptop terminal** 💻, try the new login. The script prints the exact command for you — it looks like one of these:

```bash
# If the script generated a key for you:
ssh -i ~/.ssh/deploy_key -p YOUR-SSH-PORT deploy@YOUR-SERVER-IP

# If you pasted your own key:
ssh -p YOUR-SSH-PORT deploy@YOUR-SERVER-IP
```

- ✅ **If it logs in:** great! You can now close the old window. Done — your server is secured.
- ❌ **If it fails:** don't panic. Go back to your **still-open** first window and fix it (or re-run the script). That's exactly why we kept it open.

---

## Reaching Dokploy (if you installed it)

For safety, Dokploy's control panel is **not** open to the public internet. You reach it through a private tunnel. On **your laptop** 💻:

```bash
ssh -i ~/.ssh/deploy_key -p YOUR-SSH-PORT deploy@YOUR-SERVER-IP -L 3000:localhost:3000
```

(Drop the `-i ~/.ssh/deploy_key` part if you used your own key.) Leave that window running, then open **http://localhost:3000** in your laptop's browser. Create your account (first user becomes admin) and turn on two-factor authentication.

---

## Checking your security score later

Run this **on the server** ☁️ anytime — it only looks, it changes nothing:

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

A warning gives half points; a failure gives zero.

---

## Options (for later, once you're comfortable)

| Command | What it does |
|---------|--------------|
| `sudo ./vps-harden.sh` | Normal run, asks you questions |
| `sudo ./vps-harden.sh --audit-only` | Just check the score, change nothing |
| `sudo ./vps-harden.sh --no-dokploy` | Secure the server but skip Dokploy |
| `sudo ./vps-harden.sh --help` | Show help |

Get newer versions later with `git pull` inside the `vps-harden` folder.

---

## Requirements

- A fresh Ubuntu 22.04 / 24.04 or Debian server
- Your server's IP address and root password (that's all you need)

---

## Honest notes

- This is a strong **starting point**, not a magic shield. Keep your apps updated and make backups.
- The auto-generated key is convenient and safe, but treat the private key file like a password — never share it.
- Feel free to read the script first; every part is commented in plain language.
- Built and tested for Ubuntu/Debian.

## Contributing

Beginners welcome — open an issue or pull request.

## License

MIT
