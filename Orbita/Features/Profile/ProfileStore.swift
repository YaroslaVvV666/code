import SwiftUI
import Combine

/// Профиль пользователя на сервере: имя, @username, о себе, фотографии, приватность
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profile: UserProfile?
    @Published private(set) var loadError: APIError?

    let repo: ProfileRepository

    init(repo: ProfileRepository) {
        self.repo = repo
    }

    func load() async {
        do {
            profile = try await repo.load()
            loadError = nil
        } catch {
            loadError = (error as? APIError) ?? .offline
        }
    }

    /// nil — всё прошло успешно
    @discardableResult
    func update(_ patch: ProfilePatch) async -> APIError? {
        do {
            profile = try await repo.update(patch)
            return nil
        } catch {
            return (error as? APIError) ?? .offline
        }
    }

    // MARK: Фотографии профиля

    /// Обрезает фото до квадрата, загружает и добавляет в начало галереи
    @discardableResult
    func addPhoto(from data: Data) async -> APIError? {
        guard let jpeg = ImageProcessing.avatar(data) else { return .invalidResponse }
        do {
            let id = try await repo.uploadAvatar(jpeg)
            profile = try await repo.addAvatar(mediaID: id)
            return nil
        } catch {
            return (error as? APIError) ?? .offline
        }
    }

    @discardableResult
    func removePhoto(_ id: String) async -> APIError? {
        do {
            profile = try await repo.deleteAvatar(id: id)
            return nil
        } catch {
            return (error as? APIError) ?? .offline
        }
    }

    @discardableResult
    func reorderPhotos(_ ids: [String]) async -> APIError? {
        do {
            profile = try await repo.reorderAvatars(ids)
            return nil
        } catch {
            return (error as? APIError) ?? .offline
        }
    }

    func usernameStatus(_ username: String) async -> UsernameStatus {
        (try? await repo.usernameStatus(username)) ?? .unknown
    }
}

/// Сеансы: на каких устройствах открыт аккаунт
@MainActor
final class DevicesStore: ObservableObject {
    @Published private(set) var sessions: [DeviceSession] = []
    @Published private(set) var loaded = false
    @Published var error: APIError?

    private let repo: ProfileRepository

    init(repo: ProfileRepository) { self.repo = repo }

    var current: DeviceSession? { sessions.first { $0.isCurrent } }
    var others: [DeviceSession] { sessions.filter { !$0.isCurrent } }

    func load() async {
        do {
            sessions = try await repo.sessions()
            error = nil
        } catch {
            self.error = (error as? APIError) ?? .offline
        }
        loaded = true
    }

    func terminate(_ session: DeviceSession) async {
        do {
            try await repo.terminateSession(id: session.id)
            sessions.removeAll { $0.id == session.id }
        } catch {
            self.error = (error as? APIError) ?? .offline
        }
    }

    func terminateOthers() async {
        do {
            try await repo.terminateOtherSessions()
            sessions = sessions.filter(\.isCurrent)
        } catch {
            self.error = (error as? APIError) ?? .offline
        }
    }
}

/// Ссылки, которыми открыли приложение: вход по QR или чужой профиль
@MainActor
final class LinkRouter: ObservableObject {
    @Published var pending: DeepLink?
    @Published var serverApplied: String?       // адрес сервера из QR-кода терминала

    func handle(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        if case .server(let address) = link {
            applyServer(address)
        } else {
            pending = link
        }
    }

    func applyServer(_ address: String) {
        ServerConfig.urlString = address
        serverApplied = address
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if serverApplied == address { serverApplied = nil }
        }
    }
}
