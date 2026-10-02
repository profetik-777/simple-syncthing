# Simple Syncthing

Two terminal-first helper scripts for setting up Syncthing across Linux machines.

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

Both scripts enable the Syncthing user service so it starts automatically on future logins.

## Notes

- Syncthing syncs subfolders and files recursively.
- The joiner can be reused on additional machines.
- Syncthing does not require Tailscale or the same LAN. Tailscale can still be useful as an additional network path.
- The scripts currently support apt, dnf, and pacman based systems.
