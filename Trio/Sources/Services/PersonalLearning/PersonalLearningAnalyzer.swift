import Foundation

enum PersonalLearningAnalyzer {
    private enum Config {
        static let observationWindow: TimeInterval = 6 * 60 * 60
        static let minimumOutcomeReadings = 3
        static let initialRiseThreshold = 20
        static let timeBucketMinutes = 5
        static let earlyWindowMinutes = 90
        static let delayedWindowMinutes = 120
        static let delayedHighFatWindowMinutes = 180
        static let consistentCorrectionThreshold = Decimal(5)
    }

    static func calculateCarbCorrection(aiEstimate: Decimal, userConfirmedCarbs: Decimal) -> Decimal {
        userConfirmedCarbs - aiEstimate
    }

    static func analyzeGlucoseOutcome(
        cgmReadings: [PersonalLearningGlucoseReading],
        mealTimestamp: Date,
        nextCarbEntryTimestamp: Date?
    ) -> GlucoseOutcomeMetrics {
        let observationEnd = min(
            nextCarbEntryTimestamp ?? mealTimestamp.addingTimeInterval(Config.observationWindow),
            mealTimestamp.addingTimeInterval(Config.observationWindow)
        )

        let readings = cgmReadings
            .filter { $0.date >= mealTimestamp && $0.date <= observationEnd }
            .sorted { $0.date < $1.date }

        guard readings.count >= Config.minimumOutcomeReadings else {
            return GlucoseOutcomeMetrics(
                observationStart: mealTimestamp,
                observationEnd: observationEnd,
                startingGlucose: readings.first?.glucose,
                startingTrend: readings.first?.trend,
                peakGlucose: readings.map(\.glucose).max(),
                timeToPeakMinutes: nil,
                lowestGlucose: readings.map(\.glucose).min(),
                timeBelow70Minutes: 0,
                timeBelow80Minutes: 0,
                timeAbove180Minutes: 0,
                timeAbove250Minutes: 0,
                percentTimeInRange: 0,
                earlyHypoglycemia: false,
                delayedHyperglycemia: false
            )
        }

        let starting = readings.first
        let peak = readings.max { $0.glucose < $1.glucose }
        let low = readings.min { $0.glucose < $1.glucose }
        let below70 = estimatedMinutes(readings: readings, matching: { $0.glucose < 70 })
        let below80 = estimatedMinutes(readings: readings, matching: { $0.glucose < 80 })
        let above180 = estimatedMinutes(readings: readings, matching: { $0.glucose > 180 })
        let above250 = estimatedMinutes(readings: readings, matching: { $0.glucose > 250 })
        let inRange = estimatedMinutes(readings: readings, matching: { $0.glucose >= 70 && $0.glucose <= 180 })
        let total = max(estimatedMinutes(readings: readings, matching: { _ in true }), Config.timeBucketMinutes)

        let earlyHypoglycemia = readings.contains { reading in
            reading.glucose < 80 && minutes(from: mealTimestamp, to: reading.date) <= Config.earlyWindowMinutes
        }
        let delayedHyperglycemia = readings.contains { reading in
            reading.glucose > 180 && minutes(from: mealTimestamp, to: reading.date) >= Config.delayedWindowMinutes
        }

        return GlucoseOutcomeMetrics(
            observationStart: mealTimestamp,
            observationEnd: observationEnd,
            startingGlucose: starting?.glucose,
            startingTrend: starting?.trend,
            peakGlucose: peak?.glucose,
            timeToPeakMinutes: peak.map { minutes(from: mealTimestamp, to: $0.date) },
            lowestGlucose: low?.glucose,
            timeBelow70Minutes: below70,
            timeBelow80Minutes: below80,
            timeAbove180Minutes: above180,
            timeAbove250Minutes: above250,
            percentTimeInRange: Decimal(inRange) / Decimal(total) * 100,
            earlyHypoglycemia: earlyHypoglycemia,
            delayedHyperglycemia: delayedHyperglycemia
        )
    }

    static func classifyOutcome(_ metrics: GlucoseOutcomeMetrics) -> GlucoseOutcomeClassification {
        guard let peak = metrics.peakGlucose, let low = metrics.lowestGlucose else {
            return .insufficientData
        }

        let hadLow = metrics.timeBelow70Minutes > 0 || metrics.timeBelow80Minutes > 0 || low < 80
        if hadLow, metrics.delayedHyperglycemia {
            return .earlyLowThenLateHigh
        }

        if hadLow {
            return .earlyLow
        }

        if metrics.delayedHyperglycemia {
            return .lateHigh
        }

        if peak > 180 {
            return .sustainedHigh
        }

        if peak <= 180 {
            return .inRange
        }

        return .insufficientData
    }

    static func calculateBolusTiming(bolusTimestamp: Date, mealTimestamp: Date) -> Int {
        minutes(from: bolusTimestamp, to: mealTimestamp)
    }

