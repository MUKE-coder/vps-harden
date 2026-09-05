# Securing Your First VPS (and Installing Dokploy) — A Total Beginner's Guide

You just bought your first VPS from Contabo. You have two things: an **IP address** and a **root password**. That's it. You've heard you're supposed to "secure" and "harden" the server before putting your apps on it, but every tutorial assumes you already know what SSH keys are, what a firewall is, and a dozen other things nobody taught you.

This guide assumes none of that. If you can copy and paste, you can follow along. We'll use a single friendly script, `vps-harden.sh`, that locks down your server, optionally installs [Dokploy](https://dokploy.com), and — importantly — **can create your SSH key for you** so you don't have to figure that out on your own.

By the end, your server will be properly secured and you'll have a **security score out of 100** to prove it.

---

## Why this even matters

Here's the uncomfortable truth: the moment your new server gets a public IP address, automated bots start trying to break into it. Within minutes. They guess passwords, scan for open doors, and probe for weaknesses around the clock. A fresh, untouched server is like a house with every door and window unlocked in a bad neighborhood.

Hardening is just locking those doors. It's not optional, and it's not as hard as it looks.

---

## The one idea that trips everyone up

There are **two separate computers** in this whole process. Keeping them straight is the secret to not getting lost:

- 💻 **Your laptop** — the computer in front of you.
- ☁️ **Your server (VPS)** — the Contabo machine you rented, somewhere in a data center. You can't touch it; you control it over the internet.

**The script runs on the SERVER, not your laptop.** You connect *from* your laptop *to* the server, then run the script there.

Picture a phone call: your laptop is *you*, the server is the *person you called*. The work happens on their end — you're just talking to them through the call. Throughout this guide, each step is tagged 💻 (do this on your laptop) or ☁️ (do this on the server) so you're never unsure.

A quick word on **SSH keys**, since they scare beginners: an SSH key is just a pair of files that act like a lock and a key. The **public** part (the "lock") goes on your server. The **private** part (the "key") stays secret on your laptop. Together they let you log in without a password — which is far safer, because a bot can't guess a key the way it guesses passwords. The good news: **you don't have to create this yourself. The script will make it for you if you want.**

---

## The full walkthrough

### Step 1 — Open a terminal on your laptop 💻

A "terminal" is just a window where you type commands.

- **Windows:** click Start, type **PowerShell**, and open it.
- **Mac:** press `Cmd + Space`, type **Terminal**, and open it.
- **Linux:** open your **Terminal** app.

### Step 2 — Connect to your server 💻 ➜ ☁️

Find the **IP address** and **root password** Contabo sent you. In your terminal, type this (replace `YOUR-SERVER-IP` with your actual IP):

```bash
ssh root@YOUR-SERVER-IP
```

A few things may happen:
- It might warn about a "fingerprint" the first time — type `yes` and press Enter.
- It asks for your **root password**. Type it and press Enter. **You won't see the characters as you type** — that's a security feature, not a bug. Just type it and hit Enter.

🎉 You're now **inside the server**. Every command from here runs on the server, not your laptop.

### Step 3 — Download and run the script ☁️

Paste these in, one block at a time:

```bash
# Make sure 'git' is installed (harmless if it already is)
sudo apt update && sudo apt install -y git

# Download the script
git clone https://github.com/MUKE-coder/vps-harden.git
cd vps-harden
chmod +x vps-harden.sh

# Run it
sudo ./vps-harden.sh
```

It'll ask you some simple questions:

- **A username** for your everyday account — keep it simple, like `deploy`.
  ⚠️ **Write down exactly what you type.** Everything later is named after it —
  choose `dev` and your key file is `dev_key`, and you log in as `dev@...`, not
  `deploy@...`.
- **An SSH port** — press Enter to stay on the normal port 22. If you type
  anything else (or `auto`), **write it down**: from then on every `ssh` and
  `scp` needs `-p THAT-PORT`. The script prints it in a box at the end and saves
  it to `/root/vps-harden-login.txt`, so it's recoverable if you miss it.
- **An SSH key** — this is the part beginners dread, but you have an easy way out:
  - **Never made a key? Just leave it blank and press Enter.** ⭐ The script generates one for you automatically and tells you exactly what to do next. This is the recommended path.
  - Already have a key on your laptop? Paste your public key instead.
