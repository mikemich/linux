# Bastion Linux

A minimal, Kali-style distribution built for **defensive** security only:
network monitoring, intrusion detection, hardening, file integrity,
malware scanning and forensics. It has no exploitation, password-cracking or
attack tooling.

Bastion is Debian 13 (trixie) built with `live-build`, the same toolchain Kali
uses. It runs a lean, hardened kernel built from this repository. The result
is one hybrid ISO that boots as a live system from USB or DVD and also
contains the Debian installer.

## What you get at first boot

| Area | Tools | Default state |
|------|-------|---------------|
| Network IDS | Suricata + ET Open rules (in the image), suricata-update | **running**, monitors the default-route interface |
| Firewall / IPS | nftables (drop all inbound), fail2ban | **running** |
| Auditing | auditd with a focused ruleset, AppArmor, Landlock, Yama | **running** (Debian loads AppArmor profiles only on installed systems, not live media) |
| Integrity | AIDE, rkhunter, chkrootkit, unhide, debsums | baseline built at first boot of an installed system |
| Malware | ClamAV (freshclam on), YARA | on-demand scan; `clamd` off (it uses ~1 GB of RAM) |
| Hardening / compliance | Lynis, OpenSCAP + SCAP Security Guide, needrestart, unattended-upgrades, usbguard, pwquality | security updates installed automatically |
| Traffic analysis | tcpdump, tshark, termshark, ngrep, p0f, nfdump, arpwatch, iftop, nethogs, conntrack | on demand |
| Forensics / IR | Sleuth Kit, ewf-tools, dc3dd, hashdeep, ssdeep, testdisk, foremost, exiftool, binwalk | on demand |
| Observability | bpftrace, bpftool (kernel ships BTF), sysstat, iotop-c, lnav, jq | on demand |
| Optional desktop | Xfce, LightDM, Wireshark, NetworkManager | only with `--desktop` |

## Your own tools

Your own projects from `bastion/tools.list` are built into the image as well:

