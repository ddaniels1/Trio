import Charts
import CoreData
import LoopKitUI
import Observation
import SwiftUI
import Swinject
import UIKit

extension Treatments {
    struct RootView: BaseView {
        enum FocusedField {
            case carbs
            case fat
            case protein
            case bolus
            case openAIAPIKey
        }

        @FocusState private var focusedField: FocusedField?

        let resolver: Resolver

        @State var state = StateModel()

        @State private var showPresetSheet = false
        @State private var showAIMealCamera = false
        @State private var showAIMealPhotoLibrary = false
        @State private var showHandCalibration = false
        @State private var showOpenAIAPIKeyField = false
        @State private var aiMealEstimatorViewModel = AIMealEstimatorViewModel()
        @State private var autofocus: Bool = true
        @State private var calculatorDetent = PresentationDetent.large
        @State private var pushed: Bool = false
        @State private var debounce: DispatchWorkItem?
        @State private var showFatProteinOrderBanner = false

        private enum Config {
            static let dividerHeight: CGFloat = 2
            static let spacing: CGFloat = 3
        }

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private var formatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumIntegerDigits = 2
            formatter.maximumFractionDigits = 3
            return formatter
        }

        private var bolusProgressFormatter: NumberFormatter {
            let fractionDigits: Int = switch state.settingsManager.preferences.bolusIncrement {
            case 0.1: 1
            case 0.025: 3
            default: 2
            }

            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimum = 0
            formatter.maximumFractionDigits = fractionDigits
            formatter.minimumFractionDigits = fractionDigits
            formatter.allowsFloats = true
            formatter.roundingIncrement = Double(state.settingsManager.preferences.bolusIncrement) as NSNumber
            return formatter
        }

