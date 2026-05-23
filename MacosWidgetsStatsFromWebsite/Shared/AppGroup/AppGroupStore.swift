//
//  AppGroupStore.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Observable configuration store with atomic JSON persistence.
//

import Combine
import Darwin
import Foundation

final class AppGroupStore: ObservableObject {
    private static let configurationMutationQueue = DispatchQueue(label: "com.ethansk.macos-widgets-stats-from-website.configuration-mutations")
    private static let readingsMutationQueue = DispatchQueue(label: "com.ethansk.macos-widgets-stats-from-website.readings-mutations")
    private static let configurationLockFileName = ".configuration.lock"
    private static let readingsLockFileName = ".readings.lock"

    @Published private(set) var schemaVersion: Int
    @Published var trackers: [Tracker]
    @Published var widgetConfigurations: [WidgetConfiguration]
    @Published var preferences: AppPreferences
    @Published private(set) var lastPersistenceError: String?

    init() {
        let configuration = Self.loadSharedConfiguration()
        schemaVersion = configuration.schemaVersion
        trackers = configuration.trackers
        widgetConfigurations = configuration.widgetConfigurations
        preferences = configuration.preferences
    }

    func addTracker(_ tracker: Tracker) {
        trackers.append(tracker)
        persist()
    }

    func updateTracker(_ tracker: Tracker) {
        guard let index = trackers.firstIndex(where: { $0.id == tracker.id }) else {
            addTracker(tracker)
            return
        }

        trackers[index] = tracker
        persist()
    }

    func upsertTracker(_ tracker: Tracker) {
        if trackers.contains(where: { $0.id == tracker.id }) {
            updateTracker(tracker)
        } else {
            addTracker(tracker)
        }
    }

    func duplicateTracker(_ tracker: Tracker) {
        var copy = tracker
        copy.id = UUID()
        copy.name = "\(tracker.name) Copy"
        trackers.append(copy)
        persist()
    }

    func deleteTracker(id: UUID) {
        trackers.removeAll { $0.id == id }
        widgetConfigurations = widgetConfigurations.map { configuration in
            var updated = configuration
            updated.trackerIDs.removeAll { $0 == id }
            return updated
        }
        persist()
    }

    func addWidgetConfiguration(_ configuration: WidgetConfiguration) {
        widgetConfigurations.append(configuration)
        persist()
    }

    func updateWidgetConfiguration(_ configuration: WidgetConfiguration) {
        guard let index = widgetConfigurations.firstIndex(where: { $0.id == configuration.id }) else {
            addWidgetConfiguration(configuration)
            return
        }

        widgetConfigurations[index] = configuration
        persist()
    }

    func upsertWidgetConfiguration(_ configuration: WidgetConfiguration) {
        if widgetConfigurations.contains(where: { $0.id == configuration.id }) {
            updateWidgetConfiguration(configuration)
        } else {
            addWidgetConfiguration(configuration)
        }
    }

    func deleteWidgetConfiguration(id: UUID) {
        widgetConfigurations.removeAll { $0.id == id }
        persist()
    }

    func moveTrackers(fromOffsets source: IndexSet, toOffset destination: Int) {
        let sortedSource = source.sorted()
        guard !sortedSource.isEmpty else {
            return
        }

        let movedTrackers = sortedSource.map { trackers[$0] }
        var reordered = trackers
        for index in sortedSource.reversed() {
            reordered.remove(at: index)
        }

        let adjustment = sortedSource.filter { $0 < destination }.count
        let adjustedDestination = max(0, min(destination - adjustment, reordered.count))
        reordered.insert(contentsOf: movedTrackers, at: adjustedDestination)
        trackers = reordered
        persist()
    }

