# carwash-smartgw-install

Public installer scripts for the **WASH247** carwash-smartgw gateway.

> **This repository is a mirror. Do not edit it.**
> These files are generated from the private `carwash-smartgw` repository and
> overwritten on every push to its `main` branch. Changes made here will be
> silently lost. Open pull requests against the source repository instead.

The gateway source is private; only these deployment scripts are public, so that devices can fetch them without GitHub credentials. They contain no secrets — every credential is supplied at run time via a flag or an interactive prompt.

## Install

```bash
sudo curl -fsSL https://raw.githubusercontent.com/chargepoint-carwash/carwash-smartgw-install/main/wash247 \
  -o /usr/local/bin/wash247
sudo chmod +x /usr/local/bin/wash247
```

## Usage

```bash
sudo wash247 install --image zodinettech/carwash-smartgw:latest \
     --machine-id <ID> --machine-secret <SECRET> --serial-port /dev/ttyUSB0

sudo wash247 apply-env --set SERIAL_PORT=/dev/ttyS0   # change config
sudo wash247 apply-env                                # edit interactively
sudo wash247 uninstall --yes                          # remove
sudo wash247 help
```

## Files

| File | Purpose |
|------|---------|
| `wash247` | Entry point; dispatches to the scripts below and fetches them as needed |
| `install_server.sh` | Install or re-install the gateway + Watchtower auto-updates |
| `apply_env.sh` | Change `.env` and apply it by recreating the container |
| `uninstall_server.sh` | Remove the gateway from the device |

Each script accepts `--help`:

```bash
sudo wash247 install --help
```

## Running a script directly

```bash
BASE=https://raw.githubusercontent.com/chargepoint-carwash/carwash-smartgw-install/main

sudo bash -c "$(curl -fsSL $BASE/install_server.sh)" -- \
  --image zodinettech/carwash-smartgw:latest \
  --machine-id <ID> --machine-secret <SECRET> --serial-port /dev/ttyUSB0
```

The trailing `--` is required: `bash -c 'script' name arg1` assigns `$0=name`, so without it the first flag is swallowed and ignored.

Use this form rather than `curl … | bash`. Piping delivers the script on stdin, leaving nothing for `read`, which breaks the hidden machine-secret prompt, the uninstall confirmation, and the `apply_env.sh` editor.

## Requirements

- Ubuntu/Linux (macOS supported for development) with `curl`
- Docker — `install_server.sh` offers to install it if missing
- Docker Hub credentials, since the application image is private
