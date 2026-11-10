import ReplayKit
import SwiftUI

/// Opens iOS's "Start Broadcast" sheet for the PocketEars extension from our own
/// button. RPSystemBroadcastPickerView has no public "present" call, so this taps
/// its inner UIButton for it -- an unofficial but long-standing trick. The picker
/// has to sit in a window for the sheet to appear; BroadcastPickerHost puts it there.
final class BroadcastLauncher {
    static let shared = BroadcastLauncher()

    let picker: RPSystemBroadcastPickerView = {
        let p = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        p.showsMicrophoneButton = false
        p.preferredExtension = AppModel.broadcastExtensionID
        return p
    }()

    /// Returns false if the picker's button couldn't be found.
    @discardableResult
    func present() -> Bool {
        guard let button = Self.findButton(in: picker) else { return false }
        button.sendActions(for: .touchUpInside)
        return true
    }

    private static func findButton(in view: UIView) -> UIButton? {
        for sub in view.subviews {
            if let b = sub as? UIButton { return b }
            if let b = findButton(in: sub) { return b }
        }
        return nil
    }
}

/// A 1-point, invisible host that keeps the picker in the view hierarchy.
struct BroadcastPickerHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        host.clipsToBounds = true
        host.alpha = 0.011
        host.isUserInteractionEnabled = false
        host.addSubview(BroadcastLauncher.shared.picker)
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
