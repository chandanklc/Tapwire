import Foundation
import Observation
import TapwireCore

enum PausePhase: String {
    case request, response
}

/// A call held at a breakpoint. The editor edits `request` / `response` in place.
@MainActor
@Observable
final class PausedCall: Identifiable {
    let id = UUID()
    let info: PausedCallInfo
    let phase: PausePhase
    let originalRequest: EditableRequest
    let originalResponse: EditableResponse?
    var request: EditableRequest
    var response: EditableResponse?
    var clientDisconnected = false

    @ObservationIgnored var requestContinuation: CheckedContinuation<BreakpointDecision<EditableRequest>, Never>?
    @ObservationIgnored var responseContinuation: CheckedContinuation<BreakpointDecision<EditableResponse>, Never>?

    init(info: PausedCallInfo, phase: PausePhase, request: EditableRequest, response: EditableResponse?) {
        self.info = info
        self.phase = phase
        self.originalRequest = request
        self.originalResponse = response
        self.request = request
        self.response = response
    }

    var title: String {
        let url = ParsedURL(string: request.url)
        return "\(request.method) \(url?.authority ?? "")\(url?.path ?? request.url)"
    }
}

/// Holds paused calls in a queue until the user picks Execute / Abort / Continue.
@MainActor
@Observable
final class BreakpointCoordinator: BreakpointHandler {
    private(set) var queue: [PausedCall] = []
    var selectedID: UUID?
    /// Called when a call is paused (the app opens the editor window).
    @ObservationIgnored var onPause: (() -> Void)?

    nonisolated init() {}

    var selected: PausedCall? {
        if let selectedID, let c = queue.first(where: { $0.id == selectedID }) { return c }
        return queue.first
    }

    nonisolated func pauseRequest(_ info: PausedCallInfo, request: EditableRequest) async -> BreakpointDecision<EditableRequest> {
        await withCheckedContinuation { cont in
            Task { @MainActor in
                let call = PausedCall(info: info, phase: .request, request: request, response: nil)
                call.requestContinuation = cont
                self.enqueue(call)
            }
        }
    }

    nonisolated func pauseResponse(_ info: PausedCallInfo, request: EditableRequest,
                                   response: EditableResponse) async -> BreakpointDecision<EditableResponse> {
        await withCheckedContinuation { cont in
            Task { @MainActor in
                let call = PausedCall(info: info, phase: .response, request: request, response: response)
                call.responseContinuation = cont
                self.enqueue(call)
            }
        }
    }

    private func enqueue(_ call: PausedCall) {
        queue.append(call)
        if selectedID == nil || !queue.contains(where: { $0.id == selectedID }) { selectedID = call.id }
        call.info.liveness.onClose { [weak call] in
            Task { @MainActor in call?.clientDisconnected = true }
        }
        onPause?()
    }

    enum Action { case execute, abort, continueOriginal }

    func resolve(_ call: PausedCall, _ action: Action) {
        switch call.phase {
        case .request:
            let decision: BreakpointDecision<EditableRequest>
            switch action {
            case .execute: decision = .execute(call.request)
            case .abort: decision = .abort
            case .continueOriginal: decision = .continueOriginal
            }
            call.requestContinuation?.resume(returning: decision)
            call.requestContinuation = nil
        case .response:
            let decision: BreakpointDecision<EditableResponse>
            switch action {
            case .execute: decision = call.response.map { .execute($0) } ?? .continueOriginal
            case .abort: decision = .abort
            case .continueOriginal: decision = .continueOriginal
            }
            call.responseContinuation?.resume(returning: decision)
            call.responseContinuation = nil
        }
        let idx = queue.firstIndex { $0.id == call.id }
        queue.removeAll { $0.id == call.id }
        if let idx, !queue.isEmpty {
            selectedID = queue[min(idx, queue.count - 1)].id
        } else {
            selectedID = queue.first?.id
        }
    }

    /// Lets every paused call continue unchanged (used when stopping the proxy or disabling breakpoints).
    func releaseAll() {
        for call in queue { resolve(call, .continueOriginal) }
    }

    func select(offset: Int) {
        guard let cur = selected, let i = queue.firstIndex(where: { $0.id == cur.id }), !queue.isEmpty else { return }
        selectedID = queue[(i + offset + queue.count) % queue.count].id
    }
}
