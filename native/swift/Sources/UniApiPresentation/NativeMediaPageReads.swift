import Foundation
import Combine
import UniApiCore

/// Selected-content reads outlive a button Task, but never its selection or
/// visible read generation. Command errors and accepted external opens retain
/// their separate ownership in the page/service.
@MainActor package final class NativeMediaPageReads: ObservableObject {
    package let scope = NativePageReadScope()
    @Published package private(set) var selection: String?
    @Published package private(set) var detailError: String?
    @Published package private(set) var previewError: String?
    package struct PreviewOwner {
        fileprivate let selection: String
        fileprivate let ticket: NativePageReadScope.Ticket
    }

    package init() {}

    package func select(_ id: String?) {
        guard id != selection else { return }
        scope.invalidate("detail")
        scope.invalidate("preview")
        detailError = nil
        previewError = nil
        selection = id
    }

    package func loadDetail(read: (String) async throws -> JSONValue,
                            publish: (JSONValue) -> Void,
                            failed: () -> Void = {}) async {
        guard let id = selection, let ticket = scope.begin("detail") else { return }
        do {
            let value = try await read(id)
            guard selection == id, scope.accepts(ticket) else { return }
            detailError = nil
            publish(value)
        } catch {
            guard selection == id, scope.accepts(ticket) else { return }
            detailError = error.localizedDescription
            failed()
        }
    }

    /// Capture synchronously in the button callback, before creating its Task.
    package func beginPreview() -> PreviewOwner? {
        guard let id = selection, let ticket = scope.begin("preview") else { return nil }
        previewError = nil
        return PreviewOwner(selection: id, ticket: ticket)
    }

    private func accepts(_ owner: PreviewOwner) -> Bool {
        selection == owner.selection && scope.accepts(owner.ticket)
    }

    package func preview(owner: PreviewOwner,
                         read: () async throws -> JSONValue,
                         publish: (JSONValue) -> Void) async {
        guard accepts(owner) else { return }
        do {
            let value = try await read()
            guard accepts(owner) else { return }
            publish(value)
        } catch {
            guard accepts(owner) else { return }
            previewError = error.localizedDescription
        }
    }

    package func open(fileName: String, owner: PreviewOwner?,
                      read: () async throws -> JSONValue,
                      present: (JSONValue) -> Void,
                      external: (JSONValue) -> Void,
                      commandFailure: (String) -> Void) async {
        // The immutable result metadata identifies internal-document intent
        // even if resolution throws before returning its kind/MIME. Reuse the
        // service's exact extension table; no file read or sniffing is needed.
        let intent = NativePromptFiles.type(name: fileName, sample: Data())
        let internalPreview = intent.kind == "html" || intent.mime == "image/svg+xml"
        do {
            let value = try await read()
            if value["kind"].string == "html" || value["mimeType"].string == "image/svg+xml" {
                guard let owner, accepts(owner) else { return }
                present(value)
            } else {
                // This is an already accepted external-open command, not a
                // preview publication. Changing selection must not cancel it.
                external(value)
            }
        } catch {
            if internalPreview {
                guard let owner, accepts(owner) else { return }
                previewError = error.localizedDescription
            } else {
                commandFailure(error.localizedDescription)
            }
        }
    }
}
