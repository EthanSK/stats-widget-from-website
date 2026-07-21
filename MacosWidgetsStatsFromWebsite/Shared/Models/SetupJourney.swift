//
//  SetupJourney.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Small, UI-independent model for the beginner setup path.
//

struct SetupJourneyState: Equatable {
    enum NextStep: Equatable {
        case chooseValue
        case prepareDesktopWidget
        case addWidgetToDesktop
    }

    let hasTrackedValue: Bool
    let hasDesktopWidget: Bool

    init(trackerCount: Int, widgetConfigurationCount: Int) {
        hasTrackedValue = trackerCount > 0
        hasDesktopWidget = widgetConfigurationCount > 0
    }

    var completedAppSteps: Int {
        (hasTrackedValue ? 1 : 0) + (hasDesktopWidget ? 1 : 0)
    }

    var nextStep: NextStep {
        if !hasTrackedValue {
            return .chooseValue
        }
        if !hasDesktopWidget {
            return .prepareDesktopWidget
        }
        return .addWidgetToDesktop
    }
}
