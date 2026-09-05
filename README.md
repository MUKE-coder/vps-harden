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
  ⚠️ **Remember exactly what you type.** Every file and command later is named
  after it: pick `dev` and your key is `dev_key`, not `deploy_key`.
- **An SSH port** — press Enter to stay on the normal port 22. If you type
  something else (or `auto`), **write it down** — you must add `-p THAT-PORT` to
  every `ssh` and `scp` command from then on. The script prints it in a box, and
  saves it to `/root/vps-harden-login.txt`.
- **An SSH key** — here you have two choices:
  - If you've never made one, **just leave it blank and press Enter** → the script makes a key *for you*. ⭐ (recommended for beginners)
  - If you already have a key on your laptop, paste your public key instead.
- **A password** for the account — leave it blank and the script generates a strong one and **prints it at the end**. Save it: SSH stays key-only, but this password lets you log in through your provider's **web console** if you ever lose the key.
- **Install Dokploy?** — type `y` for yes or `n` for no.

### Step 4 — Get your private key onto your laptop ☁️ ➜ 💻

> 🚩 **Your files are named after the username YOU chose.** Every example below
> uses `deploy`. If you typed `dev`, then everywhere you see `deploy` you must
> read `dev` — the key is `dev_key`, the login is `dev@...`. Copying these lines
> literally is the single most common way to get stuck.

If you left the key blank, the script generated one **on the server** and, at the
very end of its run, **printed the whole key on screen**. That printed block is
how you get it — copy it out of your terminal.

Scroll up to the block that starts:

```
>>> YOUR PRIVATE KEY - COPY THIS TO YOUR LAPTOP NOW <<<
```

Select everything from `-----BEGIN OPENSSH PRIVATE KEY-----` to
`-----END OPENSSH PRIVATE KEY-----` (both lines included) and copy it. Then, on
your **laptop** 💻:

**Mac, Linux, or Windows with Git Bash / WSL:**

```bash
mkdir -p ~/.ssh
nano ~/.ssh/deploy_key      # paste, then Ctrl+O, Enter, Ctrl+X
chmod 600 ~/.ssh/deploy_key
```

**Windows with PowerShell** (`chmod` does not exist there — Windows uses `icacls`):

```powershell
mkdir $HOME\.ssh -Force
notepad $HOME\.ssh\deploy_key    # paste, then save and close
icacls $HOME\.ssh\deploy_key /inheritance:r /grant:r "$env:USERNAME:R"
```

<details>
<summary>Prefer to download it as a file with <code>scp</code>?</summary>

You can, but **only while the script is still running** — during the pause right
after it creates the key, from a second terminal:

```bash
scp root@YOUR-SERVER-IP:/root/vps-harden-keys/deploy_key ~/.ssh/deploy_key
```

Once the script finishes, that command **cannot work**: root SSH login is now
disabled and the port may have moved. Copy/paste from the terminal always works.

</details>

### Step 5 — ⚠️ TEST YOUR NEW LOGIN BEFORE CLOSING ANYTHING ⚠️

This is the most important step. The script changed how you log in. You must
prove the new way works **before** disconnecting, or you could lock yourself out
of your own server.

You need **three** things, all printed in a box at the end of the run:

```
    +--------------------------------------------------+
    |  SERVER   : 203.0.113.77                         |
    |  USERNAME : deploy                               |
    |  SSH PORT : 22                                   |
    +--------------------------------------------------+
```

They are also saved on the server at `/root/vps-harden-login.txt`.

**Keep your original server window open.** In a **new laptop terminal** 💻:

```bash
# If the script generated a key for you:
ssh -i ~/.ssh/deploy_key -p YOUR-SSH-PORT deploy@YOUR-SERVER-IP

# If you pasted your own key:
ssh -p YOUR-SSH-PORT deploy@YOUR-SERVER-IP
```

