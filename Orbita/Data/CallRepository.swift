import Foundation

struct IceServer: Decodable, Equatable {
    let urls: [String]
    var username: String?
    var credential: String?
}

struct CallSignal: Decodable, Equatable {
    let call: String
    let kind: String            // offer | answer | ice | accepted | end
    let data: String
}

struct IncomingCall: Decodable, Equatable {
    let id: String
    let video: Bool
    let from: CallPeerDTO
    let ice: [IceServer]
}

struct CallPeerDTO: Decodable, Equatable {
    let id: String
    let name: String
    let username: String?
    let avatar: String?
    var peer: ChatPeer { ChatPeer(id: id, name: name, username: username, avatarID: avatar) }
}

struct CallPoll: Decodable {
    struct Current: Decodable { let id: String; let state: String; let video: Bool }
    let incoming: IncomingCall?
    let current: Current?
    let signals: [CallSignal]
}

struct CallRecord: Identifiable, Equatable {
    let id: String
    let mine: Bool
    let video: Bool
    let status: String
    let date: Date
    let duration: Double
    let peer: ChatPeer
}

private struct StartDTO: Decodable { let id: String; let ice: [IceServer] }
private struct AnswerDTO: Decodable { let ice: [IceServer]; let video: Bool }
private struct HistoryDTO: Decodable {
    struct Item: Decodable {
        let id: String; let mine: Bool; let video: Bool; let status: String
        let createdAt: Double; let duration: Double; let peer: CallPeerDTO
    }
    let calls: [Item]
}

struct CallRepository: Sendable {
    let api: ServerAPI

    func start(to userID: String, video: Bool) async throws -> (id: String, ice: [IceServer]) {
        let data = try await api.request("POST", "/v1/calls", body: ServerAPI.json(["to": userID, "video": video] as [String: Any]))
        let dto = try decodeAPI(StartDTO.self, from: data)
        return (dto.id, dto.ice)
    }

    func poll() async throws -> CallPoll {
        try decodeAPI(CallPoll.self, from: try await api.request("GET", "/v1/calls/poll"))
    }

    func signal(_ id: String, kind: String, data: String) async {
        _ = try? await api.request("POST", "/v1/calls/\(id)/signal",
                                   body: ServerAPI.json(["kind": kind, "data": data]))
    }

    func answer(_ id: String) async throws -> [IceServer] {
        let data = try await api.request("POST", "/v1/calls/\(id)/answer")
        return try decodeAPI(AnswerDTO.self, from: data).ice
    }

    func end(_ id: String) async {
        _ = try? await api.request("POST", "/v1/calls/\(id)/end")
    }

    func history() async throws -> [CallRecord] {
        let dto = try decodeAPI(HistoryDTO.self, from: try await api.request("GET", "/v1/calls/history"))
        return dto.calls.map {
            CallRecord(id: $0.id, mine: $0.mine, video: $0.video, status: $0.status,
                       date: Date(timeIntervalSince1970: $0.createdAt), duration: $0.duration, peer: $0.peer.peer)
        }
    }
}
