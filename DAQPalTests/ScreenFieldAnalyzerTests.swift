//
//  ScreenFieldAnalyzerTests.swift
//  DAQPalTests
//
//  Two layers, deliberately separated:
//
//  - The pure helpers (unit-token matching, format inference, geometric
//    label/unit association) are tested exhaustively WITHOUT Vision. They are
//    where the component's judgement lives, and they must be pinned exactly.
//  - One end-to-end pass renders a multi-row instrument panel with CoreGraphics
//    and runs the real analyzer over it, which is the only way to prove the
//    Vision box conversion and the association geometry agree.
//
//  The panel renderer draws straight into the destination buffer through a
//  single y-flip, so there is no intermediate image to double-flip (the bug
//  `SyntheticDisplayGenerator.drawImage` documents). Orientation is verified by
//  the test itself: the top row's value must come back as the top-most field.
//

import CoreGraphics
import CoreVideo
import Foundation
import UIKit
import XCTest
@testable import DAQPal

final class ScreenFieldAnalyzerTests: XCTestCase {

    // MARK: - Unit token matching

    func testKnownUnitTokensMatchCaseInsensitively() {
        for token in ["V", "A", "mA", "uA", "µA", "mV", "kV", "Ω", "ohm",
                      "W", "kW", "Hz", "kHz", "MHz", "°C", "°F", "C", "F",
                      "S", "dB", "%", "VA", "Wh", "kWh", "H"] {
            XCTAssertEqual(ScreenFieldAnalyzer.unitToken(in: token), token,
                           "\(token) should be recognized as a unit")
            XCTAssertEqual(ScreenFieldAnalyzer.classify(token), .unit,
                           "\(token) should classify as .unit")
        }
        XCTAssertEqual(ScreenFieldAnalyzer.unitToken(in: "v"), "v")
        XCTAssertEqual(ScreenFieldAnalyzer.unitToken(in: "MA"), "MA")
        XCTAssertEqual(ScreenFieldAnalyzer.unitToken(in: "hz"), "hz")
    }

    /// The reason matching is exact-token: "A" is amperes, but it also sits
    /// inside almost every word an instrument prints.
    func testUnitTokenNeverMatchesInsideAWord() {
        for word in ["ALARM", "AVERAGE", "VOLTAGE", "CURRENT", "AUTO", "MAX",
                     "MIN", "HOLD", "CAL", "WATTS", "FAULT", "SET", "HI",
                     "AC", "DC"] {
            XCTAssertNil(ScreenFieldAnalyzer.unitToken(in: word),
                         "\(word) must not be treated as a unit")
            XCTAssertEqual(ScreenFieldAnalyzer.classify(word), .label,
                           "\(word) should classify as .label")
        }
    }

    func testUnitTokenTrimsFramingPunctuation() {
        XCTAssertEqual(ScreenFieldAnalyzer.unitToken(in: " V "), "V")
        XCTAssertEqual(ScreenFieldAnalyzer.unitToken(in: "(A)"), "A")
        XCTAssertEqual(ScreenFieldAnalyzer.unitToken(in: "[mV]"), "mV")
    }

    /// Case-insensitive matching must not become case-REWRITING: "MV" stays
    /// "MV", because folding it to "mV" would turn megavolts into millivolts.
    func testUnitTokenPreservesOriginalSpelling() {
        XCTAssertEqual(ScreenFieldAnalyzer.unitToken(in: "MV"), "MV")
        XCTAssertEqual(ScreenFieldAnalyzer.unitToken(in: "KHZ"), "KHZ")
    }

    func testUnitTokenRejectsNonUnits() {
        XCTAssertNil(ScreenFieldAnalyzer.unitToken(in: ""))
        XCTAssertNil(ScreenFieldAnalyzer.unitToken(in: "   "))
        XCTAssertNil(ScreenFieldAnalyzer.unitToken(in: "12"))
        XCTAssertNil(ScreenFieldAnalyzer.unitToken(in: "VV"))
        XCTAssertNil(ScreenFieldAnalyzer.unitToken(in: "mAh?"))
    }

    // MARK: - Classification

    func testClassifyNumericReadings() {
        for reading in ["12.345", "-12.3", "+0.05", "1234", "0", ".500", "12.345 V"] {
            XCTAssertEqual(ScreenFieldAnalyzer.classify(reading), .numeric,
                           "\(reading) should classify as .numeric")
        }
    }

    func testClassifyUnknownForNonTextualJunk() {
        XCTAssertEqual(ScreenFieldAnalyzer.classify(""), .unknown)
        XCTAssertEqual(ScreenFieldAnalyzer.classify("   "), .unknown)
        XCTAssertEqual(ScreenFieldAnalyzer.classify("---"), .unknown)
        XCTAssertEqual(ScreenFieldAnalyzer.classify("***"), .unknown)
    }

    /// A caption that carries a channel or range number is still a caption.
    /// Classifying "CH1" as a reading is doubly wrong: it mints a spurious
    /// numeric field AND consumes the only caption the row's real reading
    /// could have been given, leaving that one anonymous.
    func testCaptionCarryingADigitStaysALabel() {
        for caption in ["CH1", "CH2", "T1", "2ND", "AUX2", "ABCDE1"] {
            XCTAssertEqual(ScreenFieldAnalyzer.classify(caption), .label,
                           "\(caption) should classify as .label")
        }
    }

    /// The counterpart: a whole line whose number IS the content stays numeric
    /// even though letters outnumber digits in it.
    func testFusedLineClassifiesAsNumeric() {
        for line in ["VOLTAGE 12.345 mV", "CH1 12.345 V", "POWER 15.23", "1.5mA",
                     "12.345 VDC", "VOLTAGE 12.345 VDC"] {
            XCTAssertEqual(ScreenFieldAnalyzer.classify(line), .numeric,
                           "\(line) should classify as .numeric")
        }
    }

    // MARK: - The unit vocabulary is not a gate on recall

