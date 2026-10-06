# Simple Syncthing

Simple Syncthing started because I liked Syncthing itself, but I did not particularly enjoy setting it up through the web UI. I wanted a simpler, terminal-first experience: a lightweight TUI-style installer that could walk me through choosing folders, pairing devices, and getting Syncthing running automatically without spending much time in the browser.

The project provides two terminal-first helper scripts for setting up Syncthing across Linux machines.

> **AI disclosure and disclaimer**
>
> This project was created with substantial help from AI, including code generation, review, debugging, and iteration. The scripts have been tested in the environments they were developed for, but they may still contain bugs, make incorrect assumptions about your system, or behave differently across Linux distributions and Syncthing versions.
>
> Review the scripts before running them, especially on systems containing important or irreplaceable data. Use this project at your own risk. Keep backups of anything you cannot afford to lose.

## Files

- `syncthing-primary-setup.sh` sets up the primary device, lets you paste one folder path per line, and waits for secondary devices.
- `syncthing-join.sh` is the reusable joiner script for secondary devices.

## Basic flow

On the primary machine:

```bash
chmod +x syncthing-primary-setup.sh
./syncthing-primary-setup.sh
```

Paste one folder path per line. Press Enter on a blank line when finished.

On each secondary machine:

```bash
chmod +x syncthing-join.sh
./syncthing-join.sh
```

Paste the primary Syncthing Device ID when prompted.

For each offered folder, choose the local destination. If files already exist, choose whether to merge, replace the local folder after backing it up, or skip it.

Both scripts enable a **systemd user service**, so Syncthing starts automatically when that user logs in. A username does not need to be written into the service file because `systemctl --user` already runs the service in the current user's systemd session.

## Immutable Linux

The scripts automatically detect common rpm-ostree/OSTree systems such as Aurora, Fedora Silverblue/Kinoite, and similar immutable Fedora variants.

You can also force immutable behavior:

```bash
./syncthing-primary-setup.sh --immutable
./syncthing-join.sh --immutable
```

If Syncthing is already installed, either script detects the existing binary first, skips installation, and continues directly into service/API checks and Syncthing configuration. If an existing Syncthing instance is already running on port 8384, the script reuses it instead of launching a second instance.

In immutable mode, if Syncthing is not already installed, the script asks how you want to install it:

```text
1) Direct download to ~/.local/bin
   Recommended for immutable systems.

2) Homebrew
   Uses: brew install syncthing
```

The direct option installs Syncthing into `~/.local/bin/syncthing` and creates a systemd user service at `~/.config/systemd/user/syncthing.service`.

The Homebrew option runs `brew install syncthing` and starts it with `brew services start syncthing`, letting Homebrew manage the service.

Neither option layers Syncthing into the immutable base OS.

The direct immutable installer currently supports x86_64/amd64 and arm64/aarch64 Linux systems. It expects `curl`, `tar`, and `jq` to already be available on the host. Homebrew must already be installed if you choose the Homebrew option.

## Notes

- Syncthing syncs subfolders and files recursively.
- The joiner can be reused on additional machines.
- Syncthing does not require Tailscale or the same LAN. Tailscale can still be useful as an additional network path.
- Conventional installs currently support apt, dnf, and pacman based systems.

## Existing installations and config detection

When Syncthing is already installed and running, the scripts now use `syncthing --paths` to find the configuration file for that installation before reading the REST API key. They validate the `/rest/system/status` response before passing it to `jq`.

If the running Syncthing instance and the detected config do not match, the script stops and prints the selected config path, Syncthing's reported paths, and the raw API response instead of failing with an opaque `jq: parse error`.
