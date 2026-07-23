//
//  Theme.swift
//  DAQPal
//
//  Fluke-yellow design language from the design handoff
//  (Design_notes/design_handoff_daqpal_ios/README.md).
//
//  Typography note: the handoff specifies Archivo with SF Mono for numerics.
//  Archivo is not bundled in the MVP; the system grotesque (SF Pro) is the
//  documented substitute the handoff explicitly allows. Numeric readouts use
//  the system monospaced design (SF Mono).
//

import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

enum Theme {
    // MARK: Surfaces
    static let chrome = Color(hex: 0xF7E9BC)          // app bars, panels
    static let card = Color(hex: 0xFDF6DE)            // capture cards
    static let resultsBackground = Color(hex: 0xFAF6EA)
    static let resultsCard = Color.white
    static let tableHeader = Color(hex: 0xF3EBD2)
    static let cameraArea = Color(hex: 0x0B0C0F)
    static let recordingStrip = Color(hex: 0x2B2820)

    // MARK: Ink
    static let ink = Color(hex: 0x2B2820)
    static let inkMuted = Color(hex: 0x2B2820).opacity(0.55)
    static let hairline = Color(hex: 0x2B2820).opacity(0.2)
    static let heavyRule = Color(hex: 0x2B2820).opacity(0.4)

    // MARK: Brand
    static let brandYellow = Color(hex: 0xFFC20E)     // accent, locked ROI, primary buttons
    static let graphSeries1 = Color(hex: 0xE8A400)
    static let graphSeries2 = Color(hex: 0x3A3730)
    static let spark1 = Color(hex: 0xFFC20E)
    static let spark2 = Color(hex: 0xE5DFC9)

    // MARK: Status
    static let lockedChipBackground = Color(hex: 0xFFE9A8)
    static let lockedChipForeground = Color(hex: 0x6B4E00)
    static let searchingChipBackground = Color(hex: 0xFFD9CE)
    static let searchingChipForeground = Color(hex: 0x8A2A12)
    static let rejectedRowBackground = Color(hex: 0xFDEBE7)
    static let acceptedChipBackground = Color(hex: 0xEAF3E2)
    static let acceptedChipForeground = Color(hex: 0x3D5B27)

    // MARK: Recording
    static let recordRed = Color(hex: 0xD0342C)       // idle "● REC"
    static let recordActiveRed = Color(hex: 0xB02318) // recording "■ STOP"
    static let roiSearching = Color(hex: 0xFF6B4A)    // dashed searching border

    // MARK: Typography
    /// UI text (Archivo substitute — system grotesque).
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Numeric readouts, timers, table values (SF Mono).
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Uppercase micro-label, e.g. section headers ("10/800, tracking 0.1em").
    static func sectionLabel(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .heavy)
    }
}

/// Letter-spaced uppercase section label used across capture and results.
struct SectionLabel: View {
    let text: String
    var size: CGFloat = 10
    var color: Color = Theme.inkMuted

    var body: some View {
        Text(text.uppercased())
            .font(Theme.sectionLabel(size))
            .tracking(size * 0.1)
            .foregroundStyle(color)
    }
}