    func persist() {
        do {
            let configuration = AppConfiguration(
                schemaVersion: currentSchemaVersion,
                trackers: trackers,
                widgetConfigurations: widgetConfigurations,
                preferences: preferences
            )
            try Self.save(configuration: configuration)

            schemaVersion = currentSchemaVersion
            lastPersistenceError = nil
            ActivityLogger.log("store", "saved configuration", metadata: [
                "trackers": "\(trackers.count)",
                "widgets": "\(widgetConfigurations.count)"
            ])
        } catch {
            lastPersistenceError = error.localizedDescription
            ActivityLogger.log("store", "configuration save failed", metadata: ["error": error.localizedDescription])
        }
    }

    func reloadFromDisk() {
        let configuration = Self.loadSharedConfiguration()
        schemaVersion = configuration.schemaVersion
        trackers = configuration.trackers
        widgetConfigurations = configuration.widgetConfigurations
        preferences = configuration.preferences
        lastPersistenceError = nil
        ActivityLogger.log("store", "reloaded configuration", metadata: [
            "trackers": "\(trackers.count)",
            "widgets": "\(widgetConfigurations.count)"
        ])
    }

    static func hasExistingConfigurationFile() -> Bool {
        let fileManager = FileManager.default
        let candidateURLs: [URL?] = [
            AppGroupPaths.canonicalTrackersURL(),
            AppGroupPaths.canonicalApplicationSupportURL().appendingPathComponent("config.json", isDirectory: false),
            AppGroupPaths.appGroupTrackersURL(),
            AppGroupPaths.sharedContainerURL()?.appendingPathComponent("config.json", isDirectory: false)
        ]

        return candidateURLs.compactMap { $0 }.contains { fileManager.fileExists(atPath: $0.path) }
    }

    // MARK: - Legacy App Group container migration

    /// Names of files copied from the legacy unprefixed App Group container
    /// (`group.com.ethansk.macos-widgets-stats-from-website`) into the
    /// team-prefixed container adopted in 0.12.7.  Anything outside this list
    /// (Logs/, Library/, .DS_Store, mcp.sock, lock files) is intentionally
    /// left behind so the new container starts clean.
    private static let legacyMigrationFileNames: [String] = [
        AppGroupPaths.trackersFileName,
        AppGroupPaths.readingsFileName
    ]

    private static let legacyMigrationCompletedDefaultsKey =
        "AppGroupStore.legacyDataMigrationCompleted"

    private static let legacyAppGroupIdentifier =
        "group.com.ethansk.macos-widgets-stats-from-website"

