import Foundation

struct MealLearningRecord: Identifiable, JSON, Equatable {
    let id: UUID
    var createdAt: Date
    var mealTimestamp: Date
    var aiMealDescription: String
    var aiFoodCategory: String
    var aiEstimatedCarbs: Decimal
    var userConfirmedCarbs: Decimal
    var carbCorrection: Decimal
    var aiHighFatFlag: Bool
    var aiEstimatedAbsorptionType: FoodAbsorptionClassification?
    var restaurantName: String?
    var imageReference: String?
    var notes: String?
    var glucoseOutcome: GlucoseOutcomeRecord?
    var bolusTiming: BolusTimingRecord?
    var foodAbsorption: FoodAbsorptionRecord?
}

struct GlucoseOutcomeRecord: Identifiable, JSON, Equatable {
    let id: UUID
    var mealLearningRecordId: UUID
    var observationStart: Date
    var observationEnd: Date
    var startingGlucose: Int?
    var startingTrend: String?
    var peakGlucose: Int?
    var timeToPeakMinutes: Int?
    var lowestGlucose: Int?
    var timeBelow70Minutes: Int
    var timeBelow80Minutes: Int
    var timeAbove180Minutes: Int
    var timeAbove250Minutes: Int
    var percentTimeInRange: Decimal
    var earlyHypoglycemia: Bool
    var delayedHyperglycemia: Bool
    var outcomeClassification: GlucoseOutcomeClassification
}

struct BolusTimingRecord: Identifiable, JSON, Equatable {
    let id: UUID
    var mealLearningRecordId: UUID
    var bolusTimestamp: Date
    var mealTimestamp: Date
    var minutesPreBolus: Int
    var glucoseAtBolus: Int?
    var glucoseAtMeal: Int?
    var trendAtBolus: String?
    var trendAtMeal: String?
    var bolusAmount: Decimal?
    var bolusStrategy: BolusStrategy
}

struct FoodAbsorptionRecord: Identifiable, JSON, Equatable {
    let id: UUID
    var mealLearningRecordId: UUID
    var absorptionClassification: FoodAbsorptionClassification
    var timeToInitialRiseMinutes: Int?
    var timeToPeakMinutes: Int?
    var delayedRise: Bool
    var highFatPatternLikely: Bool
    var confidence: PersonalLearningConfidence
}

struct PersonalLearningSummary: JSON, Equatable {
    var foodCategory: String
    var restaurantName: String?
    var numberOfPriorMeals: Int
    var averageAiEstimate: Decimal?
    var averageUserConfirmedCarbs: Decimal?
    var averageCorrection: Decimal?
    var mostCommonOutcomeClassification: GlucoseOutcomeClassification?
    var mostSuccessfulBolusTimingRange: BolusTimingRange?
    var typicalAbsorptionClassification: FoodAbsorptionClassification?
    var confidence: PersonalLearningConfidence
}

struct BolusTimingRange: JSON, Equatable {
    var lowerBound: Int
    var upperBound: Int
}

struct PersonalizedAdjustmentSuggestion: JSON, Equatable {
    var advisoryMessages: [String]
    var suggestedCarbAdjustment: Decimal?
    var confidence: PersonalLearningConfidence
    var basedOnRecordCount: Int
}

struct PendingAIMealLearningContext: JSON, Equatable {
    var aiMealDescription: String
    var aiFoodCategory: String
    var aiEstimatedCarbs: Decimal
    var aiHighFatFlag: Bool
    var aiEstimatedAbsorptionType: FoodAbsorptionClassification?
    var restaurantName: String?
    var imageReference: String?
}

struct PersonalLearningGlucoseReading: JSON, Equatable {
    var date: Date
    var glucose: Int
    var trend: String?
}

struct GlucoseOutcomeMetrics: JSON, Equatable {
    var observationStart: Date
    var observationEnd: Date
    var startingGlucose: Int?
    var startingTrend: String?
    var peakGlucose: Int?
    var timeToPeakMinutes: Int?
    var lowestGlucose: Int?
    var timeBelow70Minutes: Int
    var timeBelow80Minutes: Int
    var timeAbove180Minutes: Int
    var timeAbove250Minutes: Int
    var percentTimeInRange: Decimal
    var earlyHypoglycemia: Bool
    var delayedHyperglycemia: Bool
}

enum GlucoseOutcomeClassification: String, Codable, Equatable, Hashable, CaseIterable {
    case inRange = "In range"
    case earlyLow = "Early low"
    case lateHigh = "Late high"
    case earlyLowThenLateHigh = "Early low followed by late high"
    case sustainedHigh = "Sustained high"
    case insufficientData = "Insufficient data"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        switch value {
        case "goodControl",
             Self.inRange.rawValue:
            self = .inRange
        case "likelyCarbOverestimate",
             Self.earlyLow.rawValue:
            self = .earlyLow
        case "delayedAbsorptionHighFatPattern",
             Self.lateHigh.rawValue:
            self = .lateHigh
        case "earlyInsulinMismatch",
             Self.earlyLowThenLateHigh.rawValue:
            self = .earlyLowThenLateHigh
        case "likelyCarbUnderestimate",
             Self.sustainedHigh.rawValue:
            self = .sustainedHigh
        case "insufficientData",
             Self.insufficientData.rawValue:
            self = .insufficientData
        default:
            self = .insufficientData
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum BolusStrategy: String, Codable, Equatable, Hashable, CaseIterable {
    case immediateBolus
    case preBolus
    case delayedBolus
    case superBolus
    case extendedBolus
    case reducedBolus
    case unknown
}

enum FoodAbsorptionClassification: String, Codable, Equatable, Hashable, CaseIterable {
    case fastAbsorption
    case mediumAbsorption
    case slowAbsorption
    case delayedHighFatPattern
    case unclearInsufficientData
}

enum PersonalLearningConfidence: String, Codable, Equatable, Comparable {
    case none
    case low
    case medium
    case high

    static func < (lhs: PersonalLearningConfidence, rhs: PersonalLearningConfidence) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .none: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }
}
