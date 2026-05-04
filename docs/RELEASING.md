# Releasing ConsoleRDP to GitHub

Step-by-step for pushing the first (or next) release from this working
copy to `github.com/billsecond/consolerdp`. Assumes you have `gh` (GitHub
CLI) and a GitHub account configured.

---

## One-time: create the GitHub repo and add the remote

If the repo doesn't exist yet:

```bash
cd /home/wdaugherty/Desktop/RDPForLinux

# Create the public repo on GitHub under your account.
gh auth login               # if not already signed in
gh repo create consolerdp \
    --public \
    --description "Windows-style RDP for Linux (Plasma 6 Wayland, single-seat takeover)" \
    --source . \
    --remote origin \
    --push=false            # we'll push manually after review
```

If you already created it via the web UI, just wire up the remote:

```bash
git remote add origin git@github.com:billsecond/consolerdp.git
```

---

## Every release

### 1. Make sure working tree is clean and tests pass

```bash
cd /home/wdaugherty/Desktop/RDPForLinux
python3 tests/smoke.py             # must print "Ran 10 tests ... OK"
git status --short                 # review what will be committed
```

### 2. Commit the source tree

```bash
git add -A
git commit -m "Release v1.0.0: initial public release

- Orchestrator daemon with RdpWatcher disconnect debounce + takeover
  auto-unlock-session.
- 8 krdp patches (NLA, fake-input auth, virtual-monitor stream size,
  pointer fixes, clipboard bridge, color range).
- 1 kpipewire patch (libx264 BT.601 color + correct H.264 VUI).
- Debian packaging + install.sh + uninstall.sh targeting Kubuntu
  26.04 LTS amd64."
```

### 3. Tag the release

```bash
git tag -a v1.0.0 -m "ConsoleRDP 1.0.0"
```

### 4. Push source + tag

```bash
git push origin main
git push origin v1.0.0
```

### 5. Build the release tarball

```bash
./scripts/mkrelease.sh
# produces: build/consolerdp-1.0.0.tar.gz  (~3.3 MB)
```

Verify the tarball contains the 7 .debs + install.sh:

```bash
tar -tzf build/consolerdp-1.0.0.tar.gz | grep -E '\.deb$|install\.sh$'
```

### 6. Create the GitHub Release + attach artefacts

```bash
gh release create v1.0.0 \
    build/consolerdp-1.0.0.tar.gz \
    scripts/install-remote.sh \
    --title "ConsoleRDP 1.0.0" \
    --notes-file docs/changelog.md
```

That uploads:

- `consolerdp-1.0.0.tar.gz` — the full bundle the one-liner downloads
- `install-remote.sh` — the curl-able bootstrap script

### 7. Verify the one-liner works from a fresh box

On a fresh Kubuntu 26.04 VM:

```bash
curl -fsSL https://github.com/billsecond/consolerdp/releases/latest/download/install-remote.sh | sudo bash
```

That should:

1. Download `consolerdp-1.0.0.tar.gz` from the Release.
2. Extract to `/opt/consolerdp-1.0.0/`.
3. Run `install.sh --user <SUDO_USER>`.
4. Finish with a green `consolerdp-doctor` report.

---

## Future / point releases

1. Bump `packaging/consolerdp/debian/changelog` with a new version (`dch -i`).
2. Rebuild the `.deb`: `cd build/consolerdp-<old> && dpkg-buildpackage ...`
   (or just `./scripts/buildall.sh` if you write one).
3. Replace the old `.deb` in `release/` with the new one.
4. Run `./scripts/mkrelease.sh` to make a new tarball.
5. `gh release create v<new> ...`

If the fix is in `krdp` or `kpipewire`, apply your new patch to
`patches/<pkg>/`, rebuild with `dpkg-buildpackage`, drop the `.deb`
into `release/`, and bump the `consolerdp` package's `Depends:` if you
need to force the new version.

---

## Troubleshooting push / release

**`gh release create` says "tag v1.0.0 not found"**
You forgot step 4. Run `git push origin v1.0.0`.

**Users report "404 downloading tarball"**
The release page has a specific URL schema. Make sure the tarball is
named exactly `consolerdp-<version>.tar.gz` and uploaded as a Release
Asset (not a repo Release Note).

**Users report the `.debs` inside the tarball have wrong dependencies**
You changed something in `patches/krdp/` or `patches/kpipewire/` but
forgot to rebuild the `.deb`. The `mkrelease.sh` script ships whatever
is in `release/`; make sure that dir is up-to-date before tagging.
