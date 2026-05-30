//
//  AutoRepairGateTests.swift
//  MacosWidgetsStatsFromWebsiteHookTests
//
//  Pins the anti-false-positive gating for the built-in "Auto-repair via
//  Claude" hook (Ethan voice 4417, 2026-05-30, v0.21.37). The agent must fire
//  ONLY on a GENUINE, SUSTAINED selectorNotFound — never on lag / challenge /
//  login / timeout / blank-page failures, and never on a one-off blip.
//

import XCTest

final class AutoRepairGateTests: XCTestCase {

    // MARK: - Genuine selectorNotFound (the ONLY thing that should fire)

    func testFiresOnGenuineSustainedSelectorNotFound() {
        let message = SelectorExtractionError.selectorDidNotMatch.errorDescription!
        let reading = TrackerReading(status: .broken, lastError: message, consecutiveFailureCount: 3)
        XCTAssertTrue(
            AutoRepairGate.shouldFireAutoRepair(reading: reading),
            "A real, 3x-sustained 'selector did not match' is the one case that should re-identify."
        )
    }

    func testFiresOnSelectedElementHasNoText() {
        // ScraperError.selectedElementHasNoText also classifies as selectorNotFound.
        let message = ScraperError.selectedElementHasNoText.errorDescription!
        let reading = TrackerReading(status: .broken, lastError: message, consecutiveFailureCount: 4)
        XCTAssertTrue(AutoRepairGate.shouldFireAutoRepair(reading: reading))
    }

    // MARK: - SUSTAINED gate (must have >= 3 consecutive failures)

    func testDoesNotFireOnSingleSelectorMiss() {
        let message = SelectorExtractionError.selectorDidNotMatch.errorDescription!
        let reading = TrackerReading(status: .stale, lastError: message, consecutiveFailureCount: 1)
        XCTAssertFalse(
            AutoRepairGate.shouldFireAutoRepair(reading: reading),
            "A one-off selector miss is a blip, not a reason to spawn the agent."
        )
    }

    func testDoesNotFireOnTwoConsecutiveSelectorMisses() {
        let message = SelectorExtractionError.selectorDidNotMatch.errorDescription!
        let reading = TrackerReading(status: .stale, lastError: message, consecutiveFailureCount: 2)
        XCTAssertFalse(AutoRepairGate.shouldFireAutoRepair(reading: reading))
    }

    // MARK: - KIND gate (every non-selector kind must NOT fire, even when sustained)

    func testDoesNotFireOnSustainedBrowserChallenge() {
        let message = SelectorExtractionError.browserChallengeInProgress.errorDescription!
        // (browserChallenge resets the counter to 0 in practice, but pin the
        // kind gate independently with an artificially-high count.)
        let reading = TrackerReading(status: .broken, lastError: message, consecutiveFailureCount: 9)
        XCTAssertFalse(
            AutoRepairGate.shouldFireAutoRepair(reading: reading),
            "A Cloudflare/Turnstile challenge never means the element changed."
        )
    }

    func testDoesNotFireOnSustainedLoginRequired() {
        let message = SelectorExtractionError.loginRequired.errorDescription!
        let reading = TrackerReading(status: .broken, lastError: message, consecutiveFailureCount: 5)
        XCTAssertFalse(
            AutoRepairGate.shouldFireAutoRepair(reading: reading),
            "Login is a user action, not a selector change — re-identify is wrong here."
        )
    }

    func testDoesNotFireOnSustainedPageTimeout() {
        let message = ScraperError.navigationFailed("Timed out loading the page.").errorDescription!
        let reading = TrackerReading(status: .broken, lastError: message, consecutiveFailureCount: 6)
        XCTAssertFalse(
            AutoRepairGate.shouldFireAutoRepair(reading: reading),
            "A page timeout is lag — the element didn't move."
        )
    }

    func testDoesNotFireOnSustainedGenericError() {
        let reading = TrackerReading(status: .broken, lastError: "Some unexpected failure", consecutiveFailureCount: 7)
        XCTAssertFalse(AutoRepairGate.shouldFireAutoRepair(reading: reading))
    }

    // MARK: - OK readings never fire

    func testDoesNotFireOnOKReading() {
        let reading = TrackerReading(status: .ok, lastError: nil, consecutiveFailureCount: 0)
        XCTAssertFalse(AutoRepairGate.shouldFireAutoRepair(reading: reading))
    }

    // MARK: - Anti-misclassification: a challenge string that LOOKS like the raw
    // selector error must NOT fire (the scraper downgrades blank/challenge pages
    // to browserChallenge; this pins that a challenge-classified message is gated).

    func testDoesNotFireWhenSelectorMissWasActuallyAChallenge() {
        // After v0.21.37, ChromeCDPScraper.finishSelectorFailure emits the
        // browserChallenge error for a non-rendered page rather than the raw
        // selector-miss string. This message therefore classifies as
        // browserChallenge and must be gated even at a high failure count.
        let message = SelectorExtractionError.browserChallengeInProgress.errorDescription!
        let reading = TrackerReading(status: .broken, lastError: message, consecutiveFailureCount: 3)
        XCTAssertFalse(AutoRepairGate.shouldFireAutoRepair(reading: reading))
    }
}
