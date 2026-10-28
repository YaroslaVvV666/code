import SwiftUI
import Combine

enum ProfileRoute: Hashable {
    case name, username, bio
    case privacy, appearance, language, data, server, twoFA, devices
    case wall, blacklist, loginEmail, style, interests
    case visibility(String)
}

/// Всё, что живёт, пока пользователь вошёл: клиент сервера, лента, профиль
@MainActor
final class AppSession: ObservableObject {
    @Published var profileRoute: ProfileRoute?
    /// Нижняя панель вкладок прячется, пока в «Шортсах» открыты комментарии
    @Published var tabBarHidden = false
    /// Шортс, присланный в чат: нажатие переносит во вкладку «Шортс», где этот ролик идёт первым
    @Published var reelRequest: Post?
    /// Кто сейчас держит звук выключенным (экраны съёмки и публикации). Пока множество не пустое — шортсы и плееры молчат
    @Published var mediaHolds: Set<UUID> = []
    var mediaHeld: Bool { !mediaHolds.isEmpty }
    /// Просьба из любого экрана переключить вкладку (MainTabView её исполняет)
    @Published var tabRequest: MainTab?
    /// Двухфакторный экран открыт из «Конфиденциальности» — «назад» вернёт туда
    var privacyOrigin = false

    let feed: FeedViewModel
    /// Лента вкладки «Шортс» живёт дольше самого экрана: ушёл в другую вкладку и вернулся — тот же ролик
    let mainReels = ReelsModel()
    let taste: TasteTracker
    let profile: ProfileStore
    let devices: DevicesStore
    let profileRepo: ProfileRepository
    let feedRepo: FeedRepository
    let socialRepo: SocialRepository
    let messengerRepo: MessengerRepository
    let extras: ExtrasAPI
    let chats: ChatsModel
    let player = AudioPlayer()
    let calls: CallManager
    /// Общий long-poll: экраны обновляются по событию с сервера, а не по частому таймеру
    let live: LiveEvents
    let userID: String
    /// Идентификатор в формате сервера (нижний регистр): им сравниваются «я» и чужие id
    let serverID: String
    private let api: ServerAPI
    private var listenBag: AnyCancellable?
    private var listenTask: Task<Void, Never>?

    init(userID: String, userName: String) {
        let api = ServerAPI(userID: userID, displayName: userName)
        self.api = api
        self.userID = userID
        self.serverID = userID.lowercased()
        profileRepo = RemoteProfileRepository(api: api)
        feedRepo = RemoteFeedRepository(api: api)
        socialRepo = RemoteSocialRepository(api: api)
        messengerRepo = RemoteMessengerRepository(api: api)
        extras = ExtrasAPI(api: api)
        taste = TasteTracker(extras: extras)
        chats = ChatsModel(repo: messengerRepo)
        calls = CallManager(repo: CallRepository(api: api))
        live = LiveEvents(api: api)
        feed = FeedViewModel(repo: feedRepo)
        profile = ProfileStore(repo: profileRepo)
        devices = DevicesStore(repo: profileRepo)
        let ex = extras
        BookmarkStore.onChange = { id, saved in Task { await ex.setSaved(id: id, saved: saved) } }
        reportListening()
    }

    /// Пока играет музыка, сервер знает «человек слушает» (раз в 20 с) — у других на его странице аватарка оживает
    private func reportListening() {
        listenBag = player.$isPlaying.removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            self.listenTask?.cancel()
            let repo = self.socialRepo
            self.listenTask = Task {
                if on {
                    while !Task.isCancelled {
                        await repo.setListening(true)
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                    }
                } else {
                    await repo.setListening(false)
                }
            }
        }
    }

    /// Разовая выгрузка локальных закладок на сервер (идемпотентно)
    func syncSaves() async { await extras.syncSaves(ids: BookmarkStore.shared.ids) }

    /// Выход: завершаем этот сеанс на сервере
    func signOutRemote() async {
        if let token = await PushManager.shared.token {          // устройство больше не получает уведомления
            _ = try? await api.request("DELETE", "/v1/me/push", body: ServerAPI.json(["token": token]))
        }
        await api.signOut()
    }

    /// Передаёт серверу токен устройства для push
    func uploadPush(token: String) async {
        _ = try? await api.request("PUT", "/v1/me/push",
                                   body: ServerAPI.json(["token": token, "env": PushManager.environment]))
    }

    /// Интересы для ленты «Для вас»
    func pushInterests(_ topics: [String]) async {
        _ = try? await api.request("PUT", "/v1/me/interests", body: ServerAPI.json(["topics": topics]))
        await feed.load()
    }

    /// При входе: локальный выбор уходит на сервер, а на новом устройстве подтягивается с сервера
    func syncInterests() async {
        if InterestsStore.hasAnswered(userID) {
            _ = try? await api.request("PUT", "/v1/me/interests", body: ServerAPI.json(["topics": InterestsStore.load(userID)]))
        } else if let data = try? await api.request("GET", "/v1/me/interests"),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["set"] as? Bool == true, let topics = obj["topics"] as? [String] {
            InterestsStore.save(topics, user: userID)
        }
    }

    /// После смены адреса сервера
    func reloadAll() async {
        await profile.load()
        await feed.load()
    }

    func deleteRemoteAccount() async {
        try? await profileRepo.deleteAccount()
    }
}


/// Экран съёмки или публикации: шортс под ним ставится на паузу и не играет, пока экран открыт.
/// Музыка останавливается только там, где идёт запись (съёмка шортса) — при создании поста или записи на стену она играет дальше
private struct HoldsMedia: ViewModifier {
    var stopsMusic: Bool
    @EnvironmentObject private var session: AppSession
    @State private var token = UUID()
    func body(content: Content) -> some View {
        content
            .onAppear {
                session.mediaHolds.insert(token)
                if stopsMusic { session.player.stop() }
            }
            .onDisappear { session.mediaHolds.remove(token) }
    }
}

extension View {
    func holdsMedia(stopsMusic: Bool = true) -> some View { modifier(HoldsMedia(stopsMusic: stopsMusic)) }
}