        private var mealFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumIntegerDigits = 3
            formatter.maximumFractionDigits = 0
            return formatter
        }

        private var gluoseFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            if state.units == .mmolL {
                formatter.maximumIntegerDigits = 2
                formatter.maximumFractionDigits = 1
            } else {
                formatter.maximumIntegerDigits = 3
                formatter.maximumFractionDigits = 0
            }
            return formatter
        }

        private var fractionDigits: Int {
            if state.units == .mmolL {
                return 1
            } else { return 0 }
        }

        /// Handles macro input (carb, fat, protein) in a debounced fashion.
        func handleDebouncedInput() {
            debounce?.cancel()
            debounce = DispatchWorkItem { [self] in
                Task {
                    await state.updateForecasts()
                    state.insulinCalculated = await state.calculateInsulin()
                }
            }
            if let debounce = debounce {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: debounce)
            }
        }

        @ViewBuilder private func proteinAndFat() -> some View {
            HStack {
                HStack {
                    Text("Fat")
                    TextFieldWithToolBar(
                        text: $state.fat,
                        placeholder: "0",
                        keyboardType: .numberPad,
                        numberFormatter: mealFormatter,
                        showArrows: true,
                        previousTextField: { focusedField = previousField(from: .fat) },
                        nextTextField: { focusedField = nextField(from: .fat) },
                        unitsText: String(localized: "g", comment: "Units for carbs")
                    )
                    .focused($focusedField, equals: .fat)
                }

                Divider().foregroundStyle(.primary).fontWeight(.bold).frame(width: 10)

                HStack {
                    Text("Protein")
                    TextFieldWithToolBar(
                        text: $state.protein,
                        placeholder: "0",
                        keyboardType: .numberPad,
                        numberFormatter: mealFormatter,
                        showArrows: true,
                        previousTextField: { focusedField = previousField(from: .protein) },
                        nextTextField: { focusedField = nextField(from: .protein) },
                        unitsText: String(localized: "g", comment: "Units for carbs")
                    )
                    .focused($focusedField, equals: .protein)
                }
            }
        }

        @ViewBuilder private func carbsTextField() -> some View {
            HStack {
                Text("Carbs")
                Spacer()
                TextFieldWithToolBar(
                    text: $state.carbs,
                    placeholder: "0",
                    keyboardType: .numberPad,
                    numberFormatter: mealFormatter,
                    showArrows: true,
                    previousTextField: { focusedField = previousField(from: .carbs) },
                    nextTextField: { focusedField = nextField(from: .carbs) },
                    unitsText: String(localized: "g", comment: "Units for carbs")
                )
                .focused($focusedField, equals: .carbs)
                .onChange(of: state.carbs) {
                    handleDebouncedInput()
                }
            }
        }

        private var aiMealEstimatorButton: some View {
            Button {
                aiMealEstimatorViewModel.loadAPIKey()
                aiMealEstimatorViewModel.errorMessage = nil
                guard aiMealEstimatorViewModel.isAPIKeySaved else {
                    focusOpenAIAPIKeyField()
                    aiMealEstimatorViewModel.errorMessage = OpenAIMealEstimatorClient.ClientError.missingAPIKey
                        .localizedDescription
                    return
                }
                #if targetEnvironment(simulator)
                    showAIMealPhotoLibrary = true
                #else
                    if aiMealEstimatorViewModel.handCalibration == nil {
                        showHandCalibration = true
                    } else {
                        showAIMealCamera = true
                    }
                #endif
            } label: {
                if aiMealEstimatorViewModel.isEstimating {
                    HStack {
                        ProgressView()
                        Text("Estimating carbs...")
                    }
                } else {
                    Label("Estimate Carbs from Photo", systemImage: "camera.viewfinder")
                }
            }
            .buttonStyle(.borderless)
            .disabled(
                aiMealEstimatorViewModel.isEstimating || !aiMealImageSourceAvailable || !aiMealEstimatorViewModel.isAPIKeySaved
            )
        }

        @ViewBuilder private var openAIAPIKeyField: some View {
            if showOpenAIAPIKeyField || !aiMealEstimatorViewModel.isAPIKeySaved {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("OpenAI API key", text: $aiMealEstimatorViewModel.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .openAIAPIKey)
                        .padding(8)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(aiMealEstimatorViewModel.isAPIKeySaved ? Color.clear : Color.red, lineWidth: 1.5)
                        }
                        .onSubmit {
                            saveOpenAIAPIKey()
                        }

                    HStack {
                        Text("Saved locally in Keychain.")
                            .font(.caption)
                            .foregroundStyle(aiMealEstimatorViewModel.isAPIKeySaved ? Color.secondary : Color.red)

                        Spacer()

                        Button("Save") {
                            saveOpenAIAPIKey()
                        }
                        .buttonStyle(.borderless)
                        .disabled(!aiMealEstimatorViewModel.hasAPIKey)
                    }
                }
            } else {
                HStack {
                    Label("OpenAI API key saved", systemImage: "key.fill")
                    Spacer()
                    Button("Edit") {
                        showOpenAIAPIKeyField = true
                    }
                    .buttonStyle(.borderless)
                }
            }
        }

        private func saveOpenAIAPIKey() {
            aiMealEstimatorViewModel.saveAPIKey()
            if aiMealEstimatorViewModel.errorMessage == nil {
                showOpenAIAPIKeyField = false
                focusedField = nil
            }
        }

        private func focusOpenAIAPIKeyField() {
            showOpenAIAPIKeyField = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                focusedField = .openAIAPIKey
            }
        }

        private var aiMealImageSourceAvailable: Bool {
            #if targetEnvironment(simulator)
                UIImagePickerController.isSourceTypeAvailable(.photoLibrary)
            #else
                UIImagePickerController.isSourceTypeAvailable(.camera)
            #endif
        }

        private var handCalibrationButton: some View {
            Button {
                aiMealEstimatorViewModel.loadAPIKey()
                aiMealEstimatorViewModel.errorMessage = nil
                guard aiMealEstimatorViewModel.isAPIKeySaved else {
                    focusOpenAIAPIKeyField()
                    aiMealEstimatorViewModel.errorMessage = OpenAIMealEstimatorClient.ClientError.missingAPIKey
                        .localizedDescription
                    return
                }
                showHandCalibration = true
            } label: {
                if let handCalibration = aiMealEstimatorViewModel.handCalibration {
                    Label("Hand scale: \(handCalibration.palmWidthCm, specifier: "%.1f") cm", systemImage: "hand.raised")
                } else {
                    Label("Calibrate Hand Scale", systemImage: "hand.raised")
                }
            }
            .buttonStyle(.borderless)
            .disabled(!aiMealEstimatorViewModel.isAPIKeySaved)
        }

        @ViewBuilder private var aiMealEstimatorResult: some View {
            if let carbEstimate = aiMealEstimatorViewModel.carbEstimate {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI photo estimate")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text("Reference: \(carbEstimate.referenceDetected ? carbEstimate.referenceDescription : "Not detected")")
                    Text("Total carbs: \(carbEstimate.totalCarbsGrams) g")
                        .fontWeight(.semibold)
                    Text(
                        "Carb range: \(carbEstimate.confidenceIntervalGrams.lowerBound)-\(carbEstimate.confidenceIntervalGrams.upperBound) g"
                    )
                    Text("Confidence: \(carbEstimate.confidence)")

                    ForEach(carbEstimate.foodItems) { foodItem in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(foodItem.name)
                                .fontWeight(.semibold)
                            Text("Dimensions: \(foodItem.estimatedDimensions)")
                            Text("Weight: \(foodItem.estimatedWeightGrams) g")
                            Text("Carbs: \(foodItem.carbsGrams) g")
                            Text("High fat: \(foodItem.highFat ? "Yes" : "No")")
                        }
                        .padding(.top, 4)
                    }

                    if !carbEstimate.explanation.isEmpty {
                        Text(carbEstimate.explanation)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
            }

            if let errorMessage = aiMealEstimatorViewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }

        private func estimateCarbsFromCapturedMeal(_ image: UIImage) async {
            aiMealEstimatorViewModel.setSelectedImage(image)
            await aiMealEstimatorViewModel.estimateCarbs()

            guard let carbEstimate = aiMealEstimatorViewModel.carbEstimate else { return }
            state.carbs = Decimal(carbEstimate.totalCarbsGrams)
        }

        /// Determines the next field to focus on based on the current focused field.
        ///
        /// This function handles the tab order navigation between input fields,
        /// taking into account whether fat/protein fields are visible based on user settings.
        ///
        /// - Parameter current: The currently focused field
        /// - Returns: The next field that should receive focus, or nil if there is no next field
        private func nextField(from current: FocusedField) -> FocusedField? {
            // If fat/protein fields are hidden, skip them in navigation
            let showFPU = state.useFPUconversion

            switch current {
            case .fat:
                return .bolus
            case .protein:
                return .fat
            case .carbs:
                return showFPU ? .protein : .bolus
            case .bolus:
                return .carbs
            case .openAIAPIKey:
                return .carbs
            }
        }

        /// Determines the previous field to focus on based on the current focused field.
        ///
        /// This function handles the reverse tab order navigation between input fields,
        /// taking into account whether fat/protein fields are visible based on user settings.
        ///
        /// - Parameter current: The currently focused field
        /// - Returns: The previous field that should receive focus, or nil if there is no previous field
        private func previousField(from current: FocusedField) -> FocusedField? {
            let showFPU = state.useFPUconversion

            switch current {
            case .fat:
                return .protein
            case .protein:
                return .carbs
            case .carbs:
                return .bolus
            case .bolus:
                return showFPU ? .fat : .carbs
            case .openAIAPIKey:
                return nil
            }
        }

        var body: some View {
            ZStack(alignment: .center) {
                VStack {
                    List {
                        Section {
                            ForecastChart(state: state)
                                .padding(.vertical)
                        }.listRowBackground(Color.chart)

                        Section {
                            carbsTextField()
                            openAIAPIKeyField
                            aiMealEstimatorButton
                            handCalibrationButton
                            aiMealEstimatorResult

                            if state.useFPUconversion {
                                proteinAndFat()

                                if showFatProteinOrderBanner {
                                    HStack {
                                        Image(systemName: "arrow.left.arrow.right")
                                        Text("The order of Fat and Protein inputs has changed.").font(.callout)
                                        Spacer()
                                        Button {
                                            PropertyPersistentFlags.shared.hasSeenFatProteinOrderChange = true
                                            withAnimation { showFatProteinOrderBanner = false }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .listRowBackground(Color.orange.opacity(0.75))
                                    .transition(.opacity)
                                }
                            }

                            // Time
                            HStack {
                                // Semi-hacky workaround to make sure the List renders the horizontal divider properly between the `Time` and `Note` rows within the Section
                                HStack {
                                    Text("")
                                    Image(systemName: "clock").padding(.leading, -7)
                                }

                                Spacer()
                                if !pushed {
                                    Button {
                                        pushed = true
                                    } label: { Text("Now") }.buttonStyle(.borderless).foregroundColor(.secondary)
                                        .padding(.trailing, 5)
                                } else {
                                    Button { state.date = state.date.addingTimeInterval(-15.minutes.timeInterval) }
                                    label: { Image(systemName: "minus.circle") }.tint(.blue).buttonStyle(.borderless)

                                    DatePicker(
                                        "Time",
                                        selection: $state.date,
                                        displayedComponents: [.hourAndMinute]
                                    ).controlSize(.mini)
                                        .labelsHidden()
                                        .onChange(of: state.date) { _, _ in
                                            // Trigger simulation when date changes to update forecasts for backdated carbs
                                            Task {
                                                // `updateForecasts()` does update the `simulatedDetermination` of type `Determination?` var on the main thread, so I can use this to pass its cob value into the bolus calc manager
                                                await state.updateForecasts()
                                                state.insulinCalculated = await state.calculateInsulin()
                                            }
                                        }
                                    Button {
                                        state.date = state.date.addingTimeInterval(15.minutes.timeInterval)
                                    }
                                    label: { Image(systemName: "plus.circle") }.tint(.blue).buttonStyle(.borderless)
                                }
                            }

                            // Notes
                            HStack {
                                Image(systemName: "square.and.pencil")
                                TextFieldWithToolBarString(
                                    text: $state.note,
                                    placeholder: String(localized: "Note..."),
                                    maxLength: 25
                                )
                            }
                        }.listRowBackground(Color.chart)

                        Section {
                            if state.fattyMeals || state.sweetMeals {
                                HStack(spacing: 10) {
                                    if state.fattyMeals {
                                        Toggle(isOn: $state.useFattyMealCorrectionFactor) {
                                            Text("Reduced Bolus")
                                        }
                                        .toggleStyle(RadioButtonToggleStyle())
                                        .font(.footnote)
                                        .onChange(of: state.useFattyMealCorrectionFactor) {
                                            Task {
                                                state.insulinCalculated = await state.calculateInsulin()
                                                if state.useFattyMealCorrectionFactor {
                                                    state.useSuperBolus = false
                                                }
                                            }
                                        }
                                    }
                                    if state.sweetMeals {
                                        Toggle(isOn: $state.useSuperBolus) {
                                            Text("Super Bolus")
                                        }
                                        .toggleStyle(RadioButtonToggleStyle())
                                        .font(.footnote)
                                        .onChange(of: state.useSuperBolus) {
                                            Task {
                                                state.insulinCalculated = await state.calculateInsulin()
                                                if state.useSuperBolus {
                                                    state.useFattyMealCorrectionFactor = false
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            HStack {
                                HStack {
                                    Text("Recommendation")
                                    Button(action: {
                                        state.showInfo.toggle()
                                    }, label: {
                                        Image(systemName: "info.circle")
                                    })
                                        .foregroundStyle(.blue)
                                        .buttonStyle(PlainButtonStyle())
                                }
                                Spacer()
                                Button {
                                    state.amount = state.insulinCalculated
                                } label: {
                                    HStack {
                                        Text(
                                            formatter
                                                .string(from: Double(state.insulinCalculated) as NSNumber) ?? ""
                                        )

                                        Text(
                                            String(
                                                localized:
                                                " U",
                                                comment: "Unit in number of units delivered (keep the space character!)"
                                            )
                                        ).foregroundColor(.secondary)
                                    }
                                }
                                .disabled(state.insulinCalculated == 0 || state.amount == state.insulinCalculated)
                                .buttonStyle(.bordered).padding(.trailing, -10)
                            }

                            HStack {
                                Text("Bolus")
                                Spacer()
                                TextFieldWithToolBar(
                                    text: $state.amount,
                                    placeholder: "0",
                                    textColor: colorScheme == .dark ? .white : .blue,
                                    maxLength: 5,
                                    numberFormatter: formatter,
                                    showArrows: true,
                                    previousTextField: { focusedField = previousField(from: .bolus) },
                                    nextTextField: { focusedField = nextField(from: .bolus) },
                                    unitsText: String(localized: "U", comment: "Units for bolus amount")
                                ).focused($focusedField, equals: .bolus)
                                    .onChange(of: state.amount) {
                                        Task {
                                            await state.updateForecasts()
                                        }
                                    }
                            }

                            HStack {
                                Text("External Insulin")
                                Spacer()
                                Toggle("", isOn: $state.externalInsulin).toggleStyle(CheckboxToggleStyle())
                            }
                        }.listRowBackground(Color.chart)

                        treatmentButton
                    }
                    .listSectionSpacing(sectionSpacing)
                }
                .blur(radius: state.isAwaitingDeterminationResult ? 5 : 0)

                if state.isAwaitingDeterminationResult {
                    CustomProgressView(text: progressText.displayName)
                }
            }
            .padding(.top)
            .ignoresSafeArea(edges: .top)
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .blur(radius: state.showInfo ? 3 : 0)
            .navigationTitle("Treatments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        state.hideModal()
                    } label: {
                        Text("Close")
                    }
                }
                if state.displayPresets {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            showPresetSheet = true
                        }, label: {
                            HStack {
                                Text("Presets")
                                Image(systemName: "plus")
                            }
                        })
                    }
                }
            })
            .onAppear {
                configureView {
                    state.isActive = true
                    Task { @MainActor in
                        state.insulinCalculated = await state.calculateInsulin()
                    }

                    aiMealEstimatorViewModel.loadAPIKey()
                    if !aiMealEstimatorViewModel.isAPIKeySaved {
                        focusOpenAIAPIKeyField()
                    }

                    if PropertyPersistentFlags.shared.hasSeenFatProteinOrderChange != true {
                        showFatProteinOrderBanner = true
                    }
                }
            }
            .onDisappear {
                state.isActive = false
                state.addButtonPressed = false

                // Cancel all Combine subscriptions and unregister State from broadcaster
                state.cleanupTreatmentState()
            }
            .sheet(isPresented: $state.showInfo) {
                PopupView(state: state)
            }
            .sheet(isPresented: $showPresetSheet, onDismiss: {
                showPresetSheet = false
            }) {
                MealPresetView(state: state)
            }
            .sheet(isPresented: $showAIMealCamera) {
                AIMealCameraPicker(onPhotoLibraryRequested: {
                    showAIMealCamera = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showAIMealPhotoLibrary = true
                    }
                }) { image in
                    Task {
                        await estimateCarbsFromCapturedMeal(image)
                    }
                }
            }
            .sheet(isPresented: $showAIMealPhotoLibrary) {
                AIMealCameraPicker(sourceType: .photoLibrary) { image in
                    Task {
                        await estimateCarbsFromCapturedMeal(image)
                    }
                }
            }
            .sheet(isPresented: $showHandCalibration) {
                HandCalibrationView(
                    existingCalibration: aiMealEstimatorViewModel.handCalibration,
                    apiKey: aiMealEstimatorViewModel.apiKey
                ) { calibration in
                    aiMealEstimatorViewModel.saveHandCalibration(calibration)
                    showHandCalibration = false
                    showAIMealCamera = true
                }
            }
            .alert("Error while processing Treatment", isPresented: $state.showDeterminationFailureAlert) {
                Button("OK", role: .cancel) {
                    state.hideModal()
                }
            } message: {
                Text("\(state.determinationFailureMessage)")
            }
        }

        var progressText: ProgressText {
            switch (state.amount > 0, state.carbs > 0) {
            case (true, true):
                return .updatingIOBandCOB
            case (false, true):
                return .updatingCOB
            case (true, false):
                return .updatingIOB
            default:
                return .updatingTreatments
            }
        }

        @State private var showConfirmDialogForBolusing = false

        private var bolusWarning: (shouldConfirm: Bool, warningMessage: String, color: Color) {
            let isGlucoseVeryLow = state.currentBG < 54
            let isForecastVeryLow = state.minPredBG < 54

            // Only warn when enacting a bolus via pump
            guard !state.externalInsulin, state.amount > 0 else {
                return (false, "", .primary)
            }

            let warningMessage = isGlucoseVeryLow ? String(localized: "Glucose is very low.") :
                isForecastVeryLow ? String(localized: "Glucose forecast is very low.") :
                ""

            let warningColor: Color = isGlucoseVeryLow ? .red : colorScheme == .dark ? .orange : .accentColor

            let shouldConfirm = state.confirmBolus && (isGlucoseVeryLow || isForecastVeryLow)

            return (shouldConfirm, warningMessage, warningColor)
        }

        var treatmentButton: some View {
            let shouldDisplayBolusProgress = state.isBolusInProgress && state.amount > 0 &&
                !state.externalInsulin && (state.carbs == 0 || state.fat == 0 || state.protein == 0)

            var treatmentButtonBackground = Color(.systemBlue)
            if limitExceeded {
                treatmentButtonBackground = Color(.systemRed)
            } else if disableTaskButton {
                treatmentButtonBackground = Color(.systemGray)
            }

            return Section {
                if shouldDisplayBolusProgress {
                    bolusInProgressView
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                } else {
                    Button {
                        if bolusWarning.shouldConfirm {
                            showConfirmDialogForBolusing = true
                        } else {
                            state.invokeTreatmentsTask()
                        }
                    } label: {
                        HStack {
                            taskButtonLabel
                        }
                        .font(.headline)
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 35)
                    }
                    .disabled(disableTaskButton)
                    .listRowBackground(treatmentButtonBackground)
                    .shadow(radius: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .confirmationDialog(
                        bolusWarning.warningMessage + " Bolus \(state.amount.description) U?",
                        isPresented: $showConfirmDialogForBolusing,
                        titleVisibility: .visible
                    ) {
                        Button("Cancel", role: .cancel) {}
                        Button(
                            bolusWarning.warningMessage
                                .isEmpty ? String(localized: "Enact Bolus") : String(localized: "Ignore Warning and Enact Bolus"),
                            role: bolusWarning.warningMessage.isEmpty ? nil : .destructive
                        ) {
                            state.invokeTreatmentsTask()
                        }
                    }
                }
            } header: {
                if !bolusWarning.warningMessage.isEmpty {
                    Text(bolusWarning.warningMessage)
                        .textCase(nil)
                        .font(.subheadline)
                        .foregroundColor(bolusWarning.color)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, -22)
                }
            }
        }

        /// Card-style in-progress visualizer matching Home's `bolusView` look:
        /// insulin-tinted background, cross.vial.fill icon, "Bolusing" + "X of Y U" text,
        /// xmark.app cancel, gradient progress bar overlaid at the bottom.
        @ViewBuilder private var bolusInProgressView: some View {
            let progress = state.bolusProgress ?? 0
            let bolusTotal = state.lastPumpBolus?.bolus?.amount as Decimal?
            let bolusFraction = (bolusTotal ?? 0) * progress
            let bolusString: String = {
                guard let bolusTotal = bolusTotal else { return String(localized: "Bolus In Progress...") }
                return (bolusProgressFormatter.string(from: bolusFraction as NSNumber) ?? "0")
                    + String(localized: " of ", comment: "Bolus string partial message: 'x U of y U' in home view")
                    + (Formatter.decimalFormatterWithThreeFractionDigits.string(from: bolusTotal as NSNumber) ?? "0")
                    + String(localized: " U", comment: "Insulin unit")
            }()

            ZStack {
                // background card
                RoundedRectangle(cornerRadius: 15)
                    .fill(
                        colorScheme == .dark
                            ? Color(red: 0.03921568627, green: 0.133333333, blue: 0.2156862745)
                            : Color.insulin.opacity(0.2)
                    )
                    .frame(height: 56)
                    .shadow(
                        color: colorScheme == .dark
                            ? Color(red: 0.02745098039, green: 0.1098039216, blue: 0.1411764706)
                            : Color.black.opacity(0.33),
                        radius: 3
                    )

                // bolus content
                HStack {
                    Image(systemName: "cross.vial.fill")
                        .font(.system(size: 25))

                    Spacer()

                    VStack {
                        Text("Bolusing")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(bolusString)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 5)

                    Spacer()

                    Button { state.cancelBolus() } label: {
                        Image(systemName: "xmark.app")
                            .font(.system(size: 25))
                    }.tint(Color.tabBar)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Cancel bolus")
                }
                .padding(.horizontal, 10)
                .padding(.trailing, 8)
            }
            .padding(.horizontal, 10)
            .overlay(alignment: .bottom) {
                BolusProgressBar(progress: progress)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15))
        }

        private var taskButtonLabel: some View {
            if pumpBolusLimitExceeded {
                return Text("Max Bolus of \(state.maxBolus.description) U Exceeded")
            } else if externalBolusLimitExceeded {
                return Text("Max External Bolus of \(state.maxExternal.description) U Exceeded")
            } else if carbLimitExceeded {
                return Text("Max Carbs of \(state.maxCarbs.description) g Exceeded")
            } else if fatLimitExceeded {
                return Text("Max Fat of \(state.maxFat.description) g Exceeded")
            } else if proteinLimitExceeded {
                return Text("Max Protein of \(state.maxProtein.description) g Exceeded")
            }

            let hasInsulin = state.amount > 0
            let hasCarbs = state.carbs > 0
            let hasFatOrProtein = state.fat > 0 || state.protein > 0
            let bolusString = state.externalInsulin ? String(localized: "External Insulin") : String(localized: "Enact Bolus")

            // Note: when a pump bolus is in progress, the row is rendered by `bolusInProgressView`
            // (Home-style card), so this label's in-progress branch is intentionally absent.

            switch (hasInsulin, hasCarbs, hasFatOrProtein) {
            case (true, true, true):
                return Text("Log Meal and \(bolusString)")
            case (true, true, false):
                return Text("Log Carbs and \(bolusString)")
            case (true, false, true):
                return Text("Log FPU and \(bolusString)")
            case (true, false, false):
                return Text(state.externalInsulin ? String(localized: "Log External Insulin") : String(localized: "Enact Bolus"))
            case (false, true, true):
                return Text("Log Meal")
            case (false, true, false):
                return Text("Log Carbs")
            case (false, false, true):
                return Text("Log FPU")
            default:
                return Text("Continue Without Treatment")
            }
        }

        private var pumpBolusLimitExceeded: Bool {
            !state.externalInsulin && state.amount > state.maxBolus
        }

        private var externalBolusLimitExceeded: Bool {
            state.externalInsulin && state.amount > state.maxExternal
        }

        private var carbLimitExceeded: Bool {
            state.carbs > state.maxCarbs
        }

        private var fatLimitExceeded: Bool {
            state.fat > state.maxFat
        }

        private var proteinLimitExceeded: Bool {
            state.protein > state.maxProtein
        }

        private var limitExceeded: Bool {
            pumpBolusLimitExceeded || externalBolusLimitExceeded || carbLimitExceeded || fatLimitExceeded || proteinLimitExceeded
        }

        private var disableTaskButton: Bool {
            (
                state.isBolusInProgress && state
                    .amount > 0 && !state.externalInsulin && (state.carbs == 0 || state.fat == 0 || state.protein == 0)
            ) || state
                .addButtonPressed || limitExceeded
        }
    }

    struct DividerDouble: View {
        var body: some View {
            VStack(spacing: 2) {
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(.gray.opacity(0.65))
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(.gray.opacity(0.65))
            }
            .frame(height: 4)
            .padding(.vertical)
        }
    }

    struct DividerCustom: View {
        var body: some View {
            Rectangle()
                .frame(height: 1)
                .foregroundColor(.gray.opacity(0.65))
                .padding(.vertical)
        }
    }
}

