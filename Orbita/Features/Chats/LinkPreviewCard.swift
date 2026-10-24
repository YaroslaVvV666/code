import SwiftUI

/// Карточка ссылки под сообщением: картинка, заголовок и описание страницы (как в Telegram)
struct LinkPreviewCard: View {
    let url: String
    let mine: Bool

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @State private var info: LinkPreviewData?

    private static var cache: [String: LinkPreviewData?] = [:]

    static func firstURL(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            if let u = match.url, let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return u.absoluteString
            }
        }
        return nil
    }

    var body: some View {
        Group {
            if let info {
                Button {
                    if let u = URL(string: info.url) { UIApplication.shared.open(u) }
                } label: {
                    card(info)
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: url) { await load() }
    }

    private func card(_ info: LinkPreviewData) -> some View {
        let bar: Color = mine ? Color.white.opacity(0.85) : theme.accentColor
        let title: Color = mine ? Color.white : theme.text
        let sub: Color = mine ? Color.white.opacity(0.8) : theme.textSecondary
        return HStack(alignment: .top, spacing: 8) {
            Capsule().fill(bar).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                if !info.site.isEmpty {
                    Text(info.site).font(.system(size: 13, weight: .semibold)).foregroundStyle(bar).lineLimit(1)
                }
                if !info.title.isEmpty {
                    Text(info.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(title).lineLimit(2)
                }
                if !info.description.isEmpty {
                    Text(info.description).font(.system(size: 13)).foregroundStyle(sub).lineLimit(3)
                }
                if let imageURL = URL(string: info.image), !info.image.isEmpty {
                    CachedImage(url: imageURL, maxPixel: 800) { image, _ in
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Color.black.opacity(0.08)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 260, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 11).padding(.top, 2).padding(.bottom, 8)
    }

    private func load() async {
        if let cached = Self.cache[url] { info = cached; return }
        let result = await session.extras.linkPreview(url: url)
        Self.cache[url] = .some(result)
        withAnimation(.easeOut(duration: 0.2)) { info = result }
    }
}