    /// One table, every column asserted: what a run classifies as, the value it
    /// yields, the unit it carries out of its own text, and the caption it
    /// recovers. Both halves matter — a row asserting `.label` is asserting
    /// that NO numeric field is minted from that run.
    ///
    /// The regression this pins: a genuine reading followed by a unit the
    /// analyzer's vocabulary does not list ("230 VAC", "12 PSI", "0.5 PSI")
    /// used to classify `.label`, so the display produced nothing capturable at
    /// all. `unitTokens` can never be complete, so it must not decide whether a
    /// number is a number.
    func testClassificationTable() {
        struct Case {
            let text: String
            let kind: FieldContentKind
            let value: Double?
            let unit: String?
            let label: String?
            let note: String
        }
        let cases: [Case] = [
            // --- The regression: real readings, unrecognized units. ---
            Case(text: "230 VAC", kind: .numeric, value: 230, unit: "VAC", label: nil,
                 note: "unrecognized unit must not suppress the reading"),
            Case(text: "12 PSI", kind: .numeric, value: 12, unit: "PSI", label: nil,
                 note: "unrecognized unit must not suppress the reading"),
            Case(text: "0.5 PSI", kind: .numeric, value: 0.5, unit: "PSI", label: nil,
                 note: "unrecognized unit must not suppress the reading"),
            Case(text: "350 CFM", kind: .numeric, value: 350, unit: "CFM", label: nil,
                 note: "vocabulary is incomplete by construction"),
            Case(text: "101.3 kPa", kind: .numeric, value: 101.3, unit: "kPa", label: nil,
                 note: "vocabulary is incomplete by construction"),
            Case(text: "1200 lux", kind: .numeric, value: 1200, unit: "lux", label: nil,
                 note: "vocabulary is incomplete by construction"),
            Case(text: "7.2 pH", kind: .numeric, value: 7.2, unit: "pH", label: nil,
                 note: "vocabulary is incomplete by construction"),
            Case(text: "12.345 VDC", kind: .numeric, value: 12.345, unit: "VDC", label: nil,
                 note: "vocabulary is incomplete by construction"),

            // --- Recognized units: unchanged, and the unit is still recorded. ---
            Case(text: "12.345 mV", kind: .numeric, value: 12.345, unit: "mV", label: nil,
                 note: "recognized unit"),
            Case(text: "1.5mA", kind: .numeric, value: 1.5, unit: "mA", label: nil,
                 note: "a RECOGNIZED unit attaches without a separator"),
            Case(text: "MAX 99.9 RPM", kind: .numeric, value: 99.9, unit: "RPM", label: "MAX",
                 note: "caption left, recognized unit right"),
            Case(text: "1750 RPM", kind: .numeric, value: 1750, unit: "RPM", label: nil,
                 note: "recognized unit"),
            Case(text: "450 ppm", kind: .numeric, value: 450, unit: "ppm", label: nil,
                 note: "recognized unit"),
            Case(text: "98.6 °F", kind: .numeric, value: 98.6, unit: "°F", label: nil,
                 note: "degree sign is unit-shaped"),

            // --- Fused captions still recovered. ---
            Case(text: "VOLTAGE 12.345 mV", kind: .numeric, value: 12.345, unit: "mV",
                 label: "VOLTAGE", note: "fused caption + recognized unit"),
            Case(text: "CH1 12.345 V", kind: .numeric, value: 12.345, unit: "V", label: "CH1",
                 note: "a caption carrying a digit still detaches from the reading"),
            Case(text: "PRESSURE 12.5 PSI", kind: .numeric, value: 12.5, unit: "PSI",
                 label: "PRESSURE", note: "fused caption + unrecognized unit"),

            // --- Bare readings. ---
            Case(text: "1234", kind: .numeric, value: 1234, unit: nil, label: nil,
                 note: "bare integer"),
            Case(text: "-12.3", kind: .numeric, value: -12.3, unit: nil, label: nil,
                 note: "sign belongs to the token, not to a caption"),
            Case(text: "0", kind: .numeric, value: 0, unit: nil, label: nil,
                 note: "a single zero is a reading"),

            // --- NOT readings. The over-correction must not come back. ---
            Case(text: "CH1", kind: .label, value: nil, unit: nil, label: nil,
                 note: "letters fused to a minor digit are a caption"),
            Case(text: "T1", kind: .label, value: nil, unit: nil, label: nil,
                 note: "letters fused to a minor digit are a caption"),
            Case(text: "AUX2", kind: .label, value: nil, unit: nil, label: nil,
                 note: "letters fused to a minor digit are a caption"),
            Case(text: "2ND", kind: .label, value: nil, unit: nil, label: nil,
                 note: "an unrecognized suffix glued to a digit is NOT a unit"),
            Case(text: "HOLD", kind: .label, value: nil, unit: nil, label: nil,
                 note: "annunciator"),
            Case(text: "AUTO", kind: .label, value: nil, unit: nil, label: nil,
                 note: "annunciator"),
            Case(text: "PSI", kind: .label, value: nil, unit: nil, label: nil,
                 note: "a bare unit-shaped word is a caption, never a unit on its own"),
            Case(text: "VAC", kind: .label, value: nil, unit: nil, label: nil,
                 note: "a bare unit-shaped word is a caption, never a unit on its own"),
            // The deliberate limit of the separator rule. "230VAC" is shaped
            // exactly like "2ND" — letters glued straight onto digits — and no
            // rule can admit one without admitting the other, so the analyzer
            // keeps the conservative reading and the number stays a caption.
            Case(text: "230VAC", kind: .label, value: nil, unit: nil, label: nil,
                 note: "no separator: indistinguishable from an annunciator"),

            // --- Recognized units standing alone are units, not captions. ---
            Case(text: "V", kind: .unit, value: nil, unit: "V", label: nil, note: "bare unit run"),
            Case(text: "mA", kind: .unit, value: nil, unit: "mA", label: nil, note: "bare unit run"),

            // --- Neither. ---
            Case(text: "---", kind: .unknown, value: nil, unit: nil, label: nil,
                 note: "no letters, no digits"),
            Case(text: "", kind: .unknown, value: nil, unit: nil, label: nil, note: "empty")
        ]

        for c in cases {
            XCTAssertEqual(ScreenFieldAnalyzer.classify(c.text), c.kind,
                           "'\(c.text)' — \(c.note)")
            guard c.kind == .numeric else {
                XCTAssertNotEqual(ScreenFieldAnalyzer.classify(c.text), .numeric,
                                  "'\(c.text)' must NOT mint a numeric field — \(c.note)")
                continue
            }
            let extracted = FormatValidator.extractNumber(from: c.text)
            XCTAssertEqual(extracted?.value, c.value, "'\(c.text)' value — \(c.note)")
            XCTAssertEqual(ScreenFieldAnalyzer.trailingUnitCandidate(in: c.text), c.unit,
                           "'\(c.text)' unit — \(c.note)")
            XCTAssertEqual(ScreenFieldAnalyzer.leadingLabel(in: c.text), c.label,
                           "'\(c.text)' caption — \(c.note)")
            XCTAssertNotNil(ScreenFieldAnalyzer.inferredFormat(from: c.text),
                            "'\(c.text)' must yield an inferred format — \(c.note)")
        }

        // The unit column above is what the ANALYZER records; for the two bare
        // unit runs it comes from `unitToken` instead, so pin those separately.
        for c in cases where c.kind == .unit {
            XCTAssertEqual(ScreenFieldAnalyzer.unitToken(in: c.text), c.unit, "'\(c.text)'")
        }
    }