@Observable
@MainActor final class AIMealEstimatorViewModel {
    private enum Config {
        static let openAIAPIKeyKey = "AIMealEstimator.openAIAPIKey"
        static let hardcodedOpenAIAPIKey = ""
    }

    private let keychain: Keychain = BaseKeychain()
    private let estimatorClient = OpenAIMealEstimatorClient()

    var selectedImage: UIImage?
    var apiKey = ""
    var carbEstimate: AIMealCarbEstimate?
    var handCalibration = HandCalibrationStore.load()
    var isAPIKeySaved = false
    var isEstimating = false
    var errorMessage: String?

    var canEstimate: Bool {
        selectedImage != nil && isAPIKeySaved && !isEstimating
    }

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func loadAPIKey() {
        let hardcodedAPIKey = Config.hardcodedOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if hardcodedAPIKey.isEmpty {
            apiKey = keychain.getValue(String.self, forKey: Config.openAIAPIKeyKey) ?? ""
        } else {
            apiKey = hardcodedAPIKey
        }
        isAPIKeySaved = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveAPIKey() {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else {
            errorMessage = OpenAIMealEstimatorClient.ClientError.missingAPIKey.localizedDescription
            return
        }

        guard Config.hardcodedOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            apiKey = Config.hardcodedOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            isAPIKeySaved = true
            errorMessage = nil
            return
        }

        keychain.setValue(trimmedAPIKey, forKey: Config.openAIAPIKeyKey)
        apiKey = trimmedAPIKey
        isAPIKeySaved = true
        errorMessage = nil
    }

