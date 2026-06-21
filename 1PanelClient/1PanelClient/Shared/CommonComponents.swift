//
//  CommonComponents.swift
//  1PanelClient
//

import SwiftUI

struct InfoRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack(alignment: .top) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }
}

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("重试", action: retry)
                .buttonStyle(.bordered)
        }
        .padding(.top, 40)
    }
}