    /// One-time copy of user-data JSON from the legacy unprefixed App Group
    /// container into the new team-prefixed container.  Idempotent: skips
    /// files that already exist in the new container, persists a UserDefaults
    /// flag so it never repeats, and never throws — failures are logged and
    /// swallowed so the app keeps launching even on disk/permission errors.
    ///
    /// MUST be called before any code constructs `AppGroupStore` or calls
    /// `loadSharedConfiguration()`, because those write into the new
    /// container and would defeat the "new container is missing those files"
    /// guard below.
    static func migrateLegacyAppGroupContainerIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: legacyMigrationCompletedDefaultsKey) {
            return
        }

        // Skip migration entirely under the test-container override —
        // tests use a sandboxed temp dir and shouldn't touch ~/Library.
        if ProcessInfo.processInfo.environment["MACOS_WIDGETS_STATS_TEST_CONTAINER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            defaults.set(true, forKey: legacyMigrationCompletedDefaultsKey)
            return
        }

        let fileManager = FileManager.default

        guard let newContainerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupPaths.identifier
        ) else {
            // No new container yet (entitlements not active?). Leave the
            // flag unset so we retry on next launch when the container
            // exists.
            ActivityLogger.log(
                "store",
                "legacy migration skipped: new container unavailable"
            )
            return
        }

        let legacyContainerURL = legacyContainerDirectoryURL()
        var legacyExists: ObjCBool = false
        guard fileManager.fileExists(atPath: legacyContainerURL.path, isDirectory: &legacyExists),
              legacyExists.boolValue else {
            // No legacy container at all — fresh install, nothing to copy.
            // Mark complete so we don't keep checking on every launch.
            defaults.set(true, forKey: legacyMigrationCompletedDefaultsKey)
            ActivityLogger.log(
                "store",
                "legacy migration skipped: no legacy container",
                metadata: ["legacy": legacyContainerURL.path]
            )
            return
        }

        do {
            try fileManager.createDirectory(
                at: newContainerURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            ActivityLogger.log(
                "store",
                "legacy migration: failed to ensure new container directory",
                metadata: ["error": error.localizedDescription]
            )
            // Don't set the completed flag — try again next launch.
            return
        }

        var copiedAny = false
        var anyFailure = false

        for fileName in legacyMigrationFileNames {
            let sourceURL = legacyContainerURL.appendingPathComponent(fileName, isDirectory: false)
            let destinationURL = newContainerURL.appendingPathComponent(fileName, isDirectory: false)

            guard fileManager.fileExists(atPath: sourceURL.path) else {
                ActivityLogger.log(
                    "store",
                    "legacy migration: source missing",
                    metadata: ["file": fileName]
                )
                continue
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                ActivityLogger.log(
                    "store",
                    "legacy migration: destination already populated, skipping",
                    metadata: ["file": fileName]
                )
                continue
            }

            do {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                copiedAny = true
                ActivityLogger.log(
                    "store",
                    "legacy migration: copied file",
                    metadata: [
                        "file": fileName,
                        "from": sourceURL.path,
                        "to": destinationURL.path
                    ]
                )
            } catch {
                anyFailure = true
                ActivityLogger.log(
                    "store",
                    "legacy migration: copy failed",
                    metadata: [
                        "file": fileName,
                        "error": error.localizedDescription
                    ]
                )
            }
        }

        // Persist the flag so this never runs twice — even if a copy
        // failed, retrying on every launch would fight the user (e.g. they
        // intentionally deleted a file in the new container after launch).
        // Onboarding still works as a manual fallback if everything failed.
        defaults.set(true, forKey: legacyMigrationCompletedDefaultsKey)

        ActivityLogger.log(
            "store",
            "legacy migration completed",
            metadata: [
                "copied_any": copiedAny ? "true" : "false",
                "any_failure": anyFailure ? "true" : "false"
            ]
        )
    }

    private static func legacyContainerDirectoryURL() -> URL {
        // Group Containers always live at
        // ~/Library/Group Containers/<identifier>/ on macOS, regardless of
        // sandbox state — there's no FileManager API that resolves a path
        // for an identifier we no longer hold entitlements for, so build it
        // directly from the user's home directory.
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(legacyAppGroupIdentifier, isDirectory: true)
    }

    static func loadReadings() -> TrackerReadingsFile {
        loadReadingsUnlocked()
    }

    private static func loadReadingsUnlocked() -> TrackerReadingsFile {
        guard let url = AppGroupPaths.appGroupReadingsURL(),
              let data = try? Data(contentsOf: url) else {
            return .empty
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(TrackerReadingsFile.self, from: data)
            // v0.21.10 fix (Ethan voice 3902 — "no trackers" after the v0.21.9
            // upgrade). The previous strict `file.schemaVersion ==
            // currentSchemaVersion` gate silently rejected every pre-v0.21.9
            // readings.json on upgrade (currentSchemaVersion was bumped 4 → 5
            // in v0.21.9 to signal the additive multi-element-array schema),
            // dropping the file to `.empty` and wiping the user's tracker list
            // from the host app + widget extension on every load.
            //
            // The TrackerReading decoder already uses `decodeIfPresent` with
            // `?? [:]` defaults for the v0.21.9-added `secondaryValues` field
            // (see TrackerResult.swift), so an older schemaVersion=4 file
            // decodes cleanly into the current TrackerReadingsFile shape with
            // empty new fields — no data loss, no migration logic required.
            //
            // The strict gate was redundant with that decoder backcompat and
            // was the sole cause of the no-trackers regression. Relaxing to
            // `<=` lets v4 (and any earlier) files load via the existing
            // decoder path. NEWER files (someone downgraded after running a
            // future schema) are still rejected — we can't promise forward
            // compatibility with keys we don't know about, so .empty + fresh
            // save is the safe path there.
            //
            // The configuration load path at decodeConfiguration() already
            // has a migration fallback (try strict decode, then fall through
            // to migrateConfigurationObject for older schemas), so config was
            // surviving the upgrade — only readings were being wiped. This
            // change brings readings into symmetry with that pattern.
            guard file.schemaVersion <= currentSchemaVersion else {
                return .empty
            }
            return file
        } catch {
            return .empty
        }
    }

    static func reading(for trackerID: UUID) -> TrackerReading? {
        loadReadings().readings[trackerID.uuidString]
    }

    static func record(reading newReading: TrackerReading, for tracker: Tracker) throws {
        try withReadingsMutationLock {
            var file = loadReadingsUnlocked()
            let key = tracker.id.uuidString
            var reading = normalizedReading(newReading, existing: file.readings[key], for: tracker)
            // Always stamp lastAttemptedAt on persist so the CLI rate-limit
            // path can distinguish "haven't tried in N seconds" from "tried
            // but the page errored". Falls back to lastUpdatedAt for callers
            // that didn't supply one.
            if reading.lastAttemptedAt == nil {
                reading.lastAttemptedAt = reading.lastUpdatedAt ?? Date()
            }
            file.schemaVersion = currentSchemaVersion
            file.readings[key] = reading
            try write(readingsFile: file)
            ActivityLogger.log("store", "recorded reading", metadata: [
                "tracker": tracker.id.uuidString,
                "status": reading.status.rawValue
            ])
        }
    }

    @discardableResult
    static func recordFailure(message: String, for tracker: Tracker) throws -> TrackerReading {
        try withReadingsMutationLock {
            var file = loadReadingsUnlocked()
            let existing = file.readings[tracker.id.uuidString]
            let failureCount = (existing?.consecutiveFailureCount ?? 0) + 1
            let status: TrackerStatus = failureCount >= 3 ? .broken : .stale
            let reading = TrackerReading(
                currentValue: existing?.currentValue,
                currentNumeric: existing?.currentNumeric,
                snapshotPath: existing?.snapshotPath,
                snapshotCacheKey: existing?.snapshotCacheKey,
                snapshotCapturedAt: existing?.snapshotCapturedAt,
                lastUpdatedAt: existing?.lastUpdatedAt,
                lastAttemptedAt: Date(),
                status: status,
                sparkline: existing?.sparkline ?? [],
                lastError: message,
                consecutiveFailureCount: failureCount,
                // Preserve the last-known secondary values so the widget
                // doesn't blank out the "resets in 4d" line just because
                // a single scrape failed. They'll get overwritten on the
                // next successful scrape.
                secondaryValues: existing?.secondaryValues ?? [:]
            )

            file.schemaVersion = currentSchemaVersion
            file.readings[tracker.id.uuidString] = reading
            try write(readingsFile: file)
            ActivityLogger.log("store", "recorded scrape failure", metadata: [
                "tracker": tracker.id.uuidString,
                "failures": "\(failureCount)",
                "status": status.rawValue,
                "error": message
            ])
            return reading
        }
    }

    @discardableResult
    static func resetFailureState(for trackerID: UUID, reason: String? = nil) throws -> TrackerReading {
        try withReadingsMutationLock {
            var file = loadReadingsUnlocked()
            let key = trackerID.uuidString
            var reading = file.readings[key] ?? TrackerReading(lastUpdatedAt: nil, status: .stale)
            reading.status = .stale
            reading.lastError = trimmedNonEmpty(reason)
            reading.consecutiveFailureCount = 0
            file.schemaVersion = currentSchemaVersion
            file.readings[key] = reading
            try write(readingsFile: file)
            return reading
        }
    }

    // MARK: - Hook telemetry (v0.18.0+)

    /// Persists a hook's lastRun stamp back into the tracker config so
    /// the editor UI can show "last run 13:42, ok". Silently no-ops if
    /// the tracker or hook has been deleted between fire and stamp.
    static func recordHookTelemetry(trackerID: UUID, hookID: UUID, lastRun: HookLastRun) throws {
        try mutateSharedConfiguration { configuration in
            guard let trackerIndex = configuration.trackers.firstIndex(where: { $0.id == trackerID }) else {
                return
            }
            var tracker = configuration.trackers[trackerIndex]
            var didStamp = false

            if let idx = tracker.hooks.onSuccess.firstIndex(where: { $0.id == hookID }) {
                tracker.hooks.onSuccess[idx].lastRun = lastRun
                didStamp = true
            }
            if let idx = tracker.hooks.onFailure.firstIndex(where: { $0.id == hookID }) {
                tracker.hooks.onFailure[idx].lastRun = lastRun
                didStamp = true
            }

            guard didStamp else {
                return
            }
            configuration.trackers[trackerIndex] = tracker
        }
    }

    /// Migration helper: backfill the default failure hook scaffold on
    /// trackers that pre-date v0.18.0. Idempotent — only fires when a
    /// tracker has zero hooks AND has no record of having been migrated.
    /// We tag the inserted hook with `BuiltInHookIdentifier.autoRepair`
    /// so future migrations can re-find it without clobbering
    /// user-authored hooks.
    @discardableResult
    static func backfillDefaultHookScaffoldIfNeeded() throws -> Int {
        var count = 0
        try mutateSharedConfiguration { configuration in
            for index in configuration.trackers.indices {
                let tracker = configuration.trackers[index]
                guard tracker.hooks.isEmpty else {
                    continue
                }
                configuration.trackers[index].hooks = TrackerHooks.defaultScaffold()
                count += 1
            }
        }
        if count > 0 {
            ActivityLogger.log("store", "backfilled default hook scaffold", metadata: ["count": "\(count)"])
        }
        return count
    }

    private static func loadConfiguration() -> AppConfiguration {
        loadConfiguration(from: AppGroupPaths.canonicalTrackersURL())
    }

    static func loadAppGroupConfiguration() -> AppConfiguration {
        guard let url = AppGroupPaths.appGroupTrackersURL() else {
            return loadConfiguration(from: AppGroupPaths.canonicalTrackersURL())
        }

        let appGroupConfiguration = loadConfiguration(from: url)
        if hasUserConfigurationData(appGroupConfiguration) {
            return appGroupConfiguration
        }

        let canonicalConfiguration = loadConfiguration(from: AppGroupPaths.canonicalTrackersURL())
        return hasUserConfigurationData(canonicalConfiguration) ? canonicalConfiguration : appGroupConfiguration
    }

    static func loadSharedConfiguration() -> AppConfiguration {
        let canonicalURL = AppGroupPaths.canonicalTrackersURL()
        let canonical = loadConfiguration(from: canonicalURL)
        let appGroupURL = AppGroupPaths.appGroupTrackersURL()
        let appGroup = appGroupURL.map(loadConfiguration(from:)) ?? .empty

        let canonicalHasData = hasUserConfigurationData(canonical)
        let appGroupHasData = hasUserConfigurationData(appGroup)

        switch (canonicalHasData, appGroupHasData) {
        case (true, true):
            guard let appGroupURL,
                  modificationDate(for: appGroupURL) > modificationDate(for: canonicalURL) else {
                mirrorToAppGroupIfAvailable(canonical, appGroupURL: appGroupURL)
                return canonical
            }
            return appGroup
        case (true, false):
            mirrorToAppGroupIfAvailable(canonical, appGroupURL: appGroupURL)
            return canonical
        case (false, true):
            return appGroup
        case (false, false):
            return canonical
        }
    }

    private static func mirrorToAppGroupIfAvailable(_ configuration: AppConfiguration, appGroupURL: URL?) {
        guard let appGroupURL else {
            return
        }

        do {
            try write(configuration: configuration, to: appGroupURL)
            ActivityLogger.log("store", "mirrored canonical configuration to app group", metadata: [
                "trackers": "\(configuration.trackers.count)",
                "widgets": "\(configuration.widgetConfigurations.count)"
            ])
        } catch {
            ActivityLogger.log("store", "app group mirror failed", metadata: ["error": error.localizedDescription])
        }
    }

    static func save(configuration: AppConfiguration) throws {
        try withConfigurationMutationLock {
            try saveUnlocked(configuration: configuration)
        }
    }

    private static func saveUnlocked(configuration: AppConfiguration) throws {
        var normalized = configuration
        normalized.schemaVersion = currentSchemaVersion
        try write(configuration: normalized, to: AppGroupPaths.canonicalTrackersURL())

        if let appGroupURL = AppGroupPaths.appGroupTrackersURL() {
            try write(configuration: normalized, to: appGroupURL)
        }
    }

    @discardableResult
    static func mutateSharedConfiguration(_ mutate: (inout AppConfiguration) throws -> Void) throws -> AppConfiguration {
        try withConfigurationMutationLock {
            var configuration = loadSharedConfiguration()
            try mutate(&configuration)
            try saveUnlocked(configuration: configuration)
            return configuration
        }
    }

    private static func loadConfiguration(from url: URL) -> AppConfiguration {
        guard let data = try? Data(contentsOf: url) else {
            return AppConfiguration.empty
        }

        do {
            return try decodeConfiguration(from: data)
        } catch {
            return AppConfiguration.empty
        }
    }

    private static func decodeConfiguration(from data: Data) throws -> AppConfiguration {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let configuration = try? decoder.decode(AppConfiguration.self, from: data),
           configuration.schemaVersion == currentSchemaVersion {
            return configuration
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let migratedObject = migrateConfigurationObject(object) else {
            throw CocoaError(.coderInvalidValue)
        }

        let migratedData = try JSONSerialization.data(withJSONObject: migratedObject, options: [])
        var configuration = try decoder.decode(AppConfiguration.self, from: migratedData)
        configuration.schemaVersion = currentSchemaVersion
        return configuration
    }

    private static func migrateConfigurationObject(_ object: [String: Any]) -> [String: Any]? {
        var migrated = object
        let schemaVersion = intValue(from: object["schemaVersion"]) ?? 1
        guard schemaVersion > 0, schemaVersion <= currentSchemaVersion else {
            return nil
        }

        if migrated["trackers"] == nil, let metrics = migrated["metrics"] {
            migrated["trackers"] = metrics
        }

        let trackerObjects = (migrated["trackers"] as? [Any])?.map(migrateTrackerObject) ?? []
        migrated["trackers"] = trackerObjects
        let trackerModes = trackerModesByID(from: trackerObjects)

        let widgetObjects = (migrated["widgetConfigurations"] as? [Any]) ?? []
        migrated["widgetConfigurations"] = widgetObjects.map {
            migrateWidgetConfigurationObject($0, trackerModesByID: trackerModes)
        }

        migrated["preferences"] = migratePreferencesObject(migrated["preferences"])
        migrated["schemaVersion"] = currentSchemaVersion
        migrated.removeValue(forKey: "metrics")
        migrated.removeValue(forKey: "detectedCLIs")
        return migrated
    }

    private static func migrateTrackerObject(_ value: Any) -> Any {
        guard var tracker = value as? [String: Any] else {
            return value
        }

        if let mode = migratedRenderMode(from: tracker["renderMode"] ?? tracker["mode"]) {
            tracker["renderMode"] = mode
        } else {
            tracker.removeValue(forKey: "renderMode")
        }

        if tracker["elementBoundingBox"] == nil,
           let cropRegion = tracker["cropRegion"] as? [String: Any],
           isValidBoundingBoxObject(cropRegion) {
            tracker["elementBoundingBox"] = cropRegion
        }

        return tracker
    }

    private static func migrateWidgetConfigurationObject(_ value: Any, trackerModesByID: [String: String]) -> Any {
        guard var widgetConfiguration = value as? [String: Any] else {
            return value
        }

        let trackerIDs = ((widgetConfiguration["trackerIDs"] as? [Any]) ?? [])
            .compactMap { $0 as? String }
            .filter { UUID(uuidString: $0) != nil }
        let template = widgetTemplate(from: widgetConfiguration["templateID"])
            ?? inferredWidgetTemplate(forTrackerIDs: trackerIDs, trackerModesByID: trackerModesByID)

        widgetConfiguration["trackerIDs"] = trackerIDs
        widgetConfiguration["templateID"] = template.rawValue

        if (widgetConfiguration["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            widgetConfiguration["name"] = template.displayName
        }
        if WidgetConfigurationSize(rawValue: widgetConfiguration["size"] as? String ?? "") == nil {
            widgetConfiguration["size"] = template.size.rawValue
        }
        if WidgetConfigurationLayout(rawValue: widgetConfiguration["layout"] as? String ?? "") == nil {
            widgetConfiguration["layout"] = template.defaultLayout.rawValue
        }
        if widgetConfiguration["showSparklines"] == nil {
            widgetConfiguration["showSparklines"] = true
        }
        if widgetConfiguration["showLabels"] == nil {
            widgetConfiguration["showLabels"] = true
        }

        return widgetConfiguration
    }

    private static func migratePreferencesObject(_ value: Any?) -> [String: Any] {
        var preferences = value as? [String: Any] ?? [:]
        var notificationChannels = preferences["notificationChannels"] as? [String: Any] ?? [:]

        if notificationChannels["macosNative"] == nil {
            notificationChannels["macosNative"] = true
        }
        if notificationChannels["webhook"] == nil {
            notificationChannels["webhook"] = NSNull()
        }
        if intValue(from: preferences["snapshotConcurrencyCap"]) == nil {
            preferences["snapshotConcurrencyCap"] = AppPreferences().snapshotConcurrencyCap
        }

        preferences["notificationChannels"] = notificationChannels
        preferences.removeValue(forKey: "detectedCLIs")
        return preferences
    }

    private static func trackerModesByID(from trackers: [Any]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: trackers.compactMap { value in
            guard let tracker = value as? [String: Any],
                  let id = tracker["id"] as? String,
                  UUID(uuidString: id) != nil else {
                return nil
            }

            return (id, migratedRenderMode(from: tracker["renderMode"]) ?? RenderMode.text.rawValue)
        })
    }

    private static func inferredWidgetTemplate(forTrackerIDs trackerIDs: [String], trackerModesByID: [String: String]) -> WidgetTemplate {
        let modes = trackerIDs.compactMap { trackerModesByID[$0] }
        let includesSnapshot = modes.contains(RenderMode.snapshot.rawValue)

        switch trackerIDs.count {
        case 1:
            return includesSnapshot ? .liveSnapshotTile : .singleBigNumber
        case 2:
            return includesSnapshot ? .snapshotPlusStat : .dualStatCompare
        case 3:
            return .dashboard3Up
        case 4...6:
            return .statsListWatchlist
        case 7...:
            return .megaDashboardGrid
        default:
            return .singleBigNumber
        }
    }

    private static func widgetTemplate(from value: Any?) -> WidgetTemplate? {
        (value as? String).flatMap(WidgetTemplate.init(rawValue:))
    }

    private static func migratedRenderMode(from value: Any?) -> String? {
        switch (value as? String)?.lowercased() {
        case "text", "number":
            return RenderMode.text.rawValue
        case "snapshot", "screenshot":
            return RenderMode.snapshot.rawValue
        default:
            return nil
        }
    }

    private static func isValidBoundingBoxObject(_ object: [String: Any]) -> Bool {
        ["x", "y", "width", "height", "viewportWidth", "viewportHeight", "devicePixelRatio"]
            .allSatisfy { doubleValue(from: object[$0]) != nil }
    }

    private static func normalizedReading(_ reading: TrackerReading, existing: TrackerReading?, for tracker: Tracker) -> TrackerReading {
        var normalized = reading
        let existingSparkline = existing?.sparkline ?? []

        if normalized.status == .ok {
            normalized.consecutiveFailureCount = 0
        } else if normalized.consecutiveFailureCount == nil {
            normalized.consecutiveFailureCount = existing?.consecutiveFailureCount ?? 0
        }

        if let numeric = normalized.currentNumeric {
            let displayWindow = max(1, tracker.history.displayWindow)
            normalized.sparkline = Array((existingSparkline + [numeric]).suffix(displayWindow))
        } else if normalized.sparkline.isEmpty {
            normalized.sparkline = existingSparkline
        }

        return normalized
    }

    private static func hasUserConfigurationData(_ configuration: AppConfiguration) -> Bool {
        !configuration.trackers.isEmpty || !configuration.widgetConfigurations.isEmpty
    }

    private static func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func write(configuration: AppConfiguration, to destinationURL: URL) throws {
        try writeJSON(configuration, to: destinationURL)
    }

    private static func write(readingsFile: TrackerReadingsFile) throws {
        guard let url = AppGroupPaths.appGroupReadingsURL() else {
            return
        }

        try writeJSON(readingsFile, to: url)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)

        let temporaryURL = directoryURL.appendingPathComponent(".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporaryURL, options: .atomic)

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    private static func withConfigurationMutationLock<T>(_ body: () throws -> T) throws -> T {
        try configurationMutationQueue.sync {
            try withFileLock(url: configurationLockURL(), body)
        }
    }

    private static func withReadingsMutationLock<T>(_ body: () throws -> T) throws -> T {
        try readingsMutationQueue.sync {
            try withFileLock(url: readingsLockURL(), body)
        }
    }

    private static func withFileLock<T>(url: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)

        let fd = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw posixError(errno)
        }
        defer {
            Darwin.close(fd)
        }

        guard flock(fd, LOCK_EX) == 0 else {
            throw posixError(errno)
        }
        defer {
            flock(fd, LOCK_UN)
        }

        return try body()
    }

    private static func configurationLockURL() -> URL {
        (AppGroupPaths.sharedContainerURL() ?? AppGroupPaths.canonicalApplicationSupportURL())
            .appendingPathComponent(configurationLockFileName, isDirectory: false)
    }

    private static func readingsLockURL() -> URL {
        if let readingsURL = AppGroupPaths.appGroupReadingsURL() {
            return readingsURL.deletingLastPathComponent().appendingPathComponent(readingsLockFileName, isDirectory: false)
        }

        return AppGroupPaths.canonicalApplicationSupportURL().appendingPathComponent(readingsLockFileName, isDirectory: false)
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
        )
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func intValue(from value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    private static func doubleValue(from value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }
}

struct AppConfiguration: Codable {
    var schemaVersion: Int
    var trackers: [Tracker]
    var widgetConfigurations: [WidgetConfiguration]
    var preferences: AppPreferences

    static var empty: AppConfiguration {
        AppConfiguration(
            schemaVersion: currentSchemaVersion,
            trackers: [],
            widgetConfigurations: [],
            preferences: AppPreferences()
        )
    }
}

struct AppPreferences: Codable, Equatable {
    var notificationChannels: NotificationChannelPreferences
    var snapshotConcurrencyCap: Int

    init(
        notificationChannels: NotificationChannelPreferences = NotificationChannelPreferences(),
        snapshotConcurrencyCap: Int = 8
    ) {
        self.notificationChannels = notificationChannels
        self.snapshotConcurrencyCap = snapshotConcurrencyCap
    }
}

struct NotificationChannelPreferences: Codable, Equatable {
    var macosNative: Bool
    var webhook: String?

    init(macosNative: Bool = true, webhook: String? = nil) {
        self.macosNative = macosNative
        self.webhook = webhook
    }
}
