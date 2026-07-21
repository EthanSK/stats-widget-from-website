import XCTest

final class SetupJourneyTests: XCTestCase {
    func testBlankInstallStartsByChoosingAValue() {
        let state = SetupJourneyState(trackerCount: 0, widgetConfigurationCount: 0)

        XCTAssertEqual(state.nextStep, .chooseValue)
        XCTAssertEqual(state.completedAppSteps, 0)
    }

    func testExistingValueWithoutWidgetNeedsWidgetPreparation() {
        let state = SetupJourneyState(trackerCount: 1, widgetConfigurationCount: 0)

        XCTAssertEqual(state.nextStep, .prepareDesktopWidget)
        XCTAssertEqual(state.completedAppSteps, 1)
    }

    func testPreparedValueAndWidgetLeavesOnlyMacOSPlacement() {
        let state = SetupJourneyState(trackerCount: 3, widgetConfigurationCount: 2)

        XCTAssertEqual(state.nextStep, .addWidgetToDesktop)
        XCTAssertEqual(state.completedAppSteps, 2)
    }

    func testOrphanWidgetDoesNotSkipChoosingAValue() {
        let state = SetupJourneyState(trackerCount: 0, widgetConfigurationCount: 1)

        XCTAssertEqual(state.nextStep, .chooseValue)
    }
}
