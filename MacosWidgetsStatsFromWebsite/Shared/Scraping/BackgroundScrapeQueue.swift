// Queues background checks so Ethan's "round robin" mode uses one account's
// Chromium at a time. Login cookies stay in each account's existing profile.
// Callers own browser teardown and release their turn only after it finishes.

import Foundation

final class BackgroundScrapeQueue {
    private struct Job {
        let id = UUID()
        let profileName: String
        let serialized: Bool
        let start: (@escaping () -> Void) -> Void
    }

    private var pending: [Job] = []
    private var active: Set<UUID> = []
    private var serializedJobID: UUID?
    private var isDraining = false

    func enqueue(
        profileName: String,
        serialized: Bool,
        start: @escaping (@escaping () -> Void) -> Void
    ) {
        pending.append(Job(profileName: profileName, serialized: serialized, start: start))
        drain()
    }

    private func drain() {
        // A synchronous completion may enqueue more work. Let this drain own
        // that work instead of recursively starting a second drain.
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        while !pending.isEmpty, serializedJobID == nil {
            if pending[0].serialized, !active.isEmpty { return }

            // FIFO also prevents a frequently refreshed account from starving
            // the others. Bulk checks already arrive in tracker/account order.
            let job = pending.removeFirst()
            active.insert(job.id)
            if job.serialized { serializedJobID = job.id }
            job.start { [weak self] in
                guard let self, self.active.remove(job.id) != nil else { return }
                if self.serializedJobID == job.id { self.serializedJobID = nil }
                self.drain()
            }
        }
    }
}
