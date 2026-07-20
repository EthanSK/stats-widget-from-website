//
//  BrowserAccountBadge.swift
//  MacosWidgetsStatsFromWebsite
//
//  Consistent visual identity for isolated signed-in browser accounts.
//

import SwiftUI

struct BrowserAccountBadge: View {
    let account: BrowserAccount
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hexString: account.colorHex) ?? .accentColor)
            Text(account.initials)
                .font(.system(size: max(9, size * 0.38), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct BrowserAccountLabel: View {
    let account: BrowserAccount
    var badgeSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 7) {
            BrowserAccountBadge(account: account, size: badgeSize)
            Text(account.name)
            if account.isDefault {
                Text("Default")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.isDefault ? "\(account.name), default browser account" : account.name)
    }
}