    func setSelectedImage(_ image: UIImage) {
        selectedImage = image
        carbEstimate = nil
        errorMessage = nil
    }

    func saveHandCalibration(_ calibration: HandCalibration) {
        HandCalibrationStore.save(calibration)
        handCalibration = calibration
    }

    func estimateCarbs() async {
        guard let selectedImage else { return }

        isEstimating = true
        errorMessage = nil
        carbEstimate = nil

        do {
            let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAPIKey.isEmpty else {
                throw OpenAIMealEstimatorClient.ClientError.missingAPIKey
            }

            if Config.hardcodedOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                keychain.setValue(trimmedAPIKey, forKey: Config.openAIAPIKeyKey)
            }

            carbEstimate = try await estimatorClient.estimateCarbs(
                from: selectedImage,
                calibration: handCalibration,
                apiKey: trimmedAPIKey
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isEstimating = false
    }
}

struct HandCalibration: Codable {
    let palmWidthCm: Double
    let calibratedAt: Date
    let calibratedWithCreditCard: Bool
}

enum HandCalibrationStore {
    private static let key = "AIMealEstimator.handCalibration"

    static func load() -> HandCalibration? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HandCalibration.self, from: data)
    }

    static func save(_ calibration: HandCalibration) {
        guard let data = try? JSONEncoder().encode(calibration) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct HandCalibrationView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var palmWidthText = ""
    @State private var showCamera = false
    @State private var capturedReferenceImage: UIImage?
    @State private var isEstimating = false
    @State private var confidence = ""
    @State private var explanation = ""
    @State private var errorMessage: String?

    let existingCalibration: HandCalibration?
    let apiKey: String
    let onSave: (HandCalibration) -> Void

    private let estimatorClient = OpenAIMealEstimatorClient()

    private var palmWidthCm: Double? {
        let normalizedText = palmWidthText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalizedText), value > 0 else { return nil }
        return value
    }

    private var handCalibrationImageSourceType: UIImagePickerController.SourceType {
        #if targetEnvironment(simulator)
            .photoLibrary
        #else
                .camera
        #endif
    }

    private var handCalibrationImageSourceAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(handCalibrationImageSourceType)
    }

    private var handCalibrationImageButtonTitle: LocalizedStringKey {
        #if targetEnvironment(simulator)
            "Choose Hand Photo with Credit Card"
        #else
            "Capture Hand with Credit Card"
        #endif
    }

    private var handCalibrationImageButtonIcon: String {
        #if targetEnvironment(simulator)
            "photo.on.rectangle"
        #else
            "camera"
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if existingCalibration == nil {
                        Button {
                            showCamera = true
                        } label: {
                            Label(handCalibrationImageButtonTitle, systemImage: handCalibrationImageButtonIcon)
                        }
                        .disabled(isEstimating || !handCalibrationImageSourceAvailable)
                    }

                    if let capturedReferenceImage {
                        Image(uiImage: capturedReferenceImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                    }

                    if isEstimating {
                        HStack {
                            ProgressView()
                            Text("Estimating palm width...")
                        }
                    }

                    if let palmWidthCm {
                        Text("Palm width: \(palmWidthCm, specifier: "%.1f") cm")
                    }

                    if !confidence.isEmpty {
                        Text("Confidence: \(confidence)")
                    }

                    if !explanation.isEmpty {
                        Text(explanation)
                            .foregroundStyle(.secondary)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Hand Scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let palmWidthCm else { return }
                        onSave(
                            HandCalibration(
                                palmWidthCm: palmWidthCm,
                                calibratedAt: Date(),
                                calibratedWithCreditCard: capturedReferenceImage != nil
                            )
                        )
                    }
                    .disabled(palmWidthCm == nil || isEstimating)
                }
            }
            .sheet(isPresented: $showCamera) {
                AIMealCameraPicker(sourceType: handCalibrationImageSourceType) { image in
                    capturedReferenceImage = image
                    Task {
                        await estimatePalmWidth(from: image)
                    }
                }
            }
            .onAppear {
                if let calibration = existingCalibration ?? HandCalibrationStore.load() {
                    palmWidthText = String(format: "%.1f", calibration.palmWidthCm)
                }
            }
        }
    }

    private func estimatePalmWidth(from image: UIImage) async {
        isEstimating = true
        errorMessage = nil
        confidence = ""
        explanation = ""

        do {
            let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAPIKey.isEmpty else {
                throw OpenAIMealEstimatorClient.ClientError.missingAPIKey
            }

            let estimate = try await estimatorClient.estimatePalmWidth(from: image, apiKey: trimmedAPIKey)
            palmWidthText = String(format: "%.1f", estimate.palmWidthCm)
            confidence = estimate.confidence
            explanation = estimate.explanation
        } catch {
            errorMessage = error.localizedDescription
        }

        isEstimating = false
    }
}

