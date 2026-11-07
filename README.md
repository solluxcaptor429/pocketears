# PocketEars

iPhone/iPad app that listens through the mic and drives the Pi LED sign's audio
visualizer — the phone version of [BuddyEars](https://github.com/solluxcaptor429/buddyears).
It speaks the sign's own protocol, so the sign needs no changes (v4.5.0+).

- 64 frames/s of 16 spectrum bands + a 64-point oscilloscope (`LSV2`, UDP 1236)
- finds the sign on the Wi-Fi by itself, or use a fixed IP / `ledsign.local`
- auto gain, sensitivity, noise floor and treble boost
- pick the sign's visualizer style, send text messages with any of its 13 animations
- keeps running with the screen locked; music playing on the phone keeps playing
- Stop hands the sign back (it returns to its clock)

## Install (SideStore)

1. On the iPhone, open
   `https://github.com/solluxcaptor429/pocketears/releases/download/latest/PocketEars.ipa`
   in Safari and save it to Files.
2. SideStore → My Apps → **+** → pick `PocketEars.ipa`.
3. First launch: allow **Microphone** and **Local Network**. Without Local Network
   the app can't reach the sign.

## Build

No Mac needed. Every push to `main` runs `.github/workflows/build.yml` on GitHub's
macOS runner: XcodeGen generates the project from `project.yml`, `xcodebuild`
builds it unsigned, and the IPA is attached to the rolling `latest` release (and
kept as a workflow artifact).

## How it finds the sign

The 3DS broadcasts a `BEHI` hello. iOS blocks broadcast/multicast for apps without
Apple's restricted multicast entitlement, which a sideloaded app can't get — so
PocketEars also sends the 16-byte hello as a unicast to every address on the local
/24 every 2 s until the sign answers with `BEHO`, then re-checks every 15 s. The
hello doesn't set the desktop flag (`0x04`), so the sign treats the phone as a
handheld and the Windows tray yields to it, exactly as it does for the 3DS.

See `buddyears/PROTOCOL.md` for the packet formats.
