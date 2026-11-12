import XCTest
@testable import EhModels

final class EhURLTests: XCTestCase {

    func testParseGalleryLink() {
        let tests: [(name: String, input: String, want: GalleryLink?)] = [
            ("e-hentai https 带结尾斜杠", "https://e-hentai.org/g/2345678/0123456789/", GalleryLink(gid: 2345678, token: "0123456789")),
            ("exhentai 无结尾斜杠", "https://exhentai.org/g/2345678/abcdef0123", GalleryLink(gid: 2345678, token: "abcdef0123")),
            ("http 协议", "http://e-hentai.org/g/1/abcdefabcd/", GalleryLink(gid: 1, token: "abcdefabcd")),
            ("带查询参数", "https://e-hentai.org/g/2345678/0123456789/?p=2", GalleryLink(gid: 2345678, token: "0123456789")),
            ("大写 token 统一为小写", "https://e-hentai.org/g/2345678/ABCDEF0123/", GalleryLink(gid: 2345678, token: "abcdef0123")),
            ("lofi 域名", "https://lofi.e-hentai.org/g/2345678/0123456789/", GalleryLink(gid: 2345678, token: "0123456789")),
            ("夹在文字中", "看这个 https://e-hentai.org/g/2345678/0123456789/ 不错", GalleryLink(gid: 2345678, token: "0123456789")),
            ("图片页链接", "https://e-hentai.org/s/0123456789/2345678-1", nil),
            ("token 长度不对", "https://e-hentai.org/g/2345678/0123456789a/", nil),
            ("其他域名", "https://example.com/g/2345678/0123456789/", nil),
            ("纯文本", "没有链接", nil),
        ]
        for tt in tests {
            XCTAssertEqual(EhURL.parseGalleryLink(tt.input), tt.want, tt.name)
        }
    }

    func testParseGalleryLink_URL() {
        let tests: [(name: String, input: String, want: GalleryLink?)] = [
            ("画廊链接", "https://exhentai.org/g/2345678/0123456789/", GalleryLink(gid: 2345678, token: "0123456789")),
            ("其他域名中嵌入画廊链接", "https://example.com/?u=https://e-hentai.org/g/2345678/0123456789/", nil),
            ("论坛链接", "https://forums.e-hentai.org/index.php?showtopic=1", nil),
        ]
        for tt in tests {
            XCTAssertEqual(EhURL.parseGalleryLink(URL(string: tt.input)!), tt.want, tt.name)
        }
    }
}
