import SwiftUI

// MARK: - Устройства: где открыт аккаунт

struct DevicesScreen: View {
    @ObservedObject var store: DevicesStore

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var scanning = false
    @State private var target: DeviceSession?
    @State private var confirmAll = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                header(s.thisDevice)
                if let current = store.current {
                    SettingsGroup { row(current) }
                } else if !store.loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
                }
            }

            connectButton

            if !store.others.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    header(s.activeSessions)
                    SettingsGroup {
                        ForEach(Array(store.others.enumerated()), id: \.element.id) { item in
                            row(item.element)
                            if item.offset < store.others.count - 1 { Divider().overlay(theme.stroke).padding(.leading, 74) }
                        }
                    }
                    Text(s.sessionsHint)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 30)
                }

                Button { confirmAll = true } label: {
                    Text(s.terminateOthers)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(theme.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .card(theme, radius: 16)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(PressStyle())
            }

            Text(s.devicesHint)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 30)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let error = store.error {
                Text(s.api(error)).font(.system(size: 13)).foregroundStyle(theme.danger).padding(.horizontal, 30)
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

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 30)
    }

    private var connectButton: some View {
        Button {
            Haptics.impact(.light)
            scanning = true
        } label: {
            Label(s.connectDevice, systemImage: "qrcode.viewfinder")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .glass(RoundedRectangle(cornerRadius: 18, style: .continuous), tint: theme.accentColor, interactive: true)
                .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    private func row(_ item: DeviceSession) -> some View {
        Button {
            if !item.isCurrent { target = item }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: deviceSymbol(item.device))
                    .font(.system(size: 20))
                    .foregroundStyle(theme.accentColor)
                    .frame(width: 46, height: 46)
                    .background(theme.accentColor.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.device == "Unknown device" ? s.unknownDevice : item.device)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.text)
                    let details = [item.app, item.system].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !details.isEmpty {
                        Text(details).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    }
                    HStack(spacing: 6) {
                        if item.isCurrent { Circle().fill(Color.green).frame(width: 6, height: 6) }
                        Text(item.isCurrent ? s.online : s.lastSeen(item.lastActive))
                        if !item.ip.isEmpty { Text("·"); Text(item.ip) }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}
