#if DEBUG
import CoreText
import SwiftUI
import UIKit

@MainActor
enum IMessageReviewFixture {
    static func makeModel() -> AppModel {
        let model = AppModel()
        let env = ProcessInfo.processInfo.environment
        writeRegionalFontReview()
        model.theme = EchoTheme(rawValue: env["REVIEW_THEME"] ?? "mist") ?? .mist
        model.chatLayoutStyle = env["REVIEW_CLASSIC"] == "1" ? .classic : .imessage
        model.composerStyle = ComposerStyle(rawValue: env["REVIEW_COMPOSER"] ?? "original") ?? .original
        model.chatFont = EchoChatFont(rawValue: env["REVIEW_FONT"] ?? "system") ?? .system
        model.bubbleStyle = .classic
        model.bubbleShapeStyle = EchoBubbleShapeStyle(rawValue: env["REVIEW_BUBBLE_SHAPE"] ?? "standard") ?? .standard
        model.showsAIBubble = true
        model.fontScale = 1
        model.chatWeight = 400
        model.showsAIAvatar = false
        model.showsHumanAvatar = false
        model.showsClawdPet = false
        model.backgroundBlur = 0
        model.backgroundOpacity = 1
        model.aiAvatarImage = avatar()
        model.backgroundImage = wallpaper(dark: model.theme == .harbor)
        var messages: [(MessageAuthor, String)] = [
            (MessageAuthor.human, "看看新的聊天布局"),
            (.ai, "圆形头像放在正中间，点一下就可以切换窗口。"),
            (.human, "输入框再轻一点"),
            (.ai, "玻璃只留在底层。文字和图标在上面，清晰可读。"),
            (.human, "加号里有什么？"),
            (.ai, "添加附件和表情包，竖着排好。"),
            (.ai, "空白时是声波，开始打字就会变成发送。")
        ]
        if model.composerStyle == .wechat {
            messages = [
                (.human, "看看新的输入栏"),
                (.ai, "底部磨砂面板贴着左右和下沿，背景颜色可以透出来。"),
                (.human, "字体也可以换吗？"),
                (.ai, "可以导入字体，也可以选择日文字形和繁体中文（香港）字形。"),
                (.human, "骨、直、令、返、雨、花、雪"),
                (.ai, "界面和聊天内容都保留简体中文，只改变聊天字形。")
            ]
        }
        model.messages = messages.enumerated().map { index, entry in
            ChatMessage(id: index + 1, timestamp: "2026-09-21T11:48:00Z",
                        author: entry.0, kind: "text", text: entry.1)
        }
        return model
    }

    /// The CI simulator verifies that its installed fonts actually resolve the
    /// same Han character to distinct regional faces, beyond just compiling.
    private static func writeRegionalFontReview() {
        let sample = "骨" as CFString
        var records: [String: String] = [:]
        for choice in [EchoChatFont.system, .japanese, .hongKong] {
            let font = choice.uiFont(size: 17, numericWeight: 400)
            let resolved = CTFontCreateForString(font as CTFont, sample, CFRange(location: 0, length: 1))
            records[choice.rawValue] = CTFontCopyPostScriptName(resolved) as String
        }
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: directory.appendingPathComponent("regional-font-review.json"), options: .atomic)
        }
    }

    private static func avatar() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { context in
            UIColor(red: 0.18, green: 0.28, blue: 0.29, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            ("A" as NSString).draw(at: CGPoint(x: 30, y: 15), withAttributes: [
                .font: UIFont.systemFont(ofSize: 76, weight: .medium),
                .foregroundColor: UIColor.white
            ])
        }
    }

    private static func wallpaper(dark: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 400, height: 900)).image { context in
            (dark ? UIColor(white: 0.12, alpha: 1) : UIColor(red: 0.71, green: 0.84, blue: 0.81, alpha: 1)).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 900))
            for row in 0..<15 {
                for column in 0..<7 {
                    UIColor.white.withAlphaComponent(dark ? 0.12 : 0.42).setFill()
                    context.cgContext.fillEllipse(in: CGRect(x: column * 66 + (row % 2) * 23,
                                                             y: row * 66, width: 12, height: 12))
                }
            }
        }
    }
}
#endif