struct HandCalibrationEstimate: Decodable {
    let palmWidthCm: Double
    let confidence: String
    let explanation: String

    enum CodingKeys: String, CodingKey {
        case palmWidthCm = "palm_width_cm"
        case confidence
        case explanation
    }
}

struct AIMealCarbEstimate: Decodable {
    struct FoodItem: Decodable, Identifiable {
        let name: String
        let estimatedDimensions: String
        let estimatedWeightGrams: Int
        let carbsGrams: Int
        let highFat: Bool

        var id: String {
            "\(name)-\(estimatedDimensions)-\(estimatedWeightGrams)-\(carbsGrams)"
        }

        enum CodingKeys: String, CodingKey {
            case name
            case estimatedDimensions = "estimated_dimensions"
            case estimatedWeightGrams = "estimated_weight_grams"
            case carbsGrams = "carbs_grams"
            case highFat = "high_fat"
        }
    }

    struct ConfidenceIntervalGrams: Decodable {
        let lowerBound: Int
        let upperBound: Int

        enum CodingKeys: String, CodingKey {
            case lowerBound = "lower_bound"
            case upperBound = "upper_bound"
        }
    }

    let referenceDetected: Bool
    let referenceDescription: String
    let foodItems: [FoodItem]
    let totalCarbsGrams: Int
    let confidenceIntervalGrams: ConfidenceIntervalGrams
    let confidence: String
    let explanation: String

