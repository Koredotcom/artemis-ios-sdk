import SwiftUI

extension RichTemplateContext {
    @MainActor func perform(
        _ id: String, value: String? = nil, formData: [String: String]? = nil,
        renderId: String? = nil, displayText: String? = nil
    ) async throws {
        if let performAction {
            try await performAction(id, value, formData, renderId, displayText)
        } else {
            submitAction(id, value, formData, renderId)
        }
    }
    var submittedActionId: String? {
        message.actions?.submittedActionId
    }
    var submittedActionIds: [String] {
        message.actions?.submittedActionIds ?? submittedActionId.map { [$0] } ?? []
    }
}