    /// The shape test on its own. It is deliberately permissive about spelling
    /// and strict about structure — one short word, letters plus a couple of
    /// unit symbols, no digits and no interior space.
    func testUnitLikeTokenAcceptsUnrecognizedUnitSpellings() {
        for token in ["VAC", "VDC", "PSI", "CFM", "kPa", "lux", "pH", "ppm", "mbar",
                      "mmHg", "°F", "%", "µS/cm"] {
            // "%"" has no letter and is only ever reached through `unitToken`,
            // so it is excluded from the shape test on purpose.
            if token == "%" {
                XCTAssertNil(ScreenFieldAnalyzer.unitLikeToken(in: token),
                             "a symbol with no letter is not unit-SHAPED")
                continue
            }
            XCTAssertEqual(ScreenFieldAnalyzer.unitLikeToken(in: token), token,
                           "\(token) should be unit-shaped")
        }
    }

    func testUnitLikeTokenRejectsEverythingThatIsNotOneShortWord() {
        for text in ["", "   ", "---", "...", "VOLTS DC", "READY TO GO", "CH1", "2ND",
                     "M12", "REMAINING", "OVERRANGE", "mAh?"] {
            XCTAssertNil(ScreenFieldAnalyzer.unitLikeToken(in: text),
                         "'\(text)' must not be treated as unit-shaped")
        }
        // Length is the cutoff, not an approximation of one.
        XCTAssertEqual(ScreenFieldAnalyzer.unitLikeToken(in: "abcdef"), "abcdef")
        XCTAssertNil(ScreenFieldAnalyzer.unitLikeToken(in: "abcdefg"))
        XCTAssertEqual(ScreenFieldAnalyzer.maximumUnitLikeLength, 6)
    }

    /// The asymmetry that keeps "2ND" a caption: a recognized unit may be glued
    /// straight onto the digits, an unrecognized one may not.
    func testDetachableUnitRequiresASeparatorWhenTheUnitIsUnrecognized() {
        // Recognized: separator optional.
        XCTAssertEqual(ScreenFieldAnalyzer.detachableUnit(in: " mA"), "mA")
        XCTAssertEqual(ScreenFieldAnalyzer.detachableUnit(in: "mA"), "mA")
        XCTAssertEqual(ScreenFieldAnalyzer.detachableUnit(in: "V"), "V")
        // Unrecognized: separator required.
        XCTAssertEqual(ScreenFieldAnalyzer.detachableUnit(in: " PSI"), "PSI")
        XCTAssertEqual(ScreenFieldAnalyzer.detachableUnit(in: " (PSI)"), "PSI")
        XCTAssertNil(ScreenFieldAnalyzer.detachableUnit(in: "PSI"))
        XCTAssertNil(ScreenFieldAnalyzer.detachableUnit(in: "ND"))
        // Not unit-shaped at all, separator or not.
        XCTAssertNil(ScreenFieldAnalyzer.detachableUnit(in: " VOLTS DC"))
        XCTAssertNil(ScreenFieldAnalyzer.detachableUnit(in: ""))
    }

    /// `trailingUnit` stays RECOGNIZED-only; `trailingUnitCandidate` is the
    /// permissive one. The difference is load-bearing: `associating` uses
    /// recognition to decide how much a number's own unit is trusted.
    func testTrailingUnitStaysStrictWhileTheCandidateIsPermissive() {
        XCTAssertNil(ScreenFieldAnalyzer.trailingUnit(in: "12 PSI"))
        XCTAssertEqual(ScreenFieldAnalyzer.trailingUnitCandidate(in: "12 PSI"), "PSI")

        XCTAssertEqual(ScreenFieldAnalyzer.trailingUnit(in: "12.345 V"), "V")
        XCTAssertEqual(ScreenFieldAnalyzer.trailingUnitCandidate(in: "12.345 V"), "V")

        XCTAssertNil(ScreenFieldAnalyzer.trailingUnitCandidate(in: "12.345"))
        XCTAssertNil(ScreenFieldAnalyzer.trailingUnitCandidate(in: "VOLTAGE"))
    }

    /// A guessed unit is worth less than a real one. A number holding only a
    /// guess still competes for a neighbouring unit run and is overwritten by
    /// it; a number holding a RECOGNIZED unit does not compete at all.
    func testGuessedUnitIsReplacedByANeighbouringRecognizedUnit() {
        var guessed = makeField(.numeric, "", x: 0.30, y: 0.10, w: 0.20, h: 0.10)
        guessed.format.unit = "AC"
        let fields = [
            guessed,
            makeField(.unit, "V", x: 0.55, y: 0.10, w: 0.05, h: 0.10)
        ]
        XCTAssertEqual(ScreenFieldAnalyzer.associating(fields)[0].format.unit, "V")
    }

    /// …but the number with NOTHING gets first refusal, even when the number
    /// holding a guess sits closer to the token. Otherwise fixing recall on one
    /// row would strip the unit off another.
    func testNumberWithNoUnitOutranksANumberHoldingAGuess() {
        var guessed = makeField(.numeric, "", x: 0.30, y: 0.10, w: 0.20, h: 0.10)
        guessed.format.unit = "PSI"
        let fields = [
            makeField(.numeric, "", x: 0.05, y: 0.10, w: 0.20, h: 0.10),
            guessed,
            makeField(.unit, "A", x: 0.55, y: 0.10, w: 0.05, h: 0.10)
        ]
        let associated = ScreenFieldAnalyzer.associating(fields)
        XCTAssertEqual(associated[0].format.unit, "A",
                       "the number with no unit at all takes the token")
        XCTAssertEqual(associated[1].format.unit, "PSI",
                       "the guess survives when there is no better evidence for it")
    }

    /// A guessed unit must never be ERASED by a neighbour that carries no unit
    /// of its own — losing "PSI" would be worse than never having read it.
    func testGuessedUnitSurvivesWhenNoUnitRunIsNearby() {
        var guessed = makeField(.numeric, "", x: 0.30, y: 0.10, w: 0.20, h: 0.10)
        guessed.format.unit = "PSI"
        let fields = [
            makeField(.label, "PRESSURE", x: 0.05, y: 0.10, w: 0.20, h: 0.10),
            guessed
        ]
        let associated = ScreenFieldAnalyzer.associating(fields)
        XCTAssertEqual(associated[1].format.unit, "PSI")
        XCTAssertEqual(associated[1].label, "PRESSURE")
    }

    // MARK: - Fused-line recovery