- **Install Dokploy?** — `y` for yes, `n` for no.

The script then works for a few minutes and finishes by showing your security
score, your login details, and — if it made one for you — your private key.
**Don't close that window until you've finished Step 5.**

### Step 4 — Get your private key onto your laptop ☁️ ➜ 💻

> 🚩 **Stop and read this.** Every example below says `deploy`, because that's
> the username *we* picked. **The script names your files after the username
> YOU typed.** If you typed `dev`, your key is `dev_key` and your login is
> `dev@...`, and pasting `deploy_key` will fail with *"No such file or
> directory"*. This is the number one place people get stuck.

If you left the key blank in Step 3, the script created a key pair *on the
server*. The **private** half needs to come down to your laptop — it's your only
way to log back in.

The script prints the whole key on screen at the end of its run. Scroll up in
your terminal to the block that starts:

```
>>> YOUR PRIVATE KEY - COPY THIS TO YOUR LAPTOP NOW <<<
```

Select everything from `-----BEGIN OPENSSH PRIVATE KEY-----` through
`-----END OPENSSH PRIVATE KEY-----` — including both of those lines — and copy
it. Then, on your **laptop** 💻, save it into a file.

**Mac, Linux, or Windows with Git Bash / WSL:**

```bash
mkdir -p ~/.ssh
nano ~/.ssh/deploy_key      # paste, then Ctrl+O, Enter, Ctrl+X
chmod 600 ~/.ssh/deploy_key
```

`chmod 600` tells your laptop "this is a private key, keep it locked down" —
SSH refuses to use a key that anyone else on the machine can read.

**Windows with PowerShell:** there is no `chmod` on Windows, so use `icacls`:

```powershell
mkdir $HOME\.ssh -Force
notepad $HOME\.ssh\deploy_key    # paste, then save and close
icacls $HOME\.ssh\deploy_key /inheritance:r /grant:r "$env:USERNAME:R"
```

> **What about `scp`?** You *can* download the key as a file, but only **while
> the script is still running**, during the pause right after it makes the key:
> `scp root@YOUR-SERVER-IP:/root/vps-harden-keys/deploy_key ~/.ssh/deploy_key`.
> Once the script has finished, that command can no longer work — it has just
> disabled root SSH login and possibly moved the port. Copy/paste from your
> terminal always works, so that's the path we recommend.

> If you pasted your own existing key in Step 3, skip this step entirely — your
> key is already on your laptop.

### Step 5 — ⚠️ Test the new login BEFORE you close anything ⚠️

This is the step you must not skip. The script changed how you log in (new user,
maybe a new port, key instead of password). You need to **prove the new login
works while you still have a way back in**. Locking yourself out of a remote
server is the classic beginner disaster, and it's completely avoidable.

First, collect the **three facts** you need. The script prints them in a box at
the very end:

```
    +--------------------------------------------------+
    |  SERVER   : 203.0.113.77                         |
    |  USERNAME : deploy                               |
    |  SSH PORT : 22                                   |
    +--------------------------------------------------+
```

Missed it, or already scrolled past? They're saved on the server. Run either of
these **on the server** ☁️:

```bash
sudo cat /root/vps-harden-login.txt        # IP, username, port, key location
cd ~/vps-harden && sudo ./vps-harden.sh --info
```

Now, the safe way to test:

1. **Keep your original server window open.** Don't close it.
2. In a **new laptop terminal** 💻, try logging in the new way:

```bash
# If the script generated a key for you:
ssh -i ~/.ssh/deploy_key -p YOUR-SSH-PORT deploy@YOUR-SERVER-IP

# If you pasted your own key:
ssh -p YOUR-SSH-PORT deploy@YOUR-SERVER-IP
```

Replace `deploy` with **your** username, `YOUR-SSH-PORT` with the port from the
box, and `YOUR-SERVER-IP` with your IP. On PowerShell, write
`$HOME\.ssh\deploy_key` instead of `~/.ssh/deploy_key`.

- ✅ **If you get in:** perfect. You're done — close the old window whenever you like. Your server is secured.
- ❌ **If it fails:** stay calm and switch back to your **still-open** original window. You never lost access. Run `sudo ./vps-harden.sh --info` there to check the port and username you actually have, then try again. *This is exactly why we kept it open.*
---