    static func classifyBolusStrategy(minutesPreBolus: Int) -> BolusStrategy {
        switch minutesPreBolus {
        case 10...:
            return .preBolus
        case 0 ..< 10:
            return .immediateBolus
        default:
            return .delayedBolus
        }
    }

    static func makeGlucoseOutcomeRecord(
        mealLearningRecordId: UUID,
        metrics: GlucoseOutcomeMetrics
    ) -> GlucoseOutcomeRecord {
        GlucoseOutcomeRecord(
            id: UUID(),
            mealLearningRecordId: mealLearningRecordId,
            observationStart: metrics.observationStart,
            observationEnd: metrics.observationEnd,
            startingGlucose: metrics.startingGlucose,
            startingTrend: metrics.startingTrend,
            peakGlucose: metrics.peakGlucose,
            timeToPeakMinutes: metrics.timeToPeakMinutes,
            lowestGlucose: metrics.lowestGlucose,
            timeBelow70Minutes: metrics.timeBelow70Minutes,
            timeBelow80Minutes: metrics.timeBelow80Minutes,
            timeAbove180Minutes: metrics.timeAbove180Minutes,
            timeAbove250Minutes: metrics.timeAbove250Minutes,
            percentTimeInRange: metrics.percentTimeInRange,
            earlyHypoglycemia: metrics.earlyHypoglycemia,
            delayedHyperglycemia: metrics.delayedHyperglycemia,
            outcomeClassification: classifyOutcome(metrics)
        )
    }

    static func classifyAbsorption(
        cgmReadings: [PersonalLearningGlucoseReading],
        mealTimestamp: Date,
        mealLearningRecordId: UUID = UUID()
    ) -> FoodAbsorptionRecord {
        let readings = cgmReadings
            .filter { $0.date >= mealTimestamp && $0.date <= mealTimestamp.addingTimeInterval(Config.observationWindow) }
            .sorted { $0.date < $1.date }

        guard let starting = readings.first, readings.count >= Config.minimumOutcomeReadings else {
            return FoodAbsorptionRecord(
                id: UUID(),
                mealLearningRecordId: mealLearningRecordId,
                absorptionClassification: .unclearInsufficientData,
                timeToInitialRiseMinutes: nil,
                timeToPeakMinutes: nil,
                delayedRise: false,
                highFatPatternLikely: false,
                confidence: .none
            )
        }

        let rise = readings.first { $0.glucose >= starting.glucose + Config.initialRiseThreshold }
        let peak = readings.max { $0.glucose < $1.glucose }
        let timeToInitialRise = rise.map { minutes(from: mealTimestamp, to: $0.date) }
        let timeToPeak = peak.map { minutes(from: mealTimestamp, to: $0.date) }
        let earlyLow = readings
            .contains { $0.glucose < 80 && minutes(from: mealTimestamp, to: $0.date) <= Config.earlyWindowMinutes }
        let delayedRise = (timeToInitialRise ?? Int.max) > Config.delayedWindowMinutes
        let highFatPatternLikely = delayedRise || (earlyLow && (timeToPeak ?? 0) >= Config.delayedHighFatWindowMinutes)

        let classification: FoodAbsorptionClassification
        switch timeToInitialRise {
        case .none:
            classification = .unclearInsufficientData
        case let .some(minutes) where highFatPatternLikely && minutes >= Config.delayedWindowMinutes:
            classification = .delayedHighFatPattern
        case let .some(minutes) where minutes < 60:
            classification = .fastAbsorption
        case let .some(minutes) where minutes <= 120:
            classification = .mediumAbsorption
        case .some:
            classification = .slowAbsorption
        }

        return FoodAbsorptionRecord(
            id: UUID(),
            mealLearningRecordId: mealLearningRecordId,
            absorptionClassification: classification,
            timeToInitialRiseMinutes: timeToInitialRise,
            timeToPeakMinutes: timeToPeak,
            delayedRise: delayedRise,
            highFatPatternLikely: highFatPatternLikely,
            confidence: confidence(recordCount: readings.count, consistent: classification != .unclearInsufficientData)
        )
    }

    static func generatePersonalLearningSummary(records: [MealLearningRecord]) -> PersonalLearningSummary {
        let category = records.first?.aiFoodCategory ?? ""
        let restaurant = records.first?.restaurantName
        let count = records.count
        let averageAiEstimate = average(records.map(\.aiEstimatedCarbs))
        let averageUserConfirmed = average(records.map(\.userConfirmedCarbs))
        let averageCorrection = average(records.map(\.carbCorrection))
        let correctionConsistent = recordsConsistentlyCorrect(records)

        return PersonalLearningSummary(
            foodCategory: category,
            restaurantName: restaurant,
            numberOfPriorMeals: count,
            averageAiEstimate: averageAiEstimate,
            averageUserConfirmedCarbs: averageUserConfirmed,
            averageCorrection: averageCorrection,
            mostCommonOutcomeClassification: mostCommon(records.compactMap(\.glucoseOutcome?.outcomeClassification)),
            mostSuccessfulBolusTimingRange: successfulBolusTimingRange(records: records),
            typicalAbsorptionClassification: mostCommon(records.compactMap(\.foodAbsorption?.absorptionClassification)),
            confidence: confidence(recordCount: count, consistent: correctionConsistent)
        )
    }