    func testNumericSplitFindsTheDominantToken() throws {
        let split = try XCTUnwrap(ScreenFieldAnalyzer.numericSplit(in: "VOLTAGE 12.345 mV"))
        XCTAssertEqual(split.leading, "VOLTAGE ")
        XCTAssertEqual(split.token, "12.345")
        XCTAssertEqual(split.trailing, " mV")

        // The token with the most digits wins, exactly as
        // `FormatValidator.extractNumber` chooses it.
        let channel = try XCTUnwrap(ScreenFieldAnalyzer.numericSplit(in: "CH1 12.345 V"))
        XCTAssertEqual(channel.leading, "CH1 ")
        XCTAssertEqual(channel.token, "12.345")
        XCTAssertEqual(channel.trailing, " V")

        XCTAssertNil(ScreenFieldAnalyzer.numericSplit(in: "VOLTAGE"))
        XCTAssertNil(ScreenFieldAnalyzer.numericSplit(in: "---"))
    }

    /// Vision groups a line before returning it, so the unit very often
    /// arrives fused into the reading rather than as its own observation.
    func testTrailingUnitInsideAReading() {
        XCTAssertEqual(ScreenFieldAnalyzer.trailingUnit(in: "12.345 V"), "V")
        XCTAssertEqual(ScreenFieldAnalyzer.trailingUnit(in: "1.5mA"), "mA")
        XCTAssertEqual(ScreenFieldAnalyzer.trailingUnit(in: "230 kW"), "kW")
        XCTAssertEqual(ScreenFieldAnalyzer.trailingUnit(in: "45 %"), "%")
        XCTAssertEqual(ScreenFieldAnalyzer.trailingUnit(in: "VOLTAGE 12.345 mV"), "mV")
        XCTAssertNil(ScreenFieldAnalyzer.trailingUnit(in: "12.345"))
        XCTAssertNil(ScreenFieldAnalyzer.trailingUnit(in: "12.3 AC"))
        XCTAssertNil(ScreenFieldAnalyzer.trailingUnit(in: "VOLTAGE"))
    }

    /// The symmetric half: the same line grouping that fuses the unit onto the
    /// right of a reading fuses its caption onto the left. Without this the
    /// common case on a real instrument returns a correctly parsed number with
    /// no caption — the one thing that tells two readouts apart.
    func testLeadingLabelInsideAReading() {
        XCTAssertEqual(ScreenFieldAnalyzer.leadingLabel(in: "VOLTAGE 12.345 mV"), "VOLTAGE")
        XCTAssertEqual(ScreenFieldAnalyzer.leadingLabel(in: "CH1 12.345 V"), "CH1")
        XCTAssertEqual(ScreenFieldAnalyzer.leadingLabel(in: "DC VOLTS: 12.345"), "DC VOLTS")
        XCTAssertEqual(ScreenFieldAnalyzer.leadingLabel(in: "POWER 15.23"), "POWER")
        // Nothing to the left, or nothing with a letter in it.
        XCTAssertNil(ScreenFieldAnalyzer.leadingLabel(in: "12.345 V"))
        XCTAssertNil(ScreenFieldAnalyzer.leadingLabel(in: "-12.3"))
        XCTAssertNil(ScreenFieldAnalyzer.leadingLabel(in: "(12.345)"))
        XCTAssertNil(ScreenFieldAnalyzer.leadingLabel(in: "VOLTAGE"))
    }

    func testIsMostlyDigits() {
        XCTAssertTrue(ScreenFieldAnalyzer.isMostlyDigits("12345"))
        XCTAssertTrue(ScreenFieldAnalyzer.isMostlyDigits("12.345 V"))
        XCTAssertFalse(ScreenFieldAnalyzer.isMostlyDigits("VOLTAGE"))
        XCTAssertFalse(ScreenFieldAnalyzer.isMostlyDigits(""))
        XCTAssertFalse(ScreenFieldAnalyzer.isMostlyDigits("ABCDE1"))
    }

    // MARK: - Format inference

    func testInferredFormatDecimalReading() throws {
        let format = try XCTUnwrap(ScreenFieldAnalyzer.inferredFormat(from: "12.345"))
        XCTAssertEqual(format.digitCount, 5)
        XCTAssertEqual(format.decimalPosition, 2)
        XCTAssertNil(format.unit)
    }

    func testInferredFormatSignedReading() throws {
        let format = try XCTUnwrap(ScreenFieldAnalyzer.inferredFormat(from: "-12.3"))
        XCTAssertEqual(format.digitCount, 3)
        XCTAssertEqual(format.decimalPosition, 2)
    }

    func testInferredFormatIntegerReadingHasNoDecimalPosition() throws {
        let format = try XCTUnwrap(ScreenFieldAnalyzer.inferredFormat(from: "1234"))
        XCTAssertEqual(format.digitCount, 4)
        XCTAssertNil(format.decimalPosition)
    }

    /// The second half of "one frame is evidence, not law": an unsigned frame
    /// proves nothing about whether the display can show a sign, and inferring
    /// `signAllowed = false` from one is the same mass-rejection bug in a
    /// second place — a DMM parked positive would reject every reading the
    /// moment it went negative. It is also stricter than the app's own
    /// `DisplayFormat.unconstrained` seed, which allows signs.
    func testInferredFormatAlwaysAllowsSign() {
        for reading in ["12.345", "1234", "0.00", ".5", "-12.3", "+0.05"] {
            XCTAssertEqual(ScreenFieldAnalyzer.inferredFormat(from: reading)?.signAllowed, true,
                           "inference from '\(reading)' must not forbid signs")
        }
        XCTAssertTrue(DisplayFormat.unconstrained.signAllowed,
                      "inference must not be stricter than the app's own seed")
    }

    func testInferredFormatLeadingDecimalPoint() throws {
        let format = try XCTUnwrap(ScreenFieldAnalyzer.inferredFormat(from: ".500"))
        XCTAssertEqual(format.digitCount, 3)
        XCTAssertEqual(format.decimalPosition, 0)
    }

    func testInferredFormatIgnoresTrailingUnit() throws {
        let format = try XCTUnwrap(ScreenFieldAnalyzer.inferredFormat(from: "12.345 V"))
        XCTAssertEqual(format.digitCount, 5)
        XCTAssertEqual(format.decimalPosition, 2)
    }

    func testInferredFormatIsNilWithoutDigits() {
        XCTAssertNil(ScreenFieldAnalyzer.inferredFormat(from: "VOLTAGE"))
        XCTAssertNil(ScreenFieldAnalyzer.inferredFormat(from: "----"))
    }

    /// The load-bearing property: one frame is evidence, not law. A meter
    /// parked at "0.00" must not mint a rule that rejects "12.345" later.
    func testInferredFormatNeverConstrains() {
        for reading in ["12.345", "-12.3", "1234", "0.00", ".5"] {
            let format = ScreenFieldAnalyzer.inferredFormat(from: reading)
            XCTAssertEqual(format?.constrainToFormat, false,
                           "inference from '\(reading)' must stay a suggestion")
        }
    }

    // MARK: - Region shaping