    enum CodingKeys: String, CodingKey {
        case referenceDetected = "reference_detected"
        case referenceDescription = "reference_description"
        case foodItems = "food_items"
        case totalCarbsGrams = "total_carbs_grams"
        case confidenceIntervalGrams = "confidence_interval_grams"
        case confidence
        case explanation
    }
}

struct OpenAIMealEstimatorClient {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case invalidImage
        case invalidResponse
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add an OpenAI API key before estimating carbs from a photo."
            case .invalidImage:
                return "Unable to prepare the selected image."
            case .invalidResponse:
                return "OpenAI did not return a carb estimate."
            case let .requestFailed(message):
                return message
            }
        }
    }

    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private let model = "gpt-5"

    func estimateCarbs(from image: UIImage, calibration: HandCalibration?, apiKey: String) async throws -> AIMealCarbEstimate {
        guard let imageData = image.jpegData(compressionQuality: 0.93) else {
            throw ClientError.invalidImage
        }

        let base64Image = imageData.base64EncodedString()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(
                base64Image: base64Image,
                prompt: mealPrompt(calibration: calibration),
                schemaName: "meal_carb_estimate",
                responseSchema: mealResponseSchema,
                imageDetail: "high",
                reasoningEffort: "low",
                maxOutputTokens: 2000
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw ClientError
                .requestFailed(Self.errorMessage(from: data) ?? "OpenAI request failed with status \(httpResponse.statusCode).")
        }

        let responseBody = try JSONDecoder().decode(OpenAIResponsesBody.self, from: data)
        guard let outputText = responseBody.outputText,
              let estimateData = outputText.data(using: .utf8)
        else {
            throw ClientError.requestFailed(responseBody.failureMessage ?? ClientError.invalidResponse.localizedDescription)
        }

        do {
            return try JSONDecoder().decode(AIMealCarbEstimate.self, from: estimateData)
        } catch {
            throw ClientError.requestFailed("OpenAI returned an estimate, but it did not match the expected carb JSON format.")
        }
    }

    func estimatePalmWidth(from image: UIImage, apiKey: String) async throws -> HandCalibrationEstimate {
        guard let imageData = image.jpegData(compressionQuality: 0.72) else {
            throw ClientError.invalidImage
        }

        let base64Image = imageData.base64EncodedString()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(
                base64Image: base64Image,
                prompt: palmCalibrationPrompt,
                schemaName: "hand_palm_width_calibration",
                responseSchema: palmCalibrationResponseSchema,
                imageDetail: "low",
                reasoningEffort: nil,
                maxOutputTokens: 220
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw ClientError
                .requestFailed(Self.errorMessage(from: data) ?? "OpenAI request failed with status \(httpResponse.statusCode).")
        }

        let responseBody = try JSONDecoder().decode(OpenAIResponsesBody.self, from: data)
        guard let outputText = responseBody.outputText,
              let estimateData = outputText.data(using: .utf8)
        else {
            throw ClientError.requestFailed(responseBody.failureMessage ?? ClientError.invalidResponse.localizedDescription)
        }

        do {
            return try JSONDecoder().decode(HandCalibrationEstimate.self, from: estimateData)
        } catch {
            throw ClientError
                .requestFailed("OpenAI returned a calibration result, but it did not match the expected JSON format.")
        }
    }

    private func requestBody(
        base64Image: String,
        prompt: String,
        schemaName: String,
        responseSchema: [String: Any],
        imageDetail: String,
        reasoningEffort: String?,
        maxOutputTokens: Int
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "input": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": prompt
                        ],
                        [
                            "type": "input_image",
                            "image_url": "data:image/jpeg;base64,\(base64Image)",
                            "detail": imageDetail
                        ]
                    ]
                ]
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": schemaName,
                    "strict": true,
                    "schema": responseSchema
                ]
            ],
            "max_output_tokens": maxOutputTokens
        ]

        if let reasoningEffort {
            body["reasoning"] = [
                "effort": reasoningEffort
            ]
        }

        return body
    }

    private func mealPrompt(calibration: HandCalibration?) -> String {
        let calibrationText: String
        if let calibration {
            calibrationText = """
            The user has calibrated their hand scale. Their palm width is \(calibration
                .palmWidthCm) cm. Use any visible hand in the meal photo as a scale reference for estimating food size and weight.
            """
        } else {
            calibrationText = """
            The user has not calibrated their hand scale. Estimate visually without hand scale calibration and lower confidence if size is uncertain.
            """
        }

        return """
        Estimate carbohydrates from the visible meal photo for user confirmation only. Do not provide insulin dosing advice. \(calibrationText)
        Return strict structured JSON only. First identify every visible food item. Do not collapse distinct foods into one item unless they are visually inseparable.
        Detect whether any usable scale reference is visible, including the user's hand based on previous credit-card calibration. Set reference_detected to true only when a visible reference can be used for scale, and describe it in reference_description.
        For every item, estimate physical dimensions before weight. Then estimate weight. Then estimate carbs for that item.
        Sum the per-item carbs into total_carbs_grams. Include a required confidence_interval_grams lower_bound and upper_bound for total carbs.
        If no usable hand or scale reference is visible, set reference_detected to false, confidence to low, use a wider confidence interval, and explain that retaking the photo with their hand visible will improve the estimate.
        Estimate each value conservatively from the image. high_fat should be true when the visible meal appears likely high in fat.
        """
    }

    private var palmCalibrationPrompt: String {
        """
        Estimate the user's palm width in centimeters from this calibration photo. Use the visible credit card as the scale reference. A standard credit card is 8.56 cm wide and 5.398 cm tall. Measure palm width across the widest visible part of the palm, excluding the thumb. Return structured JSON only. If either the hand or the credit card is not visible, set confidence to low and explain what needs to be retaken.
        """
    }

    private var mealResponseSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "reference_detected": [
                    "type": "boolean",
                    "description": "Whether a usable visual scale reference, preferably the user's hand, is visible in the photo."
                ],
                "reference_description": [
                    "type": "string",
                    "description": "Description of the detected scale reference, or a short note that no usable reference was detected."
                ],
                "food_items": [
                    "type": "array",
                    "description": "Every visible food item with dimensions, weight, carbs, and high-fat flag.",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "name": [
                                "type": "string",
                                "description": "Short user-facing name of this visible food item."
                            ],
                            "estimated_dimensions": [
                                "type": "string",
                                "description": "Estimated physical dimensions or portion size of this item."
                            ],
                            "estimated_weight_grams": [
                                "type": "integer",
                                "description": "Estimated weight of this item in grams."
                            ],
                            "carbs_grams": [
                                "type": "integer",
                                "description": "Estimated carbohydrates for this item in grams."
                            ],
                            "high_fat": [
                                "type": "boolean",
                                "description": "Whether this item appears high in fat."
                            ]
                        ],
                        "required": [
                            "name",
                            "estimated_dimensions",
                            "estimated_weight_grams",
                            "carbs_grams",
                            "high_fat"
                        ]
                    ]
                ],
                "total_carbs_grams": [
                    "type": "integer",
                    "description": "Sum of carbs_grams across every food item."
                ],
                "confidence_interval_grams": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "lower_bound": [
                            "type": "integer",
                            "description": "Lower bound of the estimated total carbohydrates in grams."
                        ],
                        "upper_bound": [
                            "type": "integer",
                            "description": "Upper bound of the estimated total carbohydrates in grams."
                        ]
                    ],
                    "required": [
                        "lower_bound",
                        "upper_bound"
                    ]
                ],
                "confidence": [
                    "type": "string",
                    "enum": ["low", "medium", "high"],
                    "description": "Confidence in the carb estimate."
                ],
                "explanation": [
                    "type": "string",
                    "description": "Short user-facing explanation, including retake guidance when no hand is visible."
                ]
            ],
            "required": [
                "reference_detected",
                "reference_description",
                "food_items",
                "total_carbs_grams",
                "confidence_interval_grams",
                "confidence",
                "explanation"
            ]
        ]
    }

    private var palmCalibrationResponseSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "palm_width_cm": [
                    "type": "number",
                    "description": "Estimated palm width in centimeters, using the credit card dimensions as scale."
                ],
                "confidence": [
                    "type": "string",
                    "enum": ["low", "medium", "high"],
                    "description": "Confidence in the palm width estimate."
                ],
                "explanation": [
                    "type": "string",
                    "description": "Short explanation of the estimate or retake guidance."
                ]
            ],
            "required": [
                "palm_width_cm",
                "confidence",
                "explanation"
            ]
        ]
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(OpenAIErrorBody.self, from: data) else {
            return nil
        }

        return body.error.message
    }
}

