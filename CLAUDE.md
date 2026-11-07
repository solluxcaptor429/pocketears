# pocketears — PocketEars (iOS)

SwiftUI app: iPhone mic → FFT → `LSV2` UDP frames to the LED sign. The phone
equivalent of `buddyears` (3DS); same wire protocol, no sign-side changes.

Repo: https://github.com/solluxcaptor429/pocketears (public — free macOS runner minutes)

## Layout

```
project.yml                     XcodeGen spec (the .xcodeproj is generated in CI, gitignored)
PocketEars/SpectrumAnalyzer.swift   vDSP FFT 4096 @ 64 fps; band maths ported from buddyears dsp.c
PocketEars/AudioCapture.swift   AVAudioEngine input → AVAudioSinkNode → ring buffer
PocketEars/SignLink.swift       BSD UDP socket: BEHI/BEHO discovery, LSV2, BECM, BETX
PocketEars/AppModel.swift       64 Hz DispatchSourceTimer drives analysis + send; settings
PocketEars/ContentView.swift    UI
.github/workflows/build.yml     macos-26 runner → unsigned IPA → release "latest"
```

## Build / install

Cannot be built on this Windows host. Push to `main`; the workflow builds the IPA
and uploads it to the `latest` release. The user installs it with SideStore (which
signs it). Check a run with `gh run list -R solluxcaptor429/pocketears`.

## Things that matter

- **No broadcast on iOS** without the restricted `com.apple.developer.networking.multicast`
  entitlement. Discovery therefore unicast-sweeps the /24 on port 1236. Don't remove the sweep.
- **Never set BEHI flag 0x04.** The phone is a handheld; the sign must tag it as one so
  the Windows tray yields (led-sign "peer yielding" gotcha).
- Style list order (`AppModel.styles`) must match led-sign `BUDDYEARS_VIZ_STYLES`;
  effects must match `BUDDYEARS_MSG_EFFECTS`. Index = wire value.
- Audio session is `.playAndRecord` + `.measurement` + `.mixWithOthers`: measurement
  disables voice AGC, mixWithOthers keeps the phone's own music playing.
- Stop sends `BECM` opcode 2 (release) so the sign returns to idle.