    func testNumericRegionIsPadded() {
        let raw = NormalizedROI(x: 0.40, y: 0.40, width: 0.20, height: 0.10)
        let padded = ScreenFieldAnalyzer.finalRegion(raw, kind: .numeric)
        XCTAssertGreaterThan(padded.width, raw.width)
        XCTAssertGreaterThan(padded.height, raw.height)
        XCTAssertEqual(padded.width, raw.width * (1 + 2 * ScreenFieldAnalyzer.numericRegionPadding),
                       accuracy: 1e-6)
        // Padding is symmetric: the centre must not move.
        XCTAssertEqual(padded.x + padded.width / 2, raw.x + raw.width / 2, accuracy: 1e-6)
        XCTAssertEqual(padded.y + padded.height / 2, raw.y + raw.height / 2, accuracy: 1e-6)
    }

    /// A one-glyph unit box is tiny; the shared `clamped()` would inflate it to
    /// the ROI-editor minimums, so descriptive regions must not go through it.
    func testUnitRegionIsNotInflatedToROIMinimums() {
        let raw = NormalizedROI(x: 0.80, y: 0.40, width: 0.02, height: 0.02)
        let shaped = ScreenFieldAnalyzer.finalRegion(raw, kind: .unit)
        XCTAssertEqual(shaped.width, 0.02, accuracy: 1e-9)
        XCTAssertEqual(shaped.height, 0.02, accuracy: 1e-9)
    }

    /// The same argument applies to NUMERIC regions, and there it is worse than
    /// cosmetic: every association cost reads `maxX`, `midY`, `width` and
    /// `height` off this region, so an ROI-editor minimum applied here computes
    /// label and unit matching against geometry the display does not have. A
    /// single-glyph reading is 2% wide and `clamped()` would inflate it 2.5×.
    func testNumericRegionIsNotInflatedToROIMinimums() {
        let raw = NormalizedROI(x: 0.40, y: 0.40, width: 0.02, height: 0.02)
        let shaped = ScreenFieldAnalyzer.finalRegion(raw, kind: .numeric)
        let pad = ScreenFieldAnalyzer.numericRegionPadding
        XCTAssertEqual(shaped.width, 0.02 * (1 + 2 * pad), accuracy: 1e-9)
        XCTAssertEqual(shaped.height, 0.02 * (1 + 2 * pad), accuracy: 1e-9)
        XCTAssertLessThan(shaped.width, NormalizedROI.minimumWidth)
        XCTAssertLessThan(shaped.height, NormalizedROI.minimumHeight)
    }

    func testRegionsAreClampedIntoTheUnitSquare() {
        let raw = NormalizedROI(x: -0.10, y: -0.05, width: 0.30, height: 0.20)
        let shaped = ScreenFieldAnalyzer.finalRegion(raw, kind: .label)
        XCTAssertGreaterThanOrEqual(shaped.x, 0)
        XCTAssertGreaterThanOrEqual(shaped.y, 0)
        XCTAssertLessThanOrEqual(shaped.x + shaped.width, 1 + 1e-9)
        XCTAssertLessThanOrEqual(shaped.y + shaped.height, 1 + 1e-9)
    }

    /// A reading flush against the canonical image's left edge is ordinary —
    /// the warp is fitted to the bezel. Overflow must be CLIPPED: shifting the
    /// box back inside to preserve its width slides it off the glyphs it was
    /// measured from, losing the padding on the side that overflowed and
    /// over-extending on the opposite one.
    func testOverflowingRegionIsClippedNotShifted() {
        let flushLeft = NormalizedROI(x: 0, y: 0.40, width: 0.20, height: 0.10)
        let shaped = ScreenFieldAnalyzer.finalRegion(flushLeft, kind: .numeric)
        let padY = 0.10 * ScreenFieldAnalyzer.numericRegionPadding
        XCTAssertEqual(shaped.x, 0, accuracy: 1e-9)
        // Right edge keeps its full pad; the left pad is simply cut off.
        XCTAssertEqual(shaped.x + shaped.width,
                       0.20 * (1 + ScreenFieldAnalyzer.numericRegionPadding), accuracy: 1e-9)
        XCTAssertEqual(shaped.y, 0.40 - padY, accuracy: 1e-9)

        let flushRight = NormalizedROI(x: 0.80, y: 0.40, width: 0.20, height: 0.10)
        let clipped = ScreenFieldAnalyzer.finalRegion(flushRight, kind: .numeric)
        XCTAssertEqual(clipped.x, 0.80 - 0.20 * ScreenFieldAnalyzer.numericRegionPadding,
                       accuracy: 1e-9)
        XCTAssertEqual(clipped.x + clipped.width, 1, accuracy: 1e-9)
    }

    // MARK: - Label / unit association (pure geometry)

    func testAssociatesLabelLeftAndUnitRightOnEachRow() {
        let fields = [
            makeField(.label, "VOLTAGE", x: 0.05, y: 0.10, w: 0.25, h: 0.10),
            makeField(.numeric, "12.345", x: 0.35, y: 0.10, w: 0.35, h: 0.10),
            makeField(.unit, "V", x: 0.75, y: 0.10, w: 0.07, h: 0.10),
            makeField(.label, "CURRENT", x: 0.05, y: 0.40, w: 0.25, h: 0.10),
            makeField(.numeric, "1.234", x: 0.35, y: 0.40, w: 0.35, h: 0.10),
            makeField(.unit, "A", x: 0.75, y: 0.40, w: 0.07, h: 0.10)
        ]
        let associated = ScreenFieldAnalyzer.associating(fields)

        XCTAssertEqual(associated[1].label, "VOLTAGE")
        XCTAssertEqual(associated[1].format.unit, "V")
        XCTAssertEqual(associated[4].label, "CURRENT")
        XCTAssertEqual(associated[4].format.unit, "A")
    }

    func testAssociatesLabelSittingAboveItsNumber() {
        let fields = [
            makeField(.label, "POWER", x: 0.30, y: 0.58, w: 0.20, h: 0.06),
            makeField(.numeric, "15.23", x: 0.30, y: 0.66, w: 0.30, h: 0.10),
            makeField(.unit, "W", x: 0.63, y: 0.66, w: 0.07, h: 0.10)
        ]
        let associated = ScreenFieldAnalyzer.associating(fields)
        XCTAssertEqual(associated[1].label, "POWER")
        XCTAssertEqual(associated[1].format.unit, "W")
    }

    /// A unit on the row BELOW belongs to that row's number, never to this one.
    func testUnitBelowIsNotAssociated() {
        let fields = [
            makeField(.numeric, "12.345", x: 0.35, y: 0.10, w: 0.35, h: 0.10),
            makeField(.unit, "A", x: 0.75, y: 0.60, w: 0.07, h: 0.10)
        ]
        let associated = ScreenFieldAnalyzer.associating(fields)
        XCTAssertNil(associated[0].format.unit)
    }