    static func suggestPersonalizedAdjustment(
        currentMealEstimate: Decimal,
        similarPriorRecords: [MealLearningRecord]
    ) -> PersonalizedAdjustmentSuggestion {
        let summary = generatePersonalLearningSummary(records: similarPriorRecords)
        guard similarPriorRecords.count >= 3 else {
            return PersonalizedAdjustmentSuggestion(
                advisoryMessages: ["Insufficient similar meal history. Review before using. Not medical advice."],
                suggestedCarbAdjustment: nil,
                confidence: .none,
                basedOnRecordCount: similarPriorRecords.count
            )
        }

        var messages = ["Based on your prior meals, this may suggest a pattern. Review before using. Not medical advice."]
        var adjustment: Decimal?

        if let averageCorrection = summary.averageCorrection {
            adjustment = averageCorrection
            let percent = currentMealEstimate == 0 ? 0 : (averageCorrection / currentMealEstimate * 100)
            if averageCorrection < 0 {
                messages.append("User usually reduces similar AI estimates by \(rounded(absolute(percent)))%.")
            } else if averageCorrection > 0 {
                messages.append("User usually increases similar AI estimates by \(rounded(percent))%.")
            }
        }

        if summary.mostCommonOutcomeClassification == .lateHigh {
            messages.append("Similar meals often showed a late high glucose pattern.")
        }

        if let absorption = summary.typicalAbsorptionClassification {
            messages.append("Typical absorption pattern appears \(displayName(for: absorption)).")
        }

        if let range = summary.mostSuccessfulBolusTimingRange {
            messages.append("Prior successful meals used about a \(range.lowerBound)-\(range.upperBound) minute pre-bolus.")
        }

        return PersonalizedAdjustmentSuggestion(
            advisoryMessages: messages,
            suggestedCarbAdjustment: adjustment,
            confidence: summary.confidence,
            basedOnRecordCount: similarPriorRecords.count
        )
    }

    private static func estimatedMinutes(
        readings: [PersonalLearningGlucoseReading],
        matching predicate: (PersonalLearningGlucoseReading) -> Bool
    ) -> Int {
        readings.filter(predicate).count * Config.timeBucketMinutes
    }

    private static func minutes(from start: Date, to end: Date) -> Int {
        Int(end.timeIntervalSince(start) / 60)
    }

    private static func average(_ values: [Decimal]) -> Decimal? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Decimal(values.count)
    }

    private static func mostCommon<T: Hashable>(_ values: [T]) -> T? {
        values.reduce(into: [:]) { counts, value in
            counts[value, default: 0] += 1
        }
        .max { $0.value < $1.value }?
        .key
    }

    private static func recordsConsistentlyCorrect(_ records: [MealLearningRecord]) -> Bool {
        guard records.count >= 3 else { return false }
        let corrections = records.map(\.carbCorrection)
        let mostlyNegative = corrections.filter { $0 <= -Config.consistentCorrectionThreshold }.count
        let mostlyPositive = corrections.filter { $0 >= Config.consistentCorrectionThreshold }.count
        return mostlyNegative >= 3 || mostlyPositive >= 3
    }

    private static func confidence(recordCount: Int, consistent: Bool) -> PersonalLearningConfidence {
        guard recordCount >= 3 else { return .none }
        if recordCount >= 8, consistent { return .high }
        if recordCount >= 5, consistent { return .medium }
        return .low
    }

    private static func successfulBolusTimingRange(records: [MealLearningRecord]) -> BolusTimingRange? {
        let successfulTimings = records.compactMap { record -> Int? in
            guard record.glucoseOutcome?.outcomeClassification == .inRange,
                  let timing = record.bolusTiming?.minutesPreBolus
            else {
                return nil
            }
            return timing
        }

        guard let averageTiming = average(successfulTimings.map { Decimal($0) }) else { return nil }
        let center = Int(truncating: NSDecimalNumber(decimal: averageTiming))
        return BolusTimingRange(lowerBound: max(0, center - 5), upperBound: max(0, center + 5))
    }

    private static func absolute(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }

    private static func rounded(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).rounding(accordingToBehavior: nil).stringValue
    }

    static func displayName(for absorption: FoodAbsorptionClassification) -> String {
        switch absorption {
        case .fastAbsorption:
            return "fast"
        case .mediumAbsorption:
            return "medium"
        case .slowAbsorption:
            return "slow"
        case .delayedHighFatPattern:
            return "delayed/high-fat"
        case .unclearInsufficientData:
            return "unclear"
        }
    }
}
