import ReplayKit
import SwiftUI
import UIKit

/// iOS 不给「用代码开始录屏」的口子——广播只能由系统那颗按钮发起。
/// 她在「给你看一眼」卡上按下确认之后，这里把那颗按钮拿到手里替她按一下：
/// 弹出来的仍然是系统面板，「开始直播」那一下还得她自己点，这一步绕不过去。
///
/// 按钮藏在 RPSystemBroadcastPickerView 的私有视图层级里，哪天 iOS 换了结构就
/// 找不到——所以失败必须说实话（返回 false），卡片会退回去露一颗真的系统按钮
/// 让她手点，而不是假装已经开了。
@MainActor
enum ScreenBroadcastLauncher {
    static var extensionBundleIdentifier: String {
        "\(Bundle.main.bundleIdentifier ?? "com.tidalecho.personal").ScreenShareUpload"
    }

    @discardableResult
    static func present() -> Bool {
        guard let window = activeWindow else { return false }
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.preferredExtension = extensionBundleIdentifier
        picker.showsMicrophoneButton = false
        picker.alpha = 0.01
        window.addSubview(picker)
        defer {
            // 系统面板是另起的进程，这颗按钮的活儿当场就干完了。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                picker.removeFromSuperview()
            }
        }
        guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else {
            return false
        }
        button.sendActions(for: .touchUpInside)
        return true
    }

    private static var activeWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let key = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow {
            return key
        }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow }
    }
}

/// 真的那颗系统广播按钮：程序化那条路走不通时的退路，设置页里也用它。
struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = ScreenBroadcastLauncher.extensionBundleIdentifier
        picker.showsMicrophoneButton = false
        picker.tintColor = .label
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        picker.preferredExtension = ScreenBroadcastLauncher.extensionBundleIdentifier
        picker.showsMicrophoneButton = false
    }
}
