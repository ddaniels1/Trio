import Foundation
import Swinject

protocol PersonalLearningStorage {
    func records() async -> [MealLearningRecord]
    func records(similarTo context: PendingAIMealLearningContext) async -> [MealLearningRecord]
    func saveMealLearningRecord(_ record: MealLearningRecord) async
    func updateMealLearningRecord(_ record: MealLearningRecord) async
    func summary(similarTo context: PendingAIMealLearningContext) async -> PersonalLearningSummary
    func suggestion(for context: PendingAIMealLearningContext) async -> PersonalizedAdjustmentSuggestion
}

final class BasePersonalLearningStorage: PersonalLearningStorage, Injectable {
    @Injected() private var fileStorage: FileStorage!

    private enum Config {
        static let recordsFile = "trio/personal-learning/meal-learning-records.json"
    }

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    func records() async -> [MealLearningRecord] {
        await fileStorage.retrieveAsync(Config.recordsFile, as: [MealLearningRecord].self) ?? []
    }

    func records(similarTo context: PendingAIMealLearningContext) async -> [MealLearningRecord] {
        let allRecords = await records()
        return allRecords.filter { record in
            isSimilar(record: record, to: context)
        }
    }

    func saveMealLearningRecord(_ record: MealLearningRecord) async {
        var allRecords = await records()
        if let index = allRecords.firstIndex(where: { $0.id == record.id }) {
            allRecords[index] = record
        } else {
            allRecords.append(record)
        }
        await fileStorage.saveAsync(allRecords, as: Config.recordsFile)
    }

    func updateMealLearningRecord(_ record: MealLearningRecord) async {
        await saveMealLearningRecord(record)
    }

    func summary(similarTo context: PendingAIMealLearningContext) async -> PersonalLearningSummary {
        PersonalLearningAnalyzer.generatePersonalLearningSummary(records: await records(similarTo: context))
    }

    func suggestion(for context: PendingAIMealLearningContext) async -> PersonalizedAdjustmentSuggestion {
        PersonalLearningAnalyzer.suggestPersonalizedAdjustment(
            currentMealEstimate: context.aiEstimatedCarbs,
            similarPriorRecords: await records(similarTo: context)
        )
    }

    private func isSimilar(record: MealLearningRecord, to context: PendingAIMealLearningContext) -> Bool {
        let recordCategory = record.aiFoodCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let contextCategory = context.aiFoodCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if !recordCategory.isEmpty, recordCategory == contextCategory {
            return true
        }

        if let restaurant = context.restaurantName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !restaurant.isEmpty,
           record.restaurantName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == restaurant
        {
            return true
        }

        return normalizedTokens(record.aiMealDescription).contains { normalizedTokens(context.aiMealDescription).contains($0) }
    }

    private func normalizedTokens(_ text: String) -> Set<String> {
        let ignoredWords: Set<String> = ["and", "with", "meal", "food", "plate", "mixed"]
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !ignoredWords.contains($0) }
        return Set(tokens)
    }
}

protocol PersonalLearningOutcomeBackfill {
    @discardableResult func backfillCompletedOutcomes(now: Date) async -> Int
}

final class BasePersonalLearningOutcomeBackfill: PersonalLearningOutcomeBackfill, Injectable {
    @Injected() private var personalLearningStorage: PersonalLearningStorage!

    private enum Config {
        static let observationWindow: TimeInterval = 6 * 60 * 60
    }

    private let context = CoreDataStack.shared.newTaskContext()

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    @discardableResult func backfillCompletedOutcomes(now: Date = Date()) async -> Int {
        let records = await personalLearningStorage.records()
        var updatedCount = 0

        for var record in records where record.glucoseOutcome == nil || record.foodAbsorption == nil {
            let nextCarbEntryTimestamp = await nextCarbEntryTimestamp(after: record.mealTimestamp)
            let observationEnd = min(
                nextCarbEntryTimestamp ?? record.mealTimestamp.addingTimeInterval(Config.observationWindow),
                record.mealTimestamp.addingTimeInterval(Config.observationWindow)
            )

            guard now >= observationEnd else { continue }

            let readings = await glucoseReadings(from: record.mealTimestamp, through: observationEnd)
            let metrics = PersonalLearningAnalyzer.analyzeGlucoseOutcome(
                cgmReadings: readings,
                mealTimestamp: record.mealTimestamp,
                nextCarbEntryTimestamp: nextCarbEntryTimestamp
            )

            if record.glucoseOutcome == nil {
                record.glucoseOutcome = PersonalLearningAnalyzer.makeGlucoseOutcomeRecord(
                    mealLearningRecordId: record.id,
                    metrics: metrics
                )
            }

            if record.foodAbsorption == nil {
                record.foodAbsorption = PersonalLearningAnalyzer.classifyAbsorption(
                    cgmReadings: readings,
                    mealTimestamp: record.mealTimestamp,
                    mealLearningRecordId: record.id
                )
            }

            await personalLearningStorage.updateMealLearningRecord(record)
            updatedCount += 1
        }

        return updatedCount
    }

    private func nextCarbEntryTimestamp(after mealTimestamp: Date) async -> Date? {
        await context.perform { [context] in
            let request = CarbEntryStored.fetchRequest()
            request.predicate = NSPredicate(
                format: "date > %@ AND date <= %@ AND carbs > 0 AND isFPU == %@",
                mealTimestamp.addingTimeInterval(1) as NSDate,
                mealTimestamp.addingTimeInterval(Config.observationWindow) as NSDate,
                false as NSNumber
            )
            request.sortDescriptors = [NSSortDescriptor(keyPath: \CarbEntryStored.date, ascending: true)]
            request.fetchLimit = 1

            do {
                return try context.fetch(request).first?.date
            } catch {
                debug(.storage, "Failed to fetch next carb entry for personal learning: \(error)")
                return nil
            }
        }
    }

    private func glucoseReadings(from start: Date, through end: Date) async -> [PersonalLearningGlucoseReading] {
        await context.perform { [context] in
            let request = GlucoseStored.fetchRequest()
            request.predicate = NSPredicate(format: "date >= %@ AND date <= %@", start as NSDate, end as NSDate)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \GlucoseStored.date, ascending: true)]

            do {
                return try context.fetch(request).compactMap { stored in
                    guard let date = stored.date else { return nil }
                    return PersonalLearningGlucoseReading(
                        date: date,
                        glucose: Int(stored.glucose),
                        trend: stored.direction
                    )
                }
            } catch {
                debug(.storage, "Failed to fetch glucose readings for personal learning: \(error)")
                return []
            }
        }
    }
}
