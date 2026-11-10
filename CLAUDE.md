# pocketears — PocketEars (iOS)

SwiftUI app: iPhone mic or phone media audio → FFT → `LSV2` UDP frames to the LED
sign. The phone equivalent of `buddyears` (3DS); same wire protocol, no sign-side changes.

Two sources:
- **Microphone**: captured and analysed in the app process.
- **Phone audio**: ReplayKit broadcast upload extension (`PocketEarsBroadcast`) gets
  `.audioApp` buffers (all apps' playback), analyses them and sends to the sign itself.
  The app mirrors its status and forwards settings/style/messages over loopback UDP
  (`Bridge.swift`: extension listens 127.0.0.1:47236, app listens 127.0.0.1:47237, JSON).

Repo: https://github.com/solluxcaptor429/pocketears (public — free macOS runner minutes)

## Layout

```
project.yml                     XcodeGen spec (the .xcodeproj is generated in CI, gitignored)
Shared/                         compiled into BOTH the app and the extension
  SpectrumAnalyzer.swift        vDSP FFT 4096 @ 64 fps; band maths ported from buddyears dsp.c
  SignLink.swift                BSD UDP socket: BEHI/BEHO discovery, LSV2, BECM, BETX
  SampleRing.swift              lock-free mono ring buffer (one writer, one reader)
  Bridge.swift                  app <-> extension loopback messages (Settings/Status/Control)
PocketEars/AudioCapture.swift   AVAudioEngine input → AVAudioSinkNode → ring buffer
PocketEars/AppModel.swift       mic: 64 Hz timer drives analysis + send; phone audio: mirrors extension
PocketEars/BroadcastPicker.swift  RPSystemBroadcastPickerView, opened from our button (taps its inner UIButton)
PocketEars/ContentView.swift    UI
PocketEarsBroadcast/SampleHandler.swift  RPBroadcastSampleHandler: CMSampleBuffer → mono → analyzer → sign
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
- **No App Group.** SideStore rewrites group IDs, so app ↔ extension talk over loopback
  only. The extension keeps its last-received settings in its own UserDefaults.
- **Extension bundle ID is found at run time** (`AppModel.broadcastExtensionID` scans
  PlugIns/) because SideStore rewrites bundle IDs. Don't hard-code it in the picker.
- ReplayKit app audio may be big-endian Int16 interleaved; `SampleHandler` reads the ASBD
  flags and handles Int16/Int32/Float32, either endianness, interleaved or not.
- DRM audio (Apple Music) reaches ReplayKit as silence. Nothing in the app can fix that.
- Extensions can't show the Local Network prompt; the app primes it once with a
  1-byte datagram to UDP port 9 when phone-audio mode is chosen. Never a BEHI.
- Broadcast extensions have a ~50 MB memory cap. Keep the extension lean.
