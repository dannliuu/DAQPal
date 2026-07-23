//
//  DAQPalApp.swift
//  DAQPal
//
//  DAQPAL — VISUAL DATA ACQUISITION
//

import SwiftUI

@main
struct DAQPalApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.light)
        }
    }
}

/// Root of the always-mounted capture hierarchy. The capture stack (camera
/// session + processing pipeline) is created once here and never torn down by
/// navigation — results and format configuration are sheets over the capture
/// screen (spec §40.1).
struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var captureStack: CaptureStack?

    var body: some View {
        Group {
            if let captureStack {
                CameraCaptureScreen(captureStack: captureStack)
            } else {
                ZStack {
                    Theme.cameraArea.ignoresSafeArea()
                    VStack(spacing: 8) {
                        Text("DAQPAL")
                            .font(Theme.ui(15, weight: .heavy))
                            .tracking(1.5)
                            .foregroundStyle(Theme.brandYellow)
                        SectionLabel(text: "Visual Data Acquisition", color: .white.opacity(0.55))
                    }
                }
            }
        }
        .task {
            guard captureStack == nil else { return }
            let stack = CaptureStack(appState: appState)
            captureStack = stack
            await stack.start()
        }
    }
}
