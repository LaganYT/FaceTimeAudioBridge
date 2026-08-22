# FaceTime Audio Bridge

A native macOS menu-bar utility that monitors **BlackHole 2ch** into a physical USB audio interface. It replaces the simple input-monitoring part of a DAW for a FaceTime anti-ducking setup.

## Requirements

- macOS 14 or later
- BlackHole 2ch installed
- A stereo USB audio interface
- Source and destination configured to the same sample rate in Audio MIDI Setup

## FaceTime routing

1. Keep the USB interface selected as the normal macOS output.
2. In FaceTime's **Video** menu, set **Output** to BlackHole 2ch.
3. Set FaceTime's **Microphone** to the USB interface/XLR microphone.
4. In this app, select BlackHole 2ch as Source and the USB interface as Destination.
5. Click **Start Bridge**.

Enable **Start on Login** to register the app in macOS Login Items and automatically start the saved bridge route whenever the app launches at login. Enabling it also starts the bridge immediately.

Use **FaceTime Boost** to raise only the bridged call by 0–24 dB without increasing normal Mac audio. The default is +12 dB and the selection is remembered.

The FaceTime call is sent to BlackHole and monitored into the interface. Other Mac audio remains directly on the interface, outside FaceTime's output device.

### If BlackHole 2ch is already used by OBS

Do not reuse the same two-channel device for FaceTime: it contains one mixed stereo stream, so the bridge would also monitor your system/OBS mix and could duplicate it in your headphones. Install a second BlackHole variant (for example BlackHole 16ch), reserve it for FaceTime, and choose that as the bridge Source. Your existing BlackHole 2ch Multi-Output Device and OBS configuration can remain unchanged.

## Build

Run `Scripts/package-app.sh` to compile and ad-hoc sign the menu-bar `.app` bundle. The prebuilt app is also available in `dist`.

## Current limitations

- Stereo, 32-bit floating-point PCM devices only
- Source and destination sample rates must match
- Device changes require stopping and restarting the bridge
- Independent FaceTime boost from 0 to +24 dB
- Source and destination have independent clocks; the bridge automatically drops stale queued frames if drift would push latency beyond roughly 32 ms