private struct OpenAIResponsesBody: Decodable {
    struct IncompleteDetails: Decodable {
        let reason: String?
    }

    struct Output: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
        }

        let content: [Content]?
    }

    let status: String?
    let incompleteDetails: IncompleteDetails?
    let output: [Output]

    enum CodingKeys: String, CodingKey {
        case status
        case incompleteDetails = "incomplete_details"
        case output
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        incompleteDetails = try container.decodeIfPresent(IncompleteDetails.self, forKey: .incompleteDetails)
        output = try container.decodeIfPresent([Output].self, forKey: .output) ?? []
    }

    var outputText: String? {
        for outputItem in output {
            guard let content = outputItem.content else { continue }

            for item in content where item.type == "output_text" || item.type == "text" {
                return item.text
            }
        }

        return nil
    }

    var failureMessage: String? {
        if status == "incomplete" {
            if let reason = incompleteDetails?.reason {
                return "OpenAI response was incomplete: \(reason)."
            }
            return "OpenAI response was incomplete."
        }

        if let status, status != "completed" {
            return "OpenAI response status was \(status)."
        }

        return nil
    }
}

private struct OpenAIErrorBody: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}

private final class AIMealCameraOverlayView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        return hitView === self ? nil : hitView
    }
}

struct AIMealCameraPicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onPhotoLibraryRequested: (() -> Void)?
    let onImageSelected: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        sourceType: UIImagePickerController.SourceType = .camera,
        onPhotoLibraryRequested: (() -> Void)? = nil,
        onImageSelected: @escaping (UIImage) -> Void
    ) {
        self.sourceType = sourceType
        self.onPhotoLibraryRequested = onPhotoLibraryRequested
        self.onImageSelected = onImageSelected
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator

        if sourceType == .camera, onPhotoLibraryRequested != nil {
            picker.showsCameraControls = true
            picker.cameraOverlayView = context.coordinator.makePhotoLibraryOverlay()
        }

        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onImageSelected: onImageSelected,
            onPhotoLibraryRequested: onPhotoLibraryRequested,
            dismiss: dismiss
        )
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onImageSelected: (UIImage) -> Void
        private let onPhotoLibraryRequested: (() -> Void)?
        private let dismiss: DismissAction

        init(
            onImageSelected: @escaping (UIImage) -> Void,
            onPhotoLibraryRequested: (() -> Void)?,
            dismiss: DismissAction
        ) {
            self.onImageSelected = onImageSelected
            self.onPhotoLibraryRequested = onPhotoLibraryRequested
            self.dismiss = dismiss
        }

        func makePhotoLibraryOverlay() -> UIView {
            let overlay = AIMealCameraOverlayView(frame: UIScreen.main.bounds)
            overlay.backgroundColor = .clear
            overlay.isUserInteractionEnabled = true

            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.filled()
            configuration.title = String(localized: "Photo Library")
            configuration.image = UIImage(systemName: "photo.on.rectangle")
            configuration.imagePadding = 6
            configuration.baseForegroundColor = .white
            configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
            button.configuration = configuration
            button.tintColor = .white
            button.layer.cornerRadius = 8
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOpacity = 0.35
            button.layer.shadowRadius = 6
            button.layer.shadowOffset = CGSize(width: 0, height: 2)
            button.addTarget(self, action: #selector(openPhotoLibrary), for: .touchUpInside)
            button.frame = CGRect(x: 16, y: 52, width: 180, height: 48)
            button.autoresizingMask = [.flexibleRightMargin, .flexibleBottomMargin]
            overlay.addSubview(button)

            return overlay
        }

        @objc private func openPhotoLibrary() {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [onPhotoLibraryRequested] in
                onPhotoLibraryRequested?()
            }
        }

        func imagePickerController(
            _: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImageSelected(image)
            }

            dismiss()
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            dismiss()
        }
    }
}
