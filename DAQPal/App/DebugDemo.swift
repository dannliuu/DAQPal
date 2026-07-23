//
//  DebugDemo.swift
//  DAQPal
//
//  DEBUG-only launch-argument hooks so the Simulator can reach every screen
//  without GUI automation:
//    -daqpal-auto-roi         place device 1's ROI on the synthetic display
//    -daqpal-auto-record N    start recording ~2s after launch, stop after N s
//    -daqpal-demo-results     open the results screen with fabricated demo data
//  Demo data is clearly synthetic (deterministic sine series) and exists only
//  for layout/interaction verification — it never ships in release builds and
//  is never a claim about recognition accuracy.
//

#if DEBUG
import Foundation

@MainActor
enum DebugDemo {
    static func applyLaunchArguments(to appState: AppState) {
        let args = ProcessInfo.processInfo.arguments

        if args.contains("-daqpal-auto-roi"), var device = appState.devices.first {
            device.roi = SyntheticDisplayRenderer.displayROI
            appState.updateDevice(device)
        }

        if args.contains("-daqpal-demo-results") {
            appState.completedSession = makeDemoSession()
            appState.showResults = true
        }

        if let idx = args.firstIndex(of: "-daqpal-auto-record"),
           idx + 1 < args.count, let seconds = Double(args[idx + 1]) {
            Task {
                try? await Task.sleep(for: .seconds(2))
                appState.startRecording()
                try? await Task.sleep(for: .seconds(seconds))
                appState.stopRecording()
            }
        }
    }

    /// Two-device session: a slow voltage sine plus a current sine, with a
    /// sprinkling of typed rejections so rejected-row/marker styling shows.
    static func makeDemoSession() -> CompletedSession {
        var dmm1 = Device.makeDefault(index: 1)
        dmm1.roi = .defaultROI
        var dmm2 = Device.makeDefault(index: 2)
        dmm2.displayFormat = DisplayFormat(digitCount: 5, decimalPosition: 1,
                                           signAllowed: false, unit: "A",
                                           minimumValue: 0, maximumValue: 5)
        dmm2.roi = NormalizedROI(x: 0.2, y: 0.7, width: 0.5, height: 0.12)

        let base: TimeInterval = 1_000
        let dt = 1.0 / 12.0
        var samples: [RecordingSample] = []
        for i in 0..<240 {
            let t = base + Double(i) * dt
            var readings: [UUID: Measurement] = [:]

            let volts = 12.3 + 0.4 * sin(Double(i) * 0.08)
            if i % 23 == 11 {
                readings[dmm1.id] = .rejected(timestamp: t, reason: .invalidFormat,
                                              unit: "V", confidence: 0.31, rawText: "1?.3A")
            } else {
                readings[dmm1.id] = Measurement(timestamp: t,
                                                value: (volts * 1000).rounded() / 1000,
                                                unit: "V",
                                                confidence: 0.995 - Float(i % 7) * 0.004,
                                                accepted: true)
            }

            let amps = 1.85 + 0.6 * sin(Double(i) * 0.035 + 1.2)
            if i % 31 == 19 {
                readings[dmm2.id] = .rejected(timestamp: t, reason: .excessiveRateOfChange,
                                              value: amps + 2.9, unit: "A", confidence: 0.62)
            } else {
                readings[dmm2.id] = Measurement(timestamp: t,
                                                value: (amps * 10000).rounded() / 10000,
                                                unit: "A",
                                                confidence: 0.988,
                                                accepted: true)
            }
            samples.append(RecordingSample(timestamp: t, readings: readings))
        }

        return CompletedSession(id: UUID(),
                                startedAt: Date().addingTimeInterval(-20),
                                endedAt: Date(),
                                devices: [dmm1, dmm2],
                                samples: samples,
                                firstTimestamp: base,
                                lastTimestamp: base + Double(239) * dt)
    }
}
#endif