    /// A far-away caption on the opposite side of the panel is not this
    /// number's caption.
    func testDistantLabelIsNotAssociated() {
        let fields = [
            makeField(.label, "VOLTAGE", x: 0.00, y: 0.10, w: 0.10, h: 0.10),
            makeField(.numeric, "12.345", x: 0.80, y: 0.10, w: 0.18, h: 0.10)
        ]
        let associated = ScreenFieldAnalyzer.associating(fields)
        XCTAssertEqual(associated[1].label, "")
    }

    /// One caption serves one number: the nearer number wins it outright
    /// rather than both rows claiming "VOLTAGE".
    func testLabelAssignmentIsExclusive() {
        let fields = [
            makeField(.label, "VOLTAGE", x: 0.05, y: 0.10, w: 0.20, h: 0.10),
            makeField(.numeric, "12.345", x: 0.30, y: 0.10, w: 0.30, h: 0.10),
            makeField(.numeric, "99.999", x: 0.65, y: 0.10, w: 0.30, h: 0.10)
        ]
        let associated = ScreenFieldAnalyzer.associating(fields)
        XCTAssertEqual(associated[1].label, "VOLTAGE")
        XCTAssertEqual(associated[2].label, "")
    }

    /// A number that read its unit out of its own text has direct evidence and
    /// must not also consume the neighbouring unit token — that token belongs
    /// to the number on the row that has none. Without the exclusion the
    /// nearer (already-united) number wins the token and "4.56" stays
    /// dimensionless.
    func testInTextUnitFreesTheNeighbouringTokenForAnotherNumber() {
        var fused = makeField(.numeric, "", x: 0.30, y: 0.10, w: 0.20, h: 0.10)
        fused.format.unit = "V"
        let fields = [
            makeField(.numeric, "", x: 0.05, y: 0.10, w: 0.20, h: 0.10),
            fused,
            makeField(.unit, "A", x: 0.55, y: 0.10, w: 0.05, h: 0.10)
        ]
        let associated = ScreenFieldAnalyzer.associating(fields)
        XCTAssertEqual(associated[1].format.unit, "V", "in-text unit must not be overwritten")
        XCTAssertEqual(associated[0].format.unit, "A",
                       "the freed token belongs to the number that has no unit")
    }

    /// The symmetric rule for captions: a reading that recovered its caption
    /// from its own fused line leaves the separate caption to the number that
    /// has none.
    func testInTextLabelFreesTheNeighbouringCaptionForAnotherNumber() {
        let fields = [
            makeField(.label, "CURRENT", x: 0.05, y: 0.10, w: 0.20, h: 0.10),
            makeField(.numeric, "", x: 0.30, y: 0.10, w: 0.20, h: 0.10),
            makeField(.numeric, "", x: 0.60, y: 0.10, w: 0.20, h: 0.10)
        ]
        var fused = fields
        fused[1].label = "VOLTAGE"

        let unfused = ScreenFieldAnalyzer.associating(fields)
        XCTAssertEqual(unfused[1].label, "CURRENT", "nearest number wins when nothing is fused")
        XCTAssertEqual(unfused[2].label, "")

        let associated = ScreenFieldAnalyzer.associating(fused)
        XCTAssertEqual(associated[1].label, "VOLTAGE", "fused caption must not be overwritten")
        XCTAssertEqual(associated[2].label, "CURRENT",
                       "the freed caption belongs to the number that has none")
    }

    /// The "left" and "above" costs are compared against each other, so they
    /// must be in the same units. Measuring both in multiples of the NUMBER's
    /// own box does that; raw normalized distances do not, because normalized x
    /// and y are only the same physical scale on a square canonical image.
    /// Here a caption half a box-width to the left and one half a box-height
    /// above are equidistant by construction and must score identically for a
    /// deliberately non-square number box.
    func testLabelCostPutsBothDirectionsOnOneScale() throws {
        let numeric = NormalizedROI(x: 0.30, y: 0.50, width: 0.40, height: 0.10)
        let left = NormalizedROI(x: 0.00, y: 0.50, width: 0.10, height: 0.10)
        let above = NormalizedROI(x: 0.45, y: 0.39, width: 0.10, height: 0.06)

        let leftCost = try XCTUnwrap(ScreenFieldAnalyzer.labelCost(left, numeric))
        let aboveCost = try XCTUnwrap(ScreenFieldAnalyzer.labelCost(above, numeric))
        XCTAssertEqual(leftCost, aboveCost, accuracy: 1e-9)
    }

    func testAssociationLeavesNonNumericFieldsAlone() {
        let fields = [
            makeField(.label, "VOLTAGE", x: 0.05, y: 0.10, w: 0.25, h: 0.10),
            makeField(.numeric, "12.345", x: 0.35, y: 0.10, w: 0.35, h: 0.10)
        ]
        let associated = ScreenFieldAnalyzer.associating(fields)
        XCTAssertEqual(associated[0].label, "VOLTAGE")
        XCTAssertEqual(associated[0].kind, .label)
    }

    // MARK: - Ordering

    func testNumericFieldsAreReturnedFirstInReadingOrder() {
        let fields = [
            makeField(.unit, "V", x: 0.75, y: 0.10, w: 0.07, h: 0.10),
            makeField(.numeric, "1.234", x: 0.35, y: 0.40, w: 0.35, h: 0.10),
            makeField(.label, "VOLTAGE", x: 0.05, y: 0.10, w: 0.25, h: 0.10),
            makeField(.numeric, "12.345", x: 0.35, y: 0.10, w: 0.35, h: 0.10)
        ]
        let ordered = ScreenFieldAnalyzer.ordered(fields)
        XCTAssertEqual(ordered.map(\.kind), [.numeric, .numeric, .label, .unit])
        XCTAssertEqual(ordered[0].region.y, 0.10, accuracy: 1e-9)
        XCTAssertEqual(ordered[1].region.y, 0.40, accuracy: 1e-9)
    }

    /// The exact configuration that a tolerance-comparator gets wrong. With
    /// y = 0.000 / 0.015 / 0.030 the middle field ties with both ends while the
    /// ends compare by y, so `a < b` is false, `b < c` is false and `a < c` is
    /// true — not transitive, and therefore not a strict weak ordering.
    /// Bucketing into rows first is well-defined here: the first two share a
    /// row (both within tolerance of its topmost member) and sort by x; the
    /// third starts a new row.
    func testOrderingIsWellDefinedForOverlappingRowTolerances() {
        let fields = [
            makeField(.numeric, "", x: 0.90, y: 0.000, w: 0.05, h: 0.05),
            makeField(.numeric, "", x: 0.50, y: 0.015, w: 0.05, h: 0.05),
            makeField(.numeric, "", x: 0.10, y: 0.030, w: 0.05, h: 0.05)
        ]
        let ordered = ScreenFieldAnalyzer.ordered(fields)
        XCTAssertEqual(ordered.map { $0.region.x }, [0.50, 0.90, 0.10])
    }

