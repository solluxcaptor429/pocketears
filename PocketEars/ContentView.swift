import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var message = ""
    @State private var styleIndex: Int?
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SpectrumView(levels: model.levels, active: model.isActive)
                        .frame(height: 170)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    Picker("Source", selection: $model.source) {
                        ForEach(AppModel.Source.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isActive)
                    statusRow
                    Button(action: mainAction) {
                        Label(mainTitle, systemImage: model.isActive ? "stop.fill" : mainIcon)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.isActive ? .red : .accentColor)
                    .background(BroadcastPickerHost().frame(width: 1, height: 1))
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
                    if let err = model.errorText {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    if !model.isActive {
                        if model.source == .microphone {
                            Text("Works with Apple Music. Start music, then come here and tap Start. It keeps listening with the app closed and the screen locked, and music stays on your speaker, Bluetooth or AirPlay.")
                        } else {
                            Text("Captures other apps digitally: Spotify, YouTube, games. Apple Music is DRM-protected and comes through silent here; use Listen for it. If the Start sheet doesn't open, long-press Screen Recording in Control Center and pick PocketEars.")
                        }
                    }
                }

                Section {
                    Toggle("Auto gain", isOn: $model.autoGain)
                    Toggle("Balance bands", isOn: $model.balanceBands)
                    LabeledSlider(title: "Sensitivity", value: $model.sensitivityDB,
                                  range: -12...24, format: { String(format: "%+.0f dB", $0) })
                    LabeledSlider(title: "Noise floor", value: $model.floorDB,
                                  range: -80...(-40), format: { String(format: "%.0f dB", $0) })
                    LabeledSlider(title: "Treble boost", value: $model.tiltDB,
                                  range: 0...6, format: { String(format: "%.1f dB/oct", $0) })
                } header: {
                    Text("Levels")
                } footer: {
                    Text("Auto gain keeps the bars in range whether the phone hears a quiet room or its own speaker. Balance bands lifts ranges that stay quiet, like the bass a phone speaker can't play. Raise the noise floor if the sign flickers in silence.")
                }

                Section("Visualizer style") {
                    Menu {
                        ForEach(AppModel.styles.indices, id: \.self) { i in
                            Button {
                                styleIndex = i
                                model.setStyle(i)
                            } label: {
                                if styleIndex == i {
                                    Label(AppModel.styles[i], systemImage: "checkmark")
                                } else {
                                    Text(AppModel.styles[i])
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text("Style on the sign")
                            Spacer()
                            Text(styleIndex.map { AppModel.styles[$0] } ?? "Choose…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!model.canTalkToSign)
                }

                Section {
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($editing)
                        .submitLabel(.send)
                        .onSubmit(send)
                    Picker("Animation", selection: $model.messageEffect) {
                        ForEach(AppModel.effects.indices, id: \.self) { i in
                            Text(AppModel.effects[i]).tag(i)
                        }
                    }
                    Stepper(value: $model.messageSeconds, in: 2...60, step: 1) {
                        Text("Show for \(Int(model.messageSeconds)) s")
                    }
                    Button("Send to sign", action: send)
                        .disabled(!model.canTalkToSign || message.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Message")
                } footer: {
                    Text("Up to 120 bytes. The visualizer comes back after the message.")
                }

                Section {
                    TextField("Automatic", text: $model.signAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($editing)
                    Toggle("Keep screen on while listening", isOn: $model.keepAwake)
                } header: {
                    Text("Sign address")
                } footer: {
                    Text("Leave empty to find the sign on this Wi-Fi automatically. Otherwise enter its IP or hostname (e.g. ledsign.local). Listening continues with the screen locked.")
                }
            }
            .navigationTitle("PocketEars")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editing = false }
                }
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.subheadline.weight(.semibold))
                if let detail = statusDetail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isActive {
                Text(String(format: "%+.0f dB", model.gainShown))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mainTitle: String {
        if model.isActive { return "Stop" }
        return model.source == .microphone ? "Start listening" : "Start phone audio"
    }

    private var mainIcon: String {
        model.source == .microphone ? "waveform" : "music.note.list"
    }

    private func mainAction() {
        if model.broadcastLive {
            model.stopBroadcast()
        } else if model.running {
            model.stop()
        } else if model.source == .microphone {
            model.start()
        } else if !model.broadcastAvailable {
            model.errorText = "This build has no broadcast extension. Reinstall the latest PocketEars.ipa."
        } else if !BroadcastLauncher.shared.present() {
            model.errorText = "Couldn't open the broadcast sheet. Long-press Screen Recording in Control Center and pick PocketEars."
        }
    }

    private var statusColor: Color {
        guard model.isActive else { return .gray }
        if model.broadcastLive && !model.broadcastAudioFlowing { return .yellow }
        if model.link.connected { return .green }
        if model.link.manual && !model.link.ip.isEmpty { return .yellow }
        return .orange
    }

    private var statusTitle: String {
        let l = model.link
        guard model.isActive else { return "Stopped" }
        if model.broadcastLive && !model.broadcastAudioFlowing {
            return "Waiting for audio…"
        }
        if l.connected { return "Sending to \(l.name.isEmpty ? "the sign" : l.name)" }
        if l.manual {
            if l.lookupFailed { return "Can't find \(model.signAddress)" }
            if l.ip.isEmpty { return "Looking up \(model.signAddress)…" }
            return "Sending to \(l.ip) (no reply yet)"
        }
        return "Searching for the sign…"
    }

    private var statusDetail: String? {
        let l = model.link
        guard model.isActive else {
            return model.source == .microphone
                ? "Hears the phone's speaker or the room. Works with Apple Music."
                : "Tap Start, then Start Broadcast. Keeps running after you leave the app."
        }
        if model.broadcastLive && !model.broadcastAudioFlowing {
            let found = l.connected ? "Sign found at \(l.ip). " : ""
            return found + "Play something in another app. For Apple Music, stop and use Listen."
        }
        if l.connected { return "\(l.ip) · \(l.framesSent) frames" }
        if l.manual && !l.ip.isEmpty { return "\(l.framesSent) frames" }
        if !l.manual { return "Allow Local Network access if iOS asks." }
        return nil
    }

    private func send() {
        model.sendMessage(message)
        message = ""
        editing = false
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: range)
        }
    }
}

/// 16 bars, roughly what the sign's Bars style shows.
struct SpectrumView: View {
    let levels: [Float]
    let active: Bool

    var body: some View {
        Canvas { ctx, size in
            let n = levels.count
            guard n > 0 else { return }
            let gap: CGFloat = 4
            let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            let cellH: CGFloat = 6
            let cells = Int(size.height / (cellH + 2))
            for i in 0..<n {
                let lit = Int((CGFloat(levels[i]) * CGFloat(cells)).rounded())
                let x = CGFloat(i) * (w + gap)
                for c in 0..<cells {
                    let y = size.height - CGFloat(c + 1) * (cellH + 2)
                    let rect = CGRect(x: x, y: y, width: w, height: cellH)
                    let hue = 0.66 - 0.66 * Double(c) / Double(max(cells - 1, 1))
                    let color: Color = c < lit
                        ? Color(hue: hue, saturation: 0.9, brightness: 1)
                        : Color.white.opacity(active ? 0.06 : 0.04)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
                }
            }
        }
        .background(Color.black, in: RoundedRectangle(cornerRadius: 10))
        .animation(.linear(duration: 0.05), value: levels)
    }
}
