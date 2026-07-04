import Foundation
import Testing
@testable import Trio

struct PersonalLearningAnalyzerTests {
    @Test("Calculates user carb correction") func calculatesCarbCorrection() {
        let correction = PersonalLearningAnalyzer.calculateCarbCorrection(aiEstimate: 40, userConfirmedCarbs: 28)
        #expect(correction == -12)
    }

    @Test("Classifies glucose outcomes with transparent rules") func classifiesGlucoseOutcomes() {
        let start = Date(timeIntervalSince1970: 0)

        let good = GlucoseOutcomeMetrics(
            observationStart: start,
            observationEnd: start.addingTimeInterval(6 * 60 * 60),
            startingGlucose: 110,
            startingTrend: "flat",
            peakGlucose: 170,
            timeToPeakMinutes: 90,
            lowestGlucose: 90,
            timeBelow70Minutes: 0,
            timeBelow80Minutes: 0,
            timeAbove180Minutes: 0,
            timeAbove250Minutes: 0,
            percentTimeInRange: 100,
            earlyHypoglycemia: false,
            delayedHyperglycemia: false
        )
        #expect(PersonalLearningAnalyzer.classifyOutcome(good) == .inRange)

        var underestimated = good
        underestimated.peakGlucose = 220
        underestimated.timeAbove180Minutes = 90
        #expect(PersonalLearningAnalyzer.classifyOutcome(underestimated) == .sustainedHigh)

        var overestimated = good
        overestimated.lowestGlucose = 68
        overestimated.timeBelow70Minutes = 10
        #expect(PersonalLearningAnalyzer.classifyOutcome(overestimated) == .earlyLow)

        var delayed = good
        delayed.peakGlucose = 210
        delayed.timeToPeakMinutes = 210
        delayed.timeAbove180Minutes = 60
        delayed.delayedHyperglycemia = true
        #expect(PersonalLearningAnalyzer.classifyOutcome(delayed) == .lateHigh)

        var earlyLowThenLateHigh = good
        earlyLowThenLateHigh.lowestGlucose = 72
        earlyLowThenLateHigh.timeBelow80Minutes = 10
        earlyLowThenLateHigh.peakGlucose = 215
        earlyLowThenLateHigh.timeAbove180Minutes = 45
        earlyLowThenLateHigh.delayedHyperglycemia = true
        #expect(PersonalLearningAnalyzer.classifyOutcome(earlyLowThenLateHigh) == .earlyLowThenLateHigh)
    }

    @Test("Summarizes CGM outcome window") func analyzesGlucoseOutcomeWindow() {
        let meal = Date(timeIntervalSince1970: 0)
        let readings = [
            reading(meal, 100),
            reading(meal.addingTimeInterval(60 * 60), 150),
            reading(meal.addingTimeInterval(120 * 60), 190),
            reading(meal.addingTimeInterval(180 * 60), 170)
        ]

        let metrics = PersonalLearningAnalyzer.analyzeGlucoseOutcome(
            cgmReadings: readings,
            mealTimestamp: meal,
            nextCarbEntryTimestamp: nil
        )

        #expect(metrics.startingGlucose == 100)
        #expect(metrics.peakGlucose == 190)
        #expect(metrics.timeToPeakMinutes == 120)
        #expect(metrics.timeAbove180Minutes == 5)
        #expect(metrics.delayedHyperglycemia)

        let recordId = UUID()
        let outcomeRecord = PersonalLearningAnalyzer.makeGlucoseOutcomeRecord(mealLearningRecordId: recordId, metrics: metrics)
        #expect(outcomeRecord.mealLearningRecordId == recordId)
        #expect(outcomeRecord.outcomeClassification == .lateHigh)
    }

    @Test("Calculates bolus timing and strategy") func calculatesBolusTiming() {
        let meal = Date(timeIntervalSince1970: 12 * 60 * 60)
        let preBolus = meal.addingTimeInterval(-15 * 60)
        let delayedBolus = meal.addingTimeInterval(10 * 60)

        #expect(PersonalLearningAnalyzer.calculateBolusTiming(bolusTimestamp: preBolus, mealTimestamp: meal) == 15)
        #expect(PersonalLearningAnalyzer.classifyBolusStrategy(minutesPreBolus: 15) == .preBolus)
        #expect(PersonalLearningAnalyzer.calculateBolusTiming(bolusTimestamp: delayedBolus, mealTimestamp: meal) == -10)
        #expect(PersonalLearningAnalyzer.classifyBolusStrategy(minutesPreBolus: -10) == .delayedBolus)
    }

    @Test("Classifies food absorption profile") func classifiesAbsorption() {
        let meal = Date(timeIntervalSince1970: 0)
        let fastReadings = [
            reading(meal, 100),
            reading(meal.addingTimeInterval(45 * 60), 125),
            reading(meal.addingTimeInterval(90 * 60), 150)
        ]
        #expect(
            PersonalLearningAnalyzer.classifyAbsorption(cgmReadings: fastReadings, mealTimestamp: meal)
                .absorptionClassification == .fastAbsorption
        )

        let delayedReadings = [
            reading(meal, 110),
            reading(meal.addingTimeInterval(90 * 60), 105),
            reading(meal.addingTimeInterval(150 * 60), 135),
            reading(meal.addingTimeInterval(210 * 60), 190)
        ]
        let delayed = PersonalLearningAnalyzer.classifyAbsorption(cgmReadings: delayedReadings, mealTimestamp: meal)
        #expect(delayed.absorptionClassification == .delayedHighFatPattern)
        #expect(delayed.delayedRise)

        let recordId = UUID()
        let linked = PersonalLearningAnalyzer.classifyAbsorption(
            cgmReadings: delayedReadings,
            mealTimestamp: meal,
            mealLearningRecordId: recordId
        )
        #expect(linked.mealLearningRecordId == recordId)
    }

    private func reading(_ date: Date, _ glucose: Int) -> PersonalLearningGlucoseReading {
        PersonalLearningGlucoseReading(date: date, glucose: glucose, trend: nil)
    }
}