## Opening the Dokploy dashboard (if you installed it)

You might expect to visit `http://your-server-ip:3000` to see Dokploy. The script deliberately **blocks that** — an admin panel open to the whole internet is an invitation to attackers.

Instead, you build a private, encrypted tunnel from your laptop to the server. On **your laptop** 💻:

```bash
ssh -i ~/.ssh/deploy_key -p YOUR-SSH-PORT deploy@YOUR-SERVER-IP -L 3000:localhost:3000
```

(Drop the `-i ~/.ssh/deploy_key` part if you used your own key.) Leave that window running, then open **http://localhost:3000** in your laptop's browser. The dashboard appears, but only *you* can reach it because it travels through your secure connection. Create your admin account (first signup becomes admin) and enable two-factor authentication.

---

## Checking your score anytime

Security drifts over time — updates pile up, things change. Re-check whenever you like. On the **server** ☁️:

```bash
cd vps-harden
sudo ./vps-harden.sh --audit-only
```

`--audit-only` means it *only looks* and changes nothing. You'll see:

```
============================================================
SECURITY SCORE: 92/100  (A - Excellent)
============================================================
```

Aim for an **A (90+)**. Each item is scored:

| Check | Points |
|-------|-------:|
| Root login over SSH disabled | 10 |
| Password login disabled (key only) | 10 |
| Non-standard SSH port | 5 |
| Firewall turned on | 15 |
| Fail2ban running | 10 |
| Automatic security updates on | 10 |
| No updates pending | 10 |
| Kernel hardening applied | 5 |
| Non-root user exists | 5 |
| Docker firewall fix in place | 5 |

A warning earns half the points; a failure earns zero. A full report is saved on the server at `/root/vps-harden-report-<date>.txt`. Running this weekly is a great habit.

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

- **You copied `deploy` out of this guide but named your user something else.**
  If you typed `dev`, you log in as `dev@IP` with `dev_key`. Confirm with
  `ls /home` on the server.
- **The key never actually reached your laptop.** If your `scp` printed *"No
  such file or directory"*, it copied nothing — and the `chmod` on the next line
  failed too. On your laptop, check: `ls -l ~/.ssh/`. Is the file there, and is
  its size more than 0?
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

Get onto the server any way you can — a still-open window, or the provider's web
console — and run:

```bash
cd ~/vps-harden && sudo ./vps-harden.sh --info
```

It reads the *live* configuration and prints your IP, your SSH port, your sudo
users, and the exact `ssh` command for every key it generated. It works even
when SSH is fully locked down.

The same details are written to a file every run:

```bash
sudo cat /root/vps-harden-login.txt
```

Or check by hand:

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

Current versions give your new user **passwordless sudo** *and* set a real
account password, which is printed once at the end of the run and saved to
`/root/vps-harden-login.txt`. If you're on an older run or lost it, set a new
one from the web console as root: `passwd deploy`.

That password is for the **web console and `su` only**. SSH stays key-only, so
it won't get you in over SSH.

---

## Quick reference

All of these run **on the server**:

| Command | What it does |
|---------|--------------|
| `sudo ./vps-harden.sh` | Normal run — asks questions, secures everything |
| `sudo ./vps-harden.sh --info` | **Forgot your port / username / key?** Prints them all |
| `sudo ./vps-harden.sh --audit-only` | Just check the score, change nothing |
| `sudo ./vps-harden.sh --no-dokploy` | Secure the server but skip Dokploy |
| `sudo ./vps-harden.sh --auto-port` | Move SSH to a random free high port |
| `sudo ./vps-harden.sh --yes` | Non-interactive; takes its answers from env vars |
| `sudo ./vps-harden.sh --help` | Show help |
| `git pull` | Get the newest version later (run inside the `vps-harden` folder) |

---

## A few honest words

- This script is a **strong starting point**, not a force field. Keep your apps updated, make backups, and never reuse passwords.
- The auto-generated key is safe and convenient — but treat that private key file like a password. Don't email it, don't paste it in chats, don't commit it to GitHub.
- You can always read the script before running it; it's commented in plain language, and reading code you're about to run as root is a great habit to build.
- It's built and tested for Ubuntu/Debian. On other systems it warns you, and results aren't guaranteed.

Secure the house before you move the furniture in. Harden first, deploy second — your future self will thank you.