    /// A comparator that is not a strict weak ordering does not merely produce
    /// an odd order — `sorted(by:)` is free to produce anything. Sixty fields
    /// in twelve rows, each row deliberately drifting within tolerance, fed in
    /// a fixed scramble: the result must be exactly row-major reading order.
    func testSixtyFieldsSortIntoExactReadingOrder() {
        let rows = 12, columns = 5
        var expected: [ScreenField] = []
        for row in 0..<rows {
            for column in 0..<columns {
                // Within-row drift stays inside the tolerance; row pitch is far
                // outside it. The drift is what breaks a naive comparator.
                expected.append(makeField(.numeric, "",
                                          x: 0.05 + CGFloat(column) * 0.15,
                                          y: CGFloat(row) * 0.08 + CGFloat(column) * 0.004,
                                          w: 0.10, h: 0.05))
            }
        }
        // Deterministic scramble: 37 and 61 are coprime, so i ↦ 37i mod 61 is a
        // permutation of 0..<60. No randomness, no Date.
        let scrambled = expected.enumerated()
            .sorted { (37 * $0.offset) % 61 < (37 * $1.offset) % 61 }
            .map(\.element)
        XCTAssertNotEqual(scrambled.map(\.id), expected.map(\.id), "input must not start sorted")

        XCTAssertEqual(ScreenFieldAnalyzer.ordered(scrambled).map(\.id), expected.map(\.id))
    }

    /// Row bucketing anchors on each row's topmost member, so a long column of
    /// regions each drifting a little from the last cannot chain into one
    /// giant row.
    func testDriftingColumnDoesNotChainIntoOneRow() {
        let fields = (0..<6).map { index in
            makeField(.numeric, "", x: 0.90 - CGFloat(index) * 0.1,
                      y: CGFloat(index) * 0.015, w: 0.05, h: 0.05)
        }
        let ordered = ScreenFieldAnalyzer.ordered(fields)
        // Rows pair up as {0,1}, {2,3}, {4,5}; x descends, so each pair swaps.
        XCTAssertEqual(ordered.map(\.id), [1, 0, 3, 2, 5, 4].map { fields[$0].id })
    }

    // MARK: - End-to-end over a rendered panel

    /// Three panel rows, three numeric fields — EXACTLY three. A lower bound
    /// would be satisfied by a spurious fourth field minted out of an
    /// annunciator, which is the failure this pins shut.
    func testAnalyzesRenderedMultiFieldPanel() async throws {
        let rows: [PanelRow] = [
            // Two-glyph units: Vision routinely drops an isolated single
            // character, and this test is about the analyzer's layout
            // reasoning, not about Vision's small-run recall.
            PanelRow(label: "VOLTAGE", value: "12.345", unit: "mV"),
            PanelRow(label: "CURRENT", value: "1.234", unit: "mA"),
            PanelRow(label: "POWER", value: "15.23", unit: "kW")
        ]
        let buffer = try makePanel(rows: rows)
        let fields = await ScreenFieldAnalyzer().analyze(canonicalImage: buffer)

        let numeric = fields.filter { $0.kind == .numeric }
        XCTAssertEqual(numeric.count, 3,
                       "expected exactly one numeric field per panel row: \(describe(fields))")

        // Capturable things come first.
        XCTAssertEqual(fields.prefix(3).map(\.kind), [.numeric, .numeric, .numeric],
                       "numeric fields must all precede labels/units: \(describe(fields))")
        XCTAssertFalse(fields.dropFirst(3).contains { $0.kind == .numeric },
                       "numeric fields must all precede labels/units: \(describe(fields))")

        // Numeric fields come back in reading order, so field i IS row i — no
        // searching. This also pins orientation: a flipped buffer would put
        // "15.23" first.
        for (index, row) in rows.enumerated() {
            let expected = try XCTUnwrap(ScreenFieldAnalyzer.inferredFormat(from: row.value))
            let field = numeric[index]
            XCTAssertEqual(field.format.digitCount, expected.digitCount,
                           "row \(index) digit count: \(describe(fields))")
            XCTAssertEqual(field.format.decimalPosition, expected.decimalPosition,
                           "row \(index) decimal position: \(describe(fields))")
            XCTAssertEqual(field.label, row.label,
                           "row \(index) label association: \(describe(fields))")
            // Compared case-insensitively on purpose. The analyzer keeps the
            // spelling Vision returned rather than canonicalizing it (folding
            // "MV" to "mV" would turn megavolts into millivolts), and Vision
            // reads this rendering's "mV" as "mv". Whose case is right is a
            // recognition question, not this component's contract.
            XCTAssertEqual(field.format.unit?.lowercased(), row.unit.lowercased(),
                           "row \(index) unit association: \(describe(fields))")
            XCTAssertEqual(field.region.y, CGFloat(index) / 3, accuracy: 1 / 6,
                           "row \(index) must sit in its own third of the panel: \(describe(fields))")
            XCTAssertFalse(field.isSelected, "analysis must never pre-select a field")
            XCTAssertFalse(field.format.constrainToFormat,
                           "inferred formats must stay suggestions")
            XCTAssertGreaterThan(field.detectionConfidence, 0)
        }

        // Everything else is decoration, and every piece of it is one of the
        // strings the panel actually prints. How Vision GROUPS those runs is
        // its business, not this component's — on this rendering it fuses
        // "15.23 kW" into one line and leaves the other two units separate —
        // so the composition is pinned by content, not by count.
        let decoration = fields.dropFirst(3)
        XCTAssertEqual(Set(decoration.map(\.kind)), [.label, .unit],
                       "no unknown-kind fields expected: \(describe(fields))")
        for field in decoration {
            XCTAssertTrue(["VOLTAGE", "CURRENT", "POWER", "mV", "mA", "kW"]
                            .contains { $0.caseInsensitiveCompare(field.label) == .orderedSame },
                          "unexpected decoration '\(field.label)': \(describe(fields))")
        }
        XCTAssertEqual(decoration.filter { $0.kind == .label }.map(\.label),
                       ["VOLTAGE", "CURRENT", "POWER"],
                       "captions must come back in reading order: \(describe(fields))")
    }

