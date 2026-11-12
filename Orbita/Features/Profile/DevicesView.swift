import SwiftUI
import Combine

// MARK: - Устройства: где открыт аккаунт (как «Устройства» в Telegram)

struct DevicesScreen: View {
    @ObservedObject var store: DevicesStore

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var scanning = false
    @State private var target: DeviceSession?
    @State private var confirmAll = false
    @State private var bob = false

    private var s: Strings { Strings(lang: lang) }
    private let red = Color(red: 0.93, green: 0.30, blue: 0.22)

    var body: some View {
        VStack(spacing: 0) {
            hero
            connectButton.padding(.top, 22)

            // ЭТО УСТРОЙСТВО
            sectionHeader(s.thisDevice).padding(.top, 30)
            if let current = store.current {
                group {
                    row(current)
                    if !store.others.isEmpty {
                        divider
                        Button { confirmAll = true } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "hand.raised")
                                    .font(.system(size: 22, weight: .regular))
                                    .foregroundStyle(red)
                                    .frame(width: 40)
                                Text(s.terminateOthers)
                                    .font(.system(size: 17))
                                    .foregroundStyle(red)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16).frame(height: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowPressStyle())
                    }
                }
                if !store.others.isEmpty {
                    sectionFooter(s.t("Выйти на всех устройствах, кроме текущего.", "Log out on all devices except this one."))
                }
            } else if !store.loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            }

            // АКТИВНЫЕ СЕАНСЫ
            if !store.others.isEmpty {
                sectionHeader(s.activeSessions).padding(.top, 30)
                group {
                    ForEach(Array(store.others.enumerated()), id: \.element.id) { item in
                        row(item.element)
                        if item.offset < store.others.count - 1 { divider }
                    }
                }
                sectionFooter(s.t("Нажмите на сеанс, чтобы завершить его. Приложение Orbita есть для iPhone и iPad.",
                                  "Tap a session to end it. Orbita is available for iPhone and iPad."))
            }

            // АВТОМАТИЧЕСКИ ЗАВЕРШАТЬ СЕАНСЫ
            sectionHeader(s.t("Автоматически завершать сеансы", "Automatically terminate sessions")).padding(.top, 30)
            group {
                Menu {
                    ForEach([7, 30, 90, 180, 365], id: \.self) { d in
                        Button {
                            Haptics.select()
                            Task { await store.setTTL(d) }
                        } label: {
                            if d == store.ttlDays { Label(ttlTitle(d), systemImage: "checkmark") } else { Text(ttlTitle(d)) }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(s.t("Если сеанс неактивен", "If inactive for"))
                            .font(.system(size: 17)).foregroundStyle(theme.text)
                        Spacer(minLength: 8)
                        Text(ttlTitle(store.ttlDays))
                            .font(.system(size: 17)).foregroundStyle(theme.textSecondary)
                            .contentTransition(.numericText())
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    }
                    .padding(.horizontal, 18).frame(height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowPressStyle())
            }
            .animation(.easeOut(duration: 0.2), value: store.ttlDays)

            if let error = store.error {
                Text(s.api(error)).font(.system(size: 13)).foregroundStyle(theme.danger)
                    .padding(.horizontal, 34).padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await store.load() }
        .fullScreenCover(isPresented: $scanning) {
            QRScannerScreen { Task { await store.load() } }
                .preferredColorScheme(.dark)
        }
        .confirmationDialog(target.map { s.terminateQuestion($0.device) } ?? "",
                            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                            titleVisibility: .visible) {
            Button(s.terminateSession, role: .destructive) {
                if let item = target { Task { await store.terminate(item) } }
                target = nil
            }
            Button(s.cancel, role: .cancel) { target = nil }
        }
        .confirmationDialog(s.terminateOthers, isPresented: $confirmAll, titleVisibility: .visible) {
            Button(s.terminateOthers, role: .destructive) { Task { await store.terminateOthers() } }
            Button(s.cancel, role: .cancel) {}
        }
    }

    // MARK: Верх: картинка, подпись, «Подключить устройство»

    private var hero: some View {
        VStack(spacing: 18) {
            ZStack {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 104, weight: .thin))
                    .foregroundStyle(LinearGradient(colors: [theme.text.opacity(0.92), theme.text.opacity(0.55)],
                                                    startPoint: .top, endPoint: .bottom))
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(theme.accentColor)
                    .offset(y: -12)
                    .offset(y: bob ? -3 : 2)
            }
            .frame(height: 120)
            .onAppear { withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { bob = true } }

            (Text(s.t("Вы можете зайти в Orbita ", "You can log in to Orbita "))
             + Text(s.t("на другом устройстве", "on another device")).foregroundStyle(theme.accentColor)
             + Text(s.t(" с помощью QR-кода.", " with a QR code.")))
                .font(.system(size: 16))
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
        .padding(.top, 12)
    }

    private var connectButton: some View {
        Button {
            Haptics.impact(.light)
            scanning = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "qrcode").font(.system(size: 20, weight: .semibold))
                Text(s.connectDevice).font(.system(size: 18, weight: .bold))
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(theme.accentColor, in: Capsule())
            .padding(.horizontal, 16)
        }
        .buttonStyle(PressStyle())
    }

    // MARK: Разделы

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 34).padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionFooter(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 34).padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(theme.dark ? Color(white: 0.11) : Color.white,
                        in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.horizontal, 16)
    }

    private var divider: some View {
        Rectangle().fill(theme.stroke).frame(height: 0.5).padding(.leading, 72)
    }

    // MARK: Строка сеанса

    private func row(_ item: DeviceSession) -> some View {
        Button {
            if !item.isCurrent { Haptics.select(); target = item }
        } label: {
            HStack(alignment: .top, spacing: 16) {
                icon(item.device, app: item.app)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.device == "Unknown device" ? s.unknownDevice : item.device)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    let details = [item.app, item.system].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !details.isEmpty {
                        Text(details).font(.system(size: 15)).foregroundStyle(theme.text).lineLimit(1)
                    }
                    let place = item.ip.isEmpty ? "" : item.ip + " • "
                    Text(place + (item.isCurrent ? s.online : when(item.lastActive)))
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .contextMenu {
            if !item.isCurrent {
                Button(role: .destructive) { target = item } label: { Label(s.terminateSession, systemImage: "xmark.circle") }
            }
        }
    }

    /// Квадратный значок устройства, как в Telegram: телефон, планшет, компьютер, браузер
    private func icon(_ device: String, app: String) -> some View {
        let d = device.lowercased(), a = app.lowercased()
        let (symbol, color): (String, Color) = {
            if d.contains("ipad") { return ("ipad.landscape", Color(red: 0.25, green: 0.55, blue: 0.98)) }
            if d.contains("iphone") { return ("iphone", Color(red: 0.25, green: 0.55, blue: 0.98)) }
            if d.contains("mac") { return ("laptopcomputer", Color(red: 0.25, green: 0.55, blue: 0.98)) }
            if d.contains("android") { return ("candybarphone", Color(red: 0.35, green: 0.75, blue: 0.35)) }
            if a.contains("web") || d.contains("firefox") || d.contains("chrome") || d.contains("safari") {
                return ("globe", Color(red: 0.98, green: 0.6, blue: 0.2))
            }
            return ("square.grid.2x2.fill", Color(red: 0.25, green: 0.55, blue: 0.98))
        }()
        return Image(systemName: symbol)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// «6 часов назад», «вчера в 14:20», «27.10.26» — как в списке сеансов Telegram
    private func when(_ date: Date) -> String {
        let sec = Date().timeIntervalSince(date)
        if sec < 300 { return s.online }
        let cal = Calendar.current
        let locale = Locale(identifier: lang == .ru ? "ru_RU" : "en_US")
        if (sec < 86400 && cal.isDateInToday(date)) || sec < 6 * 3600 {
            let f = RelativeDateTimeFormatter()
            f.locale = locale
            f.unitsStyle = .full
            return f.localizedString(for: date, relativeTo: Date())
        }
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale))
        if cal.isDateInYesterday(date) { return s.t("вчера в ", "yesterday at ") + time }
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "dd.MM.yy"
        return f.string(from: date)
    }

    private func ttlTitle(_ days: Int) -> String {
        switch days {
        case 7: return s.t("1 неделя", "1 week")
        case 30: return s.t("1 месяц", "1 month")
        case 90: return s.t("3 месяца", "3 months")
        case 365: return s.t("1 год", "1 year")
        default: return s.t("6 месяцев", "6 months")
        }
    }
}

/// Нажатие на строку — она чуть подсвечивается, как ячейки в настройках iOS
private struct RowPressStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? theme.text.opacity(0.08) : Color.clear)
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.25), value: configuration.isPressed)
    }
}
