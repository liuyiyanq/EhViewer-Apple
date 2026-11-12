//
//  CommentText.swift
//  ehviewer apple
//
//  评论 HTML 渲染与评论链接跳转
//

import SwiftUI
import EhModels

// MARK: - 评论 HTML → AttributedString

/// 评论正文是 HTML 片段：`<br>` 换行、`<a href>` 链接、`&amp;` 等实体。
/// 直接删掉全部标签会丢失链接地址、多行连成一行，所以在这里转成带链接的 AttributedString。
enum CommentText {
    private static let breakRegex = try! NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive])
    private static let linkRegex = try! NSRegularExpression(
        pattern: #"<a\s[^>]*?href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let tagRegex = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let numericEntityRegex = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#, options: [.caseInsensitive])
    private static let malformedHrefCharacters = CharacterSet(charactersIn: "\"'<>").union(.whitespacesAndNewlines)

    private static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
    ]

    /// 转成带链接的 AttributedString：`<br>` 转换行，`<a href>` 转链接，解码实体，去掉其他标签
    static func attributed(fromHTML html: String) -> AttributedString {
        let source = replace(breakRegex, in: html, with: "\n")
        var result = AttributedString()
        var cursor = source.startIndex
        let range = NSRange(source.startIndex..., in: source)
        for match in linkRegex.matches(in: source, range: range) {
            guard let whole = Range(match.range, in: source),
                  let hrefRange = Range(match.range(at: 1), in: source),
                  let textRange = Range(match.range(at: 2), in: source) else { continue }
            result += AttributedString(plainText(String(source[cursor..<whole.lowerBound])))

            let href = decodeEntities(String(source[hrefRange]))
            let text = plainText(String(source[textRange]))
            cursor = whole.upperBound
            // 用户手写的 HTML 被 E-H 转义后，整段会被自动识别成一个链接，href 里混着引号和尖括号
            if href.rangeOfCharacter(from: malformedHrefCharacters) != nil {
                result += linkifyingURLs(in: text)
                continue
            }
            var link = AttributedString(text.isEmpty ? href : text)
            if let url = URL(string: href) {
                link.link = url
            }
            result += link
        }
        result += AttributedString(plainText(String(source[cursor...])))
        return result
    }

    /// 只把文本中的网址标成链接，其余保持纯文本
    private static func linkifyingURLs(in text: String) -> AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        for match in urlRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += AttributedString(String(text[cursor..<range.lowerBound]))
            let urlText = String(text[range])
            var link = AttributedString(urlText)
            link.link = URL(string: urlText)
            result += link
            cursor = range.upperBound
        }
        result += AttributedString(String(text[cursor...]))
        return result
    }

    /// 去掉标签并解码实体后的纯文本 (换行已由调用方处理)
    private static func plainText(_ html: String) -> String {
        decodeEntities(replace(tagRegex, in: html, with: ""))
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let range = NSRange(result.startIndex..., in: result)
        for match in numericEntityRegex.matches(in: result, range: range).reversed() {
            guard let whole = Range(match.range, in: result),
                  let hexRange = Range(match.range(at: 1), in: result),
                  let valueRange = Range(match.range(at: 2), in: result) else { continue }
            let radix = result[hexRange].isEmpty ? 10 : 16
            guard let value = UInt32(result[valueRange], radix: radix),
                  let scalar = Unicode.Scalar(value) else { continue }
            result.replaceSubrange(whole, with: String(Character(scalar)))
        }
        for (entity, character) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

// MARK: - 评论链接跳转

/// 评论里的画廊链接在当前页面栈中推入画廊详情页，其他链接交给系统浏览器
struct GalleryLinkNavigation: ViewModifier {
    @State private var linkedGallery: GalleryInfo?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let link = EhURL.parseGalleryLink(url) else { return .systemAction }
                linkedGallery = GalleryInfo(gid: link.gid, token: link.token)
                return .handled
            })
            .navigationDestination(item: $linkedGallery) { gallery in
                GalleryDetailView(gallery: gallery)
            }
    }
}

extension View {
    /// 评论中的画廊链接在 App 内打开
    func openGalleryLinksInApp() -> some View {
        modifier(GalleryLinkNavigation())
    }
}