    /// The fused-line case, through the real Vision path: an instrument that
    /// prints caption, reading and unit as ONE line. Vision returns that line
    /// as a single observation, so the analyzer must recover the caption from
    /// the reading's own text — otherwise every row here comes back as a
    /// correctly-parsed number with nothing to tell it apart from the others.
    func testAnalyzesFusedSingleLineRows() async throws {
        let rows: [PanelRow] = [
            PanelRow(label: "VOLTAGE", value: "12.345", unit: "mV"),
            PanelRow(label: "CURRENT", value: "1.234", unit: "mA"),
            PanelRow(label: "POWER", value: "15.23", unit: "kW")
        ]
        let buffer = try makePanel(rows: rows, fused: true)
        let fields = await ScreenFieldAnalyzer().analyze(canonicalImage: buffer)

        XCTAssertEqual(fields.count, 3,
                       "one fused line per row, one field per line: \(describe(fields))")
        for (index, row) in rows.enumerated() {
            let expected = try XCTUnwrap(ScreenFieldAnalyzer.inferredFormat(from: row.value))
            let field = fields[index]
            XCTAssertEqual(field.kind, .numeric, "row \(index): \(describe(fields))")
            XCTAssertEqual(field.label, row.label,
                           "row \(index) caption must be recovered from the fused line: "
                            + describe(fields))
            XCTAssertEqual(field.format.unit?.lowercased(), row.unit.lowercased(),
                           "row \(index) unit: \(describe(fields))")
            XCTAssertEqual(field.format.digitCount, expected.digitCount,
                           "row \(index) digit count: \(describe(fields))")
            XCTAssertEqual(field.format.decimalPosition, expected.decimalPosition,
                           "row \(index) decimal position: \(describe(fields))")
        }
    }

    /// The regression, end to end through real Vision: three rows whose units
    /// are NOT in `unitTokens`. Before the fix every one of these produced no
    /// numeric field at all, so a locked screen showing them yielded nothing
    /// capturable. Fused rows on purpose — that is the layout where the unit
    /// lands inside the reading's own observation and the vocabulary check used
    /// to decide the outcome.
    func testAnalyzesRowsWhoseUnitsAreNotInTheVocabulary() async throws {
        let rows: [PanelRow] = [
            PanelRow(label: "PRESSURE", value: "12.5", unit: "PSI"),
            PanelRow(label: "LINE", value: "230", unit: "VAC"),
            PanelRow(label: "FLOW", value: "350", unit: "CFM")
        ]
        for unit in rows.map(\.unit) {
            XCTAssertNil(ScreenFieldAnalyzer.unitToken(in: unit),
                         "\(unit) must be OUTSIDE the vocabulary for this test to mean anything")
        }

        let buffer = try makePanel(rows: rows, fused: true)
        let fields = await ScreenFieldAnalyzer().analyze(canonicalImage: buffer)

        let numeric = fields.filter { $0.kind == .numeric }
        XCTAssertEqual(numeric.count, 3,
                       "one reading per row, unrecognized units and all: \(describe(fields))")
        for (index, row) in rows.enumerated() {
            let expected = try XCTUnwrap(ScreenFieldAnalyzer.inferredFormat(from: row.value))
            let field = numeric[index]
            XCTAssertEqual(field.label, row.label, "row \(index) caption: \(describe(fields))")
            XCTAssertEqual(field.format.unit?.lowercased(), row.unit.lowercased(),
                           "row \(index) unit must be kept verbatim: \(describe(fields))")
            XCTAssertEqual(field.format.digitCount, expected.digitCount,
                           "row \(index) digit count: \(describe(fields))")
            XCTAssertEqual(field.format.decimalPosition, expected.decimalPosition,
                           "row \(index) decimal position: \(describe(fields))")
            XCTAssertFalse(field.format.constrainToFormat,
                           "a guessed unit must not come with a constraining format")
            XCTAssertFalse(field.isSelected, "analysis must never pre-select a field")
        }
    }

    func testEmptyImageYieldsNoFields() async throws {
        let buffer = try makePanel(rows: [])
        let fields = await ScreenFieldAnalyzer().analyze(canonicalImage: buffer)
        XCTAssertTrue(fields.isEmpty, "a blank panel should produce nothing: \(describe(fields))")
    }

    // MARK: - Helpers

    private func makeField(_ kind: FieldContentKind, _ text: String,
                           x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> ScreenField {
        ScreenField(region: NormalizedROI(x: x, y: y, width: w, height: h),
                    kind: kind,
                    label: kind == .numeric ? "" : text)
    }

    private func describe(_ fields: [ScreenField]) -> String {
        fields.map {
            "[\($0.kind.rawValue) '\($0.label)' \($0.format.patternPreview) "
                + "unit=\($0.format.unit ?? "-") "
                + String(format: "@(%.2f,%.2f %.2fx%.2f)",
                         $0.region.x, $0.region.y, $0.region.width, $0.region.height) + "]"
        }.joined(separator: " ")
    }

    private struct PanelRow {
        let label: String
        let value: String
        let unit: String
    }

    /// Renders a dark-on-light instrument panel: caption on the left, reading
    /// in the middle, unit on the right, one row per entry. Drawing goes
    /// straight into the destination buffer through a single y-flip, so the
    /// result is upright by construction.
    ///
    /// `fused` draws each row as one tight run instead — the layout that makes
    /// Vision return caption, reading and unit as a single observation.
    private func makePanel(rows: [PanelRow], fused: Bool = false,
                           size: CGSize = CGSize(width: 720, height: 480)) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(size.width), Int(size.height),
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &optional)
        let buffer = try XCTUnwrap(status == kCVReturnSuccess ? optional : nil)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let ctx = try XCTUnwrap(CGContext(
            data: base,
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue))

        // One flip only: after this the context is y-down/top-left, matching
        // both UIKit text drawing and NormalizedROI.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        guard !rows.isEmpty else { return buffer }

        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        let rowHeight = size.height / CGFloat(rows.count)
        let valueFont = UIFont.monospacedDigitSystemFont(ofSize: rowHeight * 0.34, weight: .semibold)
        let smallFont = UIFont.systemFont(ofSize: rowHeight * 0.20, weight: .semibold)

        for (index, row) in rows.enumerated() {
            let top = CGFloat(index) * rowHeight
            guard !fused else {
                draw("\(row.label) \(row.value) \(row.unit)", font: valueFont,
                     in: CGRect(x: size.width * 0.05, y: top + rowHeight * 0.28,
                                width: size.width * 0.90, height: rowHeight * 0.44),
                     alignment: .left)
                continue
            }
            draw(row.label, font: smallFont,
                 in: CGRect(x: size.width * 0.03, y: top + rowHeight * 0.36,
                            width: size.width * 0.26, height: rowHeight * 0.30),
                 alignment: .left)
            draw(row.value, font: valueFont,
                 in: CGRect(x: size.width * 0.36, y: top + rowHeight * 0.28,
                            width: size.width * 0.42, height: rowHeight * 0.44),
                 alignment: .right)
            draw(row.unit, font: smallFont,
                 in: CGRect(x: size.width * 0.85, y: top + rowHeight * 0.36,
                            width: size.width * 0.12, height: rowHeight * 0.30),
                 alignment: .left)
        }
        return buffer
    }

    private func draw(_ text: String, font: UIFont, in rect: CGRect, alignment: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]).draw(in: rect)
    }
}
