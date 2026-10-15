import SwiftUI
import UIKit

// MARK: - Узор из эмодзи на фоне

private struct EmojiPattern: View {
    let emoji: String
    let dark: Bool

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 62
            var row = 0
            var y: CGFloat = 0
            while y < size.height + step {
                var x: CGFloat = row % 2 == 0 ? 0 : step / 2
                var col = 0
                while x < size.width + step {
                    // детерминированное «дрожание», чтобы узор не выглядел решёткой
                    let seed = Double((row * 31 + col * 17) % 11)
                    var c = context
                    c.translateBy(x: x + CGFloat(seed - 5) * 1.6, y: y + CGFloat((seed * 7).truncatingRemainder(dividingBy: 9) - 4) * 1.6)
                    c.rotate(by: .degrees((seed - 5) * 6))
                    c.opacity = dark ? 0.16 : 0.22
                    c.draw(Text(emoji).font(.system(size: 22 + CGFloat(seed.truncatingRemainder(dividingBy: 4)) * 3)), at: .zero)
                    x += step
                    col += 1
                }
                y += step * 0.9
                row += 1
            }
        }
    }
}

/// Один из вариантов оформления: цвета фона и эмодзи узора
private struct QRBackdropStyle: Identifiable {
    let id: Int
    let emoji: String
    let dark: [Color]
    let light: [Color]

    static let all: [QRBackdropStyle] = [
        .init(id: 0, emoji: "🪐", dark: [Color(red: 0.05, green: 0.06, blue: 0.16), Color(red: 0.16, green: 0.08, blue: 0.30)],
              light: [Color(red: 0.86, green: 0.90, blue: 1.0), Color(red: 0.90, green: 0.84, blue: 1.0)]),
        .init(id: 1, emoji: "🌙", dark: [Color(red: 0.03, green: 0.10, blue: 0.14), Color(red: 0.05, green: 0.22, blue: 0.24)],
              light: [Color(red: 0.84, green: 0.96, blue: 0.95), Color(red: 0.88, green: 0.94, blue: 1.0)]),
        .init(id: 2, emoji: "⭐️", dark: [Color(red: 0.14, green: 0.07, blue: 0.05), Color(red: 0.30, green: 0.14, blue: 0.08)],
              light: [Color(red: 1.0, green: 0.93, blue: 0.84), Color(red: 1.0, green: 0.88, blue: 0.88)]),
        .init(id: 3, emoji: "☄️", dark: [Color(red: 0.12, green: 0.04, blue: 0.14), Color(red: 0.28, green: 0.06, blue: 0.24)],
              light: [Color(red: 0.98, green: 0.88, blue: 0.96), Color(red: 0.93, green: 0.88, blue: 1.0)]),
    ]
}

// MARK: - Карточка: аватар сверху, QR с анимированной орбитой в центре, юзернейм снизу

private struct QRShareCard: View {
    let link: String
    let name: String
    let username: String?
    let avatarID: String?
    let dark: Bool
    let style: QRBackdropStyle

    private var cardColor: Color { dark ? Color(red: 0.11, green: 0.115, blue: 0.16) : .white }
    private var qrColors: [Color] {
        dark ? [Color(red: 0.62, green: 0.74, blue: 1.0), Color(red: 0.78, green: 0.62, blue: 1.0)]
             : [Color(red: 0.07, green: 0.13, blue: 0.55), Color(red: 0.36, green: 0.10, blue: 0.55)]
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: dark ? style.dark : style.light, startPoint: .top, endPoint: .bottom)
            EmojiPattern(emoji: style.emoji, dark: dark)

            VStack(spacing: 0) {
                AvatarView(name: name, size: 116, avatarID: avatarID).clipShape(Circle())
                    .overlay(Circle().stroke(cardColor, lineWidth: 0))
                    .zIndex(1)
                    .padding(.bottom, -58)

                VStack(spacing: 18) {
                    GeometryReader { geo in
                        let side = geo.size.width
                        ZStack {
                            QRCodeView(text: link, colors: qrColors, clearRadius: 0.17)
                            OrbitLogo(size: side * 0.30, forceDarkTheme: dark)
                                .environment(\.theme, Theme(dark: dark))
                        }
                        .frame(width: side, height: side)
                    }
                    .aspectRatio(1, contentMode: .fit)

                    Text(username.map { "@" + $0.uppercased() } ?? name.uppercased())
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(LinearGradient(colors: qrColors, startPoint: .leading, endPoint: .trailing))
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                .padding(.horizontal, 26).padding(.top, 76).padding(.bottom, 26)
                .background(cardColor, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
                .padding(.horizontal, 44)
            }
        }
    }
}

// MARK: - Экран «QR-код»

struct ProfileQRScreen: View {
    let link: String
    let name: String
    let username: String?
    let avatarID: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var dark = true
    @State private var shareItems: ShareItems?
    @State private var showScanner = false
    @State private var didInit = false

    private var s: Strings { Strings(lang: lang) }
    private var style: QRBackdropStyle { QRBackdropStyle.all[0] }

    var body: some View {
        ZStack(alignment: .bottom) {
            QRShareCard(link: link, name: name, username: username, avatarID: avatarID, dark: dark, style: style)
                .environment(\.theme, Theme(dark: dark))
                .padding(.bottom, 240)
                .background { (dark ? style.dark[0] : style.light[0]).ignoresSafeArea() }
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.3), value: dark)

            panel
        }
        .preferredColorScheme(theme.dark ? .dark : .light)
        .onAppear { if !didInit { didInit = true; dark = theme.dark } }
        .sheet(item: $shareItems) { ActivitySheet(items: $0.items).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showScanner) {
            QRScannerScreen(onApproved: { showScanner = false })
                .preferredColorScheme(theme.dark ? .dark : .light)
        }
    }

    private var panel: some View {
        VStack(spacing: 14) {
            HStack {
                circleButton("xmark") { dismiss() }
                Spacer()
                Text(s.t("QR-код", "QR code")).font(.system(size: 17, weight: .bold)).foregroundStyle(theme.text)
                Spacer()
                circleButton(dark ? "sun.max" : "moon.stars") {
                    Haptics.impact(.light)
                    withAnimation { dark.toggle() }
                }
            }

            Button(action: share) {
                Text(s.t("Поделиться", "Share")).font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.dark ? Color.black : Color.white)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(theme.dark ? Color.white : Color.black, in: Capsule())
            }
            .buttonStyle(PressStyle())

            Button { showScanner = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                    Text(s.t("Сканировать QR-код", "Scan QR code")).font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(theme.text)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(theme.surface, in: Capsule())
            }
            .buttonStyle(PressStyle())
        }
        .padding(16)
        .background(theme.sheet, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 6).padding(.bottom, 6)
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium)).foregroundStyle(theme.text)
                .frame(width: 46, height: 46).glassCircle()
        }
        .buttonStyle(.plain)
    }

    /// Рисуем карточку в картинку и отдаём в «Поделиться»
    @MainActor
    private func share() {
        let card = QRShareCard(link: link, name: name, username: username, avatarID: avatarID, dark: dark, style: style)
            .environment(\.theme, Theme(dark: dark))
            .frame(width: 390, height: 640)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        var items: [Any] = []
        if let image = renderer.uiImage { items.append(image) }
        items.append(link)
        shareItems = ShareItems(items: items)
    }
}
