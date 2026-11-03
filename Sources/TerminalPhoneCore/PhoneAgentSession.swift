import Foundation

/// One serialized control context. It has no terminal, transport or platform dependencies.
@MainActor
public final class PhoneAgentSession {
    public let id = UUID().uuidString.lowercased()
    private let startedAt = Date()
    private let backend: PhoneBackend
    private let artifacts: URL
    private let inputAllowed: () throws -> Bool
    private let acquireControl: () throws -> AnyObject
    private var control: AnyObject?
    private var latest: (observation: PhoneObservation, scene: PhoneScene)?
    private var busy = false
    private var remembered: [String: (PhoneAgentRequest, PhoneAgentReply)] = [:]
    private var requestOrder: [String] = []
    private var imageOrder: [URL] = []
    private let inputQueue = PhoneWorkQueue()
    private var inputEpoch = 0
    private var humanActiveUntil = Date.distantPast
    private var pendingIDs: Set<String> = []
    private struct DeliveryFailure: Error { let kind: PhoneAction.Kind; let error: AgentError }

    public init(backend: PhoneBackend, artifacts: URL, inputAllowed: @escaping () throws -> Bool,
                acquireControl: @escaping () throws -> AnyObject) {
        self.backend = backend; self.artifacts = artifacts
        self.inputAllowed = inputAllowed; self.acquireControl = acquireControl
        let existing = (try? FileManager.default.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        imageOrder = existing.filter { $0.lastPathComponent.range(of: "^[a-f0-9-]{36}-s[a-f0-9-]{36}\\.png$", options: .regularExpression) != nil }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
                      ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }

    public var info: PhoneSessionInfo {
        let phone = backend.phone
        return PhoneSessionInfo(id: id, name: phone.name, udid: phone.udid,
                                kind: phone.isDevice ? "device" : "simulator", startedAt: startedAt,
                                inputAllowed: (try? inputAllowed()) ?? false, controlsInput: control != nil)
    }

    public func close() { latest = nil; control = nil; backend.close() }

    public func handle(_ request: PhoneAgentRequest, isCancelled: @escaping () -> Bool = { false }) async -> PhoneAgentReply {
        func reply(_ error: AgentError? = nil, observation: PhoneObservation? = nil,
                   capabilities: PhoneCapabilities? = nil, action: PhoneActionReceipt? = nil) -> PhoneAgentReply {
            PhoneAgentReply(schemaVersion: PhoneAgentAPI.version, id: request.id, ok: error == nil, session: info,
                            observation: observation, capabilities: capabilities, action: action, error: error)
        }
        if let prior = remembered[request.id] {
            return prior.0 == request ? prior.1 : reply(AgentError(.requestConflict, "This request ID was already used with different arguments."))
        }
        guard pendingIDs.insert(request.id).inserted else { return reply(AgentError(.controllerBusy, "This request is already running. Wait for its result.")) }
        defer { pendingIDs.remove(request.id) }
        let exclusive = ![PhoneAgentRequest.Operation.input, .status, .capabilities].contains(request.operation)
        guard !exclusive || !busy else { return reply(AgentError(.controllerBusy, "Another agent request is still running.", recovery: "Wait for the pending operation to finish.")) }
        if exclusive { busy = true }
        defer { if exclusive { busy = false } }
        let epoch = inputEpoch
        let cancelled = { isCancelled() || (request.operation != .input && epoch != self.inputEpoch) }
        var receipt: PhoneActionReceipt?
        var observation: PhoneObservation?
        let result: PhoneAgentReply
        do {
            try request.validate()
            try checkCancellation(cancelled)
            if let expected = request.sessionId, expected != id {
                throw AgentError(.staleReference, "The requested session has ended.", recovery: "Start with a new observation; do not replay the previous action.")
            }
            let allowed = try inputAllowed()
            let capabilities = backend.capabilities(inputAllowed: allowed)
            if request.condition?.app != nil && !capabilities.foregroundApp {
                throw AgentError(.unsupported, "This backend cannot identify the foreground app reliably. Wait for a UI element instead.")
            }
            switch request.operation {
            case .status: result = reply()
            case .capabilities: result = reply(capabilities: capabilities)
            case .release:
                inputEpoch += 1
                await inputQueue.run(priority: true) { latest = nil; control = nil }
                result = reply()
            case .observe:
                latest = nil
                let capture = try await backend.capture()
                try checkCancellation(cancelled)
                observation = try publish(capture, includeImage: request.includeImage)
                result = reply(observation: observation)
            case .wait:
                let (capture, matched) = try await wait(for: request.condition!, timeout: request.timeout, isCancelled: cancelled)
                observation = try publish(capture, includeImage: request.includeImage)
                result = reply(matched ? nil : AgentError(.waitTimeout, "The expected state did not appear within \(request.timeout) seconds.", recovery: "Inspect the returned observation before continuing."), observation: observation)
            case .input:
                guard allowed else { throw AgentError(.inputDisabled, "Enable control for this iPhone first.") }
                try claimControl()
                inputEpoch += 1; latest = nil; humanActiveUntil = Date().addingTimeInterval(0.75)
                receipt = try await deliver(request.action!, target: nil, priority: true, isCancelled: isCancelled)
                latest = nil; humanActiveUntil = Date().addingTimeInterval(0.75)
                result = reply(action: receipt)
            case .act:
                let action = request.action!
                guard allowed else { throw AgentError(.inputDisabled, "Input is disabled for this phone.", recovery: "The owner must enable input during real-device setup.") }
                guard Date() >= humanActiveUntil else { throw AgentError(.controllerBusy, "You are using the phone.", recovery: "Let the person finish, then observe again before continuing.") }
                guard capabilities.actions.contains(action.kind) else { throw AgentError(.unsupported, "This backend does not support \(action.kind.rawValue).") }
                try claimControl()
                let appAction = [PhoneAction.Kind.install, .launch, .open].contains(action.kind)
                let current = appAction ? nil : try await backend.capture()
                try checkCancellation(cancelled)
                let target = try current.flatMap { try resolve(action.target, scene: $0.scene) }
                if let points = action.coordinates, let current {
                    for index in stride(from: 0, to: points.count, by: 2) {
                        guard points[index] < current.scene.width, points[index + 1] < current.scene.height else {
                            throw AgentError(.invalidRequest, "Coordinates are outside the current \(current.scene.width)×\(current.scene.height) display.")
                        }
                    }
                }
                try checkCancellation(cancelled)
                latest = nil // Even a failed or timed-out input invalidates all prior references.
                receipt = try await deliver(action, target: target, isCancelled: cancelled)
                if let condition = request.condition {
                    let (capture, matched) = try await wait(for: condition, timeout: request.timeout, isCancelled: cancelled)
                    observation = try publish(capture, includeImage: request.includeImage)
                    receipt = PhoneActionReceipt(kind: action.kind, outcome: "input-delivered", verified: matched)
                    if !matched { throw AgentError(.waitTimeout, "Input was delivered, but the expected state did not appear.", recovery: "Inspect the returned observation. Do not blindly repeat the input.") }
                } else if request.observeAfter {
                    do {
                        let capture = try await backend.capture()
                        try checkCancellation(cancelled)
                        observation = try publish(capture, includeImage: request.includeImage)
                    }
                    catch { throw AgentError(.observationFailed, "Input was delivered, but observation failed: \(error.localizedDescription)", recovery: "Observe again. Do not repeat the input just to get a screenshot.") }
                }
                result = reply(observation: observation, action: receipt)
            }
        } catch let failure as DeliveryFailure {
            receipt = PhoneActionReceipt(kind: failure.kind, outcome: "unknown", verified: false)
            result = reply(failure.error, observation: observation, action: receipt)
        } catch {
            result = reply(AgentError.backend(error), observation: observation, action: receipt)
        }
        remembered[request.id] = (request, result); requestOrder.append(request.id)
        if requestOrder.count > 128 { remembered.removeValue(forKey: requestOrder.removeFirst()) }
        return result
    }

    private func claimControl() throws {
        if control != nil { return }
        do { control = try acquireControl() }
        catch { throw AgentError(.controllerBusy, "This phone is connected to another terminal-phone workspace.", recovery: "Use the same phone registry, or stop the other workspace's session.") }
    }

    private func deliver(_ action: PhoneAction, target: PhoneElement?, priority: Bool = false, isCancelled: @escaping () -> Bool) async throws -> PhoneActionReceipt {
        try await inputQueue.run(priority: priority) {
            try claimControl()
            try checkCancellation(isCancelled)
            do { try await backend.perform(action, target: target) }
            catch {
                if let known = error as? AgentError, [.invalidRequest, .unsupported, .targetNotFound, .ambiguousTarget, .targetDisabled, .staleReference, .deviceLocked, .inputDisabled].contains(known.code) { throw known }
                throw DeliveryFailure(kind: action.kind, error: AgentError(.actionOutcomeUnknown, error.localizedDescription,
                    recovery: "The input may already have reached iOS. Observe before deciding whether to try another action."))
            }
            return PhoneActionReceipt(kind: action.kind, outcome: "input-delivered", verified: false)
        }
    }

    private func resolve(_ selector: ElementSelector?, scene: PhoneScene) throws -> PhoneElement? {
        guard let selector else { return nil }
        let target: PhoneElement
        if let ref = selector.ref {
            guard let latest, latest.scene == scene,
                  let match = latest.observation.elements.first(where: { $0.ref == ref }) else {
                throw AgentError(.staleReference, "The element reference is no longer current.", recovery: "Observe again and use a reference from that observation.")
            }
            target = match.element
        } else {
            let matches = scene.elements.filter(selector.matches)
            guard let first = matches.first else { throw AgentError(.targetNotFound, "No on-screen element matches the selector.") }
            guard matches.count == 1 else { throw AgentError(.ambiguousTarget, "\(matches.count) elements match the selector. Use a reference or a more specific selector.") }
            target = first
        }
        guard target.enabled else { throw AgentError(.targetDisabled, "The target element is disabled.") }
        return target
    }

    private func checkCancellation(_ cancelled: () -> Bool) throws {
        if Task.isCancelled || cancelled() { throw AgentError(.cancelled, "This request was cancelled.", recovery: "Observe before deciding on any further input.") }
    }

    private func wait(for condition: PhoneWaitCondition, timeout: Double, isCancelled: () -> Bool) async throws -> (PhoneCapture, Bool) {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeout * 1000)))
        while true {
            try checkCancellation(isCancelled)
            let capture = try await backend.capture()
            try checkCancellation(isCancelled)
            if condition.matches(capture.scene) { return (capture, true) }
            guard clock.now < deadline else { return (capture, false) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func publish(_ capture: PhoneCapture, includeImage: Bool) throws -> PhoneObservation {
        let scene = capture.scene
        guard (1...8192).contains(scene.width), (1...8192).contains(scene.height), scene.scale.isFinite, scene.scale > 0 else {
            throw AgentError(.observationFailed, "The backend returned invalid screen geometry.")
        }
        let observationId = "s" + UUID().uuidString.lowercased()
        var image: String?
        if includeImage {
            guard !capture.png.isEmpty else { throw AgentError(.observationFailed, "The backend returned an empty screenshot.") }
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = artifacts.appendingPathComponent("\(id)-\(observationId).png")
            try capture.png.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            imageOrder.append(url); image = url.path
            while imageOrder.count > 16 { try? FileManager.default.removeItem(at: imageOrder.removeFirst()) }
        }
        let observation = PhoneObservation(id: observationId, sessionId: id, name: backend.phone.name,
                                           udid: backend.phone.udid, kind: backend.phone.isDevice ? "device" : "simulator",
                                           capturedFrom: capture.startedAt, capturedAt: capture.finishedAt, coordinateSpace: "display-points",
                                           width: scene.width, height: scene.height, scale: scene.scale, orientation: scene.orientation,
                                           app: scene.app, screenshot: image,
                                           elements: scene.elements.enumerated().map { ObservedElement(ref: "\(observationId):e\($0.offset + 1)", element: $0.element) },
                                           consistency: "sequential-capture")
        latest = (observation, scene)
        return observation
    }
}