| Tool | What it does | How to run it |
|------|--------------|---------------|
| [antirai](https://github.com/mikemich/antirai) | Finds infected devices (Mirai, worms, botnets, cryptojacking) and LAN attacks such as ARP, DHCP and DNS spoofing | `sudo antirai` |
| [dfndr](https://github.com/mikemich/dfndr) | One security dashboard and score for your network, with antirai as its engine | `sudo dfndr` → http://127.0.0.1:8770 |
| [Spctr](https://github.com/mikemich/Spctr) (Spectre) | Passive device intelligence and anomaly mesh, with its web UI built into the binary | `bastion enable spectre` → http://127.0.0.1:7777 |
| [lightsysmon](https://github.com/mikemich/lightsysmon) | Lightweight live system monitor | `lightsysmon watch` |
| swissapps, defmap | Extra dfndr checks, and "who is scanning me" detection | Built when found locally (see below) |

`bastion tools` lists the tools installed in an image.

- The Python tools share one virtualenv in `/opt/bastion-tools`, built on
  Debian's scapy and textual, so the build downloads nothing from PyPI.
- Spectre runs as an unprivileged service with only the packet-capture
  capability. Its dashboard is local-only, and its honeypot and active
  response are off.

Building them:

- Repositories are cloned at build time. For private repositories, set
  `GITHUB_TOKEN` to a token that can read them.
- Projects that exist only on your machine (`swissapps`, `defmap`) are used
  when you point `BASTION_TOOLS_DIR` at the folder that holds your checkouts.
  A checkout found there is also used in place of cloning:

  ```
  sudo GITHUB_TOKEN=ghp_... BASTION_TOOLS_DIR=~/Documents/repos ./bastion/build.sh
  ```

- To add another tool, add a line to `bastion/tools.list`. Kinds are
  `python`, `cargo` and `spctr`.
- `--no-tools` builds without your tools.

## The bastion command

Everything is driven by one command:

```
bastion                 # status: services, sensor, rules, baseline, memory
bastion alerts 50       # latest Suricata alerts
bastion audit           # Lynis + rkhunter + chkrootkit + debsums
bastion scan /srv       # ClamAV scan
bastion tools           # your own tools in this image
bastion update          # IDS rules, AV signatures, packages
bastion sensor enp3s0   # pin Suricata to a SPAN/TAP port (or "auto")
bastion enable ssh      # also: clamd, usbguard, suricata, spectre (and disable ...)
bastion baseline        # rebuild the AIDE and rkhunter baselines
```

A `bastion-daily.timer` updates rules and runs AIDE and rkhunter checks.

## Why it's light

- **Kernel** (`kernel/configs/bastion.config`): starts from `x86_64_defconfig`
  plus the upstream `hardening.config` fragments. It drops sound, media,
  staging, legacy buses and protocols, and x32. It keeps what defensive
  tooling needs: audit, AppArmor/Landlock/BPF-LSM, eBPF with BTF, kprobes and
  uprobes, nftables with NFQUEUE, AF_PACKET/AF_XDP, WireGuard and TPM. It also
  covers the common NVMe/SATA/USB storage, Intel/Realtek/Broadcom/Mellanox
  NICs, Intel/Atheros/MediaTek/Realtek Wi-Fi, i915/amdgpu, and
  KVM/VMware/Hyper-V guests. Modules are signed and zstd-compressed.
- **Userspace**: debootstrap `minbase`, no recommended packages, and
  systemd-networkd/resolved + iwd instead of NetworkManager. Journald is the
  only logger (no rsyslog). There's no cron daemon (systemd timers do that
  job), and squashfs uses zstd.
- **Memory**: zram swap (zstd, 50% of RAM), earlyoom, and Suricata's `low`
  detection profile. ClamAV's resident daemon is off, and AV signatures
  aren't downloaded into RAM on live boots.
- **Boot**: `systemd-networkd-wait-online`, `man-db.timer` and
  `e2scrub_all.timer` are disabled, and GRUB waits 1 second.

## Building

You need about 25 GB of free disk space and root access. Build on a Debian 13
amd64 host:

```
sudo ./bastion/build.sh --install-deps            # custom kernel, console only
sudo ./bastion/build.sh --desktop                 # + minimal Xfce desktop
sudo ./bastion/build.sh --kernel stock            # Debian's signed kernel
```

On any other Linux host with Docker:

```
./bastion/build-in-docker.sh            # same options as build.sh
```

The ISO and its SHA-256 are written to `bastion/out/`. Write it to USB with:

```
sudo dd if=bastion/out/bastion-1.0-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

### Custom vs stock kernel

`--kernel custom` (the default) builds this tree and ships it as
`linux-image-<version>-bastion`. Debian hasn't signed it, so **turn off
UEFI Secure Boot** to boot it. On Secure Boot machines, or hardware the lean
config doesn't cover, use `--kernel stock`. Every other part of the image is
the same.

To build just the kernel:

```
make x86_64_defconfig hardening.config bastion.config
make -j$(nproc) bindeb-pkg
```

## Booting and installing

- **Live**: pick "Live" in the boot menu. User `bastion`, password `live`
  (it has sudo). Suricata and the firewall are already running. Changes are
  kept in RAM only.
- **Install**: pick "Install" in the boot menu. This is the standard Debian
  text installer. On the first boot of the installed system,
  `bastion-firstboot` builds the AIDE and rkhunter baselines at idle priority.
  ClamAV signatures download in the background.

Hostname defaults to `bastion`. Root login is disabled; the user you create
gets sudo. SSH is installed but stays off until you run `bastion enable ssh`.
Sign-in is key-only.

## Customising

- Add or remove packages: `bastion/live/config/package-lists/*.list.chroot`
- Change system config: files under
  `bastion/live/config/includes.chroot_after_packages/` are copied over the
  root filesystem
- Change build-time logic: `bastion/live/config/hooks/normal/*.hook.chroot`
- Change kernel options: `kernel/configs/bastion.config`
- Add firewall rules on a running system: drop `*.nft` files in
  `/etc/nftables.d/`

Common add-ons that aren't in Debian main: Zeek (OpenSUSE OBS repository),
osquery, Wazuh agent, Velociraptor. Add their apt repository in
`config/archives/` and the package names to a list.
