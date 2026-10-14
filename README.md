# Showcase

## Updates

This repository contains the Showcase source. Install the packaged tweak from the Rostane source in Sileo.

```text
https://aminerostane.com/repo
```

Beta 4-3

- Fixes the false hotspot name warning on iOS 16 and newer.

Beta 4-2

- Reconnects to your iPhone by itself, like a car. Open Showcase and CarPlay comes back without touching the iPhone.
- Starts CarPlay when you open Showcase. You can turn this off in Settings.
- Stops cleanly and waits for your iPhone when it leaves or turns off Wi-Fi.
- Rootless: keeps the Bluetooth pairing after a reboot.
- Relaunching no longer asks for internet, Try Again works, and Showcase retries when the network comes back.
- Opens without the long black screen.
- Warns when the hotspot name doesn't match the device name.

Beta 4

- Starts Personal Hotspot by itself, and asks you to turn it on in Settings when iOS refuses.
- Lets you pick where sound plays by tapping the receiver or the CarPlay sender on the Sound page.
- Shortens the connection steps and drops the small explanation text.
- Returns to CarPlay when you tap anywhere on the dimmed controls screen.
- Removes the 5 GHz hotspot option. The hotspot uses the band iOS chooses.
- Reads every version string from the `VERSION` file.

Showcase turns an older jailbroken Apple device into a software wireless CarPlay receiver. The iPhone pairs through Settings, joins the receiver's hotspot, sends the encrypted CarPlay video stream, and receives touch input from the receiver.

Showcase ships in rootful and rootless package layouts. Both use iOS 12 as the deployment minimum.

## Install

Add the package source in Sileo, Cydia, or Zebra.

```text
https://aminerostane.com/repo
```

Then install `Showcase`.

Install guide and protocol write-up

https://aminerostane.com/articles/showcase

## Requirements

| Item | Requirement |
| --- | --- |
| Receiver | Jailbroken iPhone or iPad with Personal Hotspot |
| Tested rootful receiver | iPad Air 1, A1475, iPad4,2, iOS 12.5.8, checkra1n |
| Tested rootless receiver | iPhone 7, iPhone9,3, iOS 15.8.4, Dopamine rootless |
| Runtime packages | Rootful uses `uikittools`; rootless uses `uikittools` and `ldid` |

Sileo, Cydia, and Zebra install runtime packages through normal APT dependency resolution. Manual dependency installation is only needed when sideloading a `.deb` with `dpkg -i`.

The package bundles `BTdaemon`, `libBTstack.dylib`, and the BTstack launch daemon needed for `/tmp/BTstack`. It conflicts with the old `ch.ringwald.btstack` package to avoid file ownership collisions.

## What Works

- Wireless CarPlay discovery over Bluetooth and AirPlay/mDNS.
- BTstack takeover while the receiver runs.
- iAP2 link setup, identification, BAA authentication, Wi-Fi handoff, and EAP session setup.
- AirPlay pair-setup, pair-verify, auth-setup, RTSP control, timing, event channel, and screen stream setup.
- H.264 screen stream decryption with ChaCha20-Poly1305.
- Single-finger touch forwarding over the encrypted event channel.
- BAA certificate preheating while the receiver still has internet access.
- Stream sizing derived from the receiver's native aspect ratio, memory, processor count, and decode budget.
- Sender-timeline H.264 presentation with an adaptive jitter budget and stale-frame recovery after transport stalls.
- Stream telemetry for arrival rate, bitrate, frame gaps, presentation delay, and UI enqueue time.
- Receiver audio for navigation, calls, radio, Apple Music, and third-party media apps.
- A named vehicle app with the Showcase icon and a clean CarPlay sidebar.
- Three-finger controls that dim the video and block CarPlay input until you tap to return.
- Persistent controller pairing, CarPlay screen-resource handoff, and fresh-keyframe recovery after backgrounding.
- A Bluetooth compatibility report when BTstack cannot control the receiver hardware.

Showcase embeds Monocypher and LibTomMath for CarPlay cryptography. Users no longer need an OpenSSL package or repository.

## Video quality

With **Prefer Smooth Video** off (the default), Showcase requests a sharper
30 fps stream, within the receiver's aspect ratio, native dimensions and a
1080p pixel budget. For a 2048 × 1536 iPad with 1 GB of RAM, the requested
stream is 1280 × 960 instead of 960 × 720 (78% more pixels).
This is still below Retina resolution; the iPhone controls H.264 compression.

Enable **Prefer Smooth Video** if the larger stream causes stalls on your
receiver or hotspot. This retains the previous lower-resolution profile.
Reconnect CarPlay after changing the setting. The selected resolution and
cadence appear on the About page and in the `display profile` log entry.
The sharper profile was tested on an iPad Air (iPad4,1), iOS 12.5.7,
with a user-reported improvement in sharpness and satisfactory 30 fps playback.
Other receivers and wireless conditions still need on-device validation.

## Source Layout

```text
source/       app, Bluetooth helper, AirPlay helper, pairing code
btstack-rootless/
              patched BTstack v1.1 iOS daemon source used by the rootless package
packaging/    Debian control files, depictions, package scripts
icon/         app icons
```

## Build From Source

Showcase builds on the jailbroken receiver. The build script expects SSH access through a local forwarded port and pins the deployment target to iOS 12.0.

```sh
iproxy 2222 <ipad-sshd-port>
IPAD_PORT=2222 IPAD_PASS=alpine ./build_and_install.sh
```

For a jailbreak SSH daemon on port 22, run this command.

```sh
iproxy 2222 22
```

The script compiles the three binaries on-device, signs them with `ldid`, installs the rootful app under `/Applications`, and refreshes SpringBoard. Use the package scripts below for rootless builds.

## Build The Deb

Build and test the app on the iPad first.

```sh
cd packaging
./scripts/fetch-installed-app.sh
./scripts/build-rootful-deb.sh
./scripts/build-rootless-deb.sh
./scripts/generate-apt-repo.py repo
```

The `.deb` files land in `packaging/build/`. The APT repository lands in `packaging/repo/`.

For GitHub Releases, upload both `.deb` files from `packaging/build/` after you rebuild the packages. The rootful asset ends in `iphoneos-arm.deb`; the rootless asset ends in `iphoneos-arm64.deb`.

For Sileo, Cydia, and Zebra, publish the generated `packaging/repo/` contents to the web path that serves `https://aminerostane.com/repo`.

## Logs

```text
/var/mobile/Library/Showcase/logs/app.log
/var/mobile/Library/Showcase/logs/baa_broker.log
/var/mobile/Library/Showcase/logs/btdaemon.log
/var/mobile/Library/Showcase/logs/carplay_bt.log
/var/mobile/Library/Showcase/logs/carplay_services.log
```

Check logs before posting them in public issues. Logs can include device names, hotspot names, network details, and pairing traces.

## BTstack Rootless Source

The rootless package bundles a patched BTstack daemon. Its source lives in `btstack-rootless/`.

The patch set fixes classic BR/EDR authentication state, incoming RFCOMM cid registration, RFCOMM data routing, and classic-only daemon builds on Procursus SDKs. See `btstack-rootless/README.rootless.md` for the build command.

## License

GPL-3.0-or-later. The pairing code includes work adapted from UxPlay and csrp. Binary packages bundle BTstack runtime files from the historical `ch.ringwald.btstack` jailbreak package by Matthias Ringwald.