(PowerShell users: write `$HOME\.ssh\deploy_key` instead of `~/.ssh/deploy_key`.)

- ✅ **If it logs in:** great! You can now close the old window. Done — your server is secured.
- ❌ **If it fails:** don't panic. Go back to your **still-open** first window and run
  `sudo ./vps-harden.sh --info`. It prints your port, your username and how to
  recover your key. That's exactly why we kept the window open.
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

## 🚨 Emergencies & "uh oh" situations

Things go wrong. Here are the scenarios beginners actually hit, and exactly how to fix each one. Most are recoverable — don't panic.

### 😱 My laptop was stolen / lost

This is serious: whoever has your laptop has your **private key**, which means they can log into your server as you. Act fast.

**If you can still get into your server another way** (e.g. from a different computer, or your provider's web console — see below), do this immediately:

```bash
# 1. Log into the server, then remove the stolen key from your account
nano ~/.ssh/authorized_keys
# Delete the line for the compromised key, save with Ctrl+O then Enter, exit with Ctrl+X

# 2. Make a brand-new key on your SAFE computer (see "I lost my key" below),
#    then add its PUBLIC key to the server:
echo "ssh-ed25519 AAAA...your-NEW-public-key... you@newlaptop" >> ~/.ssh/authorized_keys

# 3. As a safety net, also change passwords and check who's logged in:
sudo passwd deploy        # change your user's password
who                       # see active sessions
sudo lastlog              # see recent logins
```

If you genuinely can't get in at all, use your **provider's web console** (next section) to do the same thing. When in doubt on a server holding anything important, the safest move is to wipe and rebuild it, then re-run this script — a stolen key plus your server IP is enough for an attacker to have already gotten in.

> **Prevention:** put a passphrase on your key (`ssh-keygen -p -f ~/.ssh/deploy_key`), and use full-disk encryption on your laptop (BitLocker on Windows, FileVault on Mac). With both, a stolen laptop is far less useful to a thief.

### 🔑 I lost / deleted my private key (or it got corrupted)

Your private key is gone, so you can't log in with it anymore. You need another way in, then you install a fresh key.

**Your rescue door is your provider's web console.** Contabo, Hetzner, DigitalOcean, etc. all give you a browser-based terminal that connects to the server screen *directly*, bypassing SSH entirely. In Contabo it's under your **VPS control panel → "VNC / Web Console" (or "Rescue")**. Log in there with your **root password**.

Once you're in via the console:

```bash
# Make a NEW key. On your laptop:
ssh-keygen -t ed25519 -f ~/.ssh/deploy_key_new

# Show the new PUBLIC key on your laptop and copy it:
cat ~/.ssh/deploy_key_new.pub

# Back in the server console, paste it into your account:
echo "PASTE-YOUR-NEW-PUBLIC-KEY-HERE" >> /home/deploy/.ssh/authorized_keys
```

Now you can SSH in normally with the new key. (If you never want to deal with this again, you can also temporarily re-enable password login from the console — see "I'm fully locked out" below.)

### 🚪 "Permission denied (publickey)" when I try to log in

SSH found your account but rejected your key. Common causes, most likely first:

- **You used `deploy` from the docs but named your user something else.** If you
  typed `dev` at the prompt, your login is `dev@IP` and your key is `dev_key`.
  Check with `ls /home` on the server.
- **The key never made it to your laptop.** An `scp` that printed *"No such file
  or directory"* copied nothing, and the `chmod` after it failed too. Check on
  your laptop: `ls -l ~/.ssh/` — is the key there, and is it non-empty?
- **Wrong key file.** Make sure you're pointing at the right one: `ssh -i ~/.ssh/deploy_key -p PORT deploy@IP`.
- **Wrong permissions on your laptop.** SSH refuses keys that aren't locked down. Fix it on your laptop: `chmod 600 ~/.ssh/deploy_key`.
- **Wrong username.** It's your created user (e.g. `deploy`), not `root` (root login is disabled on purpose).
- **The public key never got onto the server.** Use the web console to check `/home/deploy/.ssh/authorized_keys` actually contains your key.

### ⏱️ "Connection refused" or "Connection timed out"

- **Wrong port.** The script moved SSH off port 22. Add `-p YOUR-PORT` to your command. Forgot the port? Check it from the web console: `sudo sshd -T | grep -i '^port'`.
- **Firewall / SSH not running.** From the web console: `sudo systemctl status ssh` and `sudo ufw status`.
- **Wrong IP.** Double-check the server IP from your provider's dashboard.

### 🔒 I'm fully locked out (no key, can't SSH at all)

Don't reinstall yet. Use the **provider's web console** (the VNC/rescue terminal in your dashboard) — it doesn't need SSH or a key, just your root password. Once inside, temporarily turn password login back on so you can get in normally and fix things:

```bash
sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/00-hardening.conf
sudo systemctl restart ssh
```

Log in with your password, add a fresh key (see above), then turn password login back off and restart SSH again.

### 🙈 I accidentally pushed my private key to GitHub (or shared it)

Treat it as compromised, exactly like the stolen-laptop case: remove that key from `~/.ssh/authorized_keys` on the server, generate a new key, and add the new one. Deleting the GitHub commit is **not** enough — assume bots already grabbed it. **Never** commit anything from your `.ssh` folder; only ever share files ending in `.pub`.

### 🤔 I forgot my username / SSH port / what I chose

Log into the server any way you can — a still-open window, or your provider's
web console — and run:

```bash
cd ~/vps-harden && sudo ./vps-harden.sh --info
```

It prints your IP, SSH port, sudo users, and the exact `ssh` command for each
key it generated. It works even with SSH fully locked down and no internet.

The same details are saved at `/root/vps-harden-login.txt`:

```bash
sudo cat /root/vps-harden-login.txt
```

Doing it by hand instead:

```bash
ls /home                                 # lists your usernames
sudo sshd -T | grep -i '^port'           # shows the SSH port
```

### 🌐 Dokploy won't load at http://localhost:3000

- Make sure your **tunnel** is running in another window: `ssh -i ~/.ssh/deploy_key -p PORT deploy@IP -L 3000:localhost:3000`. The tunnel must stay open while you use Dokploy.
- Don't try `http://your-server-ip:3000` directly — port 3000 is intentionally closed to the public.
- Check it's actually running, on the server: `docker ps | grep dokploy`.

### 🚫 Fail2ban banned my own IP address

If you fat-fingered your login too many times, Fail2ban may temporarily block you. Get in via the web console and unban yourself:

```bash
sudo fail2ban-client status sshd          # see banned IPs
sudo fail2ban-client set sshd unbanip YOUR-IP-ADDRESS
```

Bans also expire on their own (24h for SSH by default).

### 🔁 `sudo` asks for a password I don't have

Recent versions give your new user **passwordless sudo** *and* set a real
account password (shown once at the end of the run, and saved in
`/root/vps-harden-login.txt`). If you're on an older run, or you lost the
password, set a new one from the web console as root: `passwd deploy`.

That password is for the **web console and `su` only** — SSH stays key-only, so
it will not get you in over SSH.

---

## Options (for later, once you're comfortable)

| Command | What it does |
|---------|--------------|
| `sudo ./vps-harden.sh` | Normal run, asks you questions |
| `sudo ./vps-harden.sh --info` | **Forgot your port / username / key?** Prints them |
| `sudo ./vps-harden.sh --audit-only` | Just check the score, change nothing |
| `sudo ./vps-harden.sh --no-dokploy` | Secure the server but skip Dokploy |
| `sudo ./vps-harden.sh --auto-port` | Move SSH to a random free high port |
| `sudo ./vps-harden.sh --yes` | Non-interactive; takes answers from env vars |
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
