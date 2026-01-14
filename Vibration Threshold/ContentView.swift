import SwiftUI
import CoreHaptics
import Combine

// MARK: - Model

enum HapticCondition: String, CaseIterable, Codable {
    case leftPalm = "Left Palm"
    case rightPalm = "Right Palm"
    case leftBack = "Left Back of Hand"
    case rightBack = "Right Back of Hand"
}

struct ThresholdResult: Identifiable, Codable {
    let id = UUID()
    let participant: String
    let condition: HapticCondition
    let repetitionIndex: Int   // 1...3
    let globalTrialIndex: Int  // 1...12 for each participant
    let time: TimeInterval
    let intensity: Double
    let timestamp: Date
}

// MARK: - Root: Pseudonym Screen -> Test Screen

struct ContentView: View {
    @State private var participantID: String = ""
    @State private var hasStarted = false
    
    var body: some View {
        if hasStarted {
            TestView(
                participantID: participantID,
                onFinish: {
                    participantID = ""
                    hasStarted = false
                }
            )
        } else {
            PseudonymEntryView(
                participantID: $participantID,
                onStart: { hasStarted = true }
            )
        }
    }
}

// MARK: - Pseudonym Entry Screen

struct PseudonymEntryView: View {
    @Binding var participantID: String
    var onStart: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            Text("Vibration Threshold Study")
                .font(.title)
                .padding(.top, 40)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter participant pseudonym")
                    .font(.headline)
                TextField("e.g. P01, blue_fox, etc.", text: $participantID)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding(.horizontal)
            
            Text("This pseudonym will be used to label all test results for this participant.")
                .font(.footnote)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button(action: onStart) {
                Text("Proceed to Test")
                    .font(.title2)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(participantID.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding(.horizontal, 40)
            .disabled(participantID.trimmingCharacters(in: .whitespaces).isEmpty)
            
            Spacer()
        }
    }
}

// MARK: - Test Screen (minimal UI)

struct TestView: View {
    let participantID: String
    let onFinish: () -> Void
    @StateObject private var hapticManager = HapticManager()
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            Text(hapticManager.currentCondition?.rawValue ?? "All trials completed")
                .font(.system(size: 36, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Text(trialsRemainingText)
                .font(.headline)
                .foregroundColor(.gray)
            
            Spacer()
            
            VStack(spacing: 20) {
                if hapticManager.currentCondition == nil {
                    Text("No more trials for this participant.")
                        .foregroundColor(.gray)
                        .padding(.bottom, 10)
                    
                    Button(action: {
                        hapticManager.exportResultsForParticipant(participantID)
                        onFinish()
                    }) {
                        Text("Finish & Export")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(16)
                    }
                    .padding(.horizontal, 40)
                    
                } else if hapticManager.isRunning {
                    Button(action: {
                        hapticManager.stopAndRecord(participant: participantID)
                    }) {
                        Text("FELT IT")
                            .font(.system(size: 28, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(16)
                    }
                    .padding(.horizontal, 40)
                    
                } else {
                    Button(action: {
                        hapticManager.startCurrentTrial(participant: participantID)
                    }) {
                        Text("START")
                            .font(.system(size: 28, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(hapticManager.currentCondition == nil ? Color.gray : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(16)
                    }
                    .padding(.horizontal, 40)
                    .disabled(hapticManager.currentCondition == nil)
                }
                
                // Show retry only after at least one trial for this participant
                if hapticManager.hasAnyResult(for: participantID) {
                    Button(action: {
                        hapticManager.retryPreviousTrial(participant: participantID)
                    }) {
                        Text("Retry previous trial")
                            .font(.body)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.gray.opacity(0.15))
                            .foregroundColor(.black)
                            .cornerRadius(10)
                    }
                    .padding(.horizontal, 40)
                    .disabled(!hapticManager.canRetryPreviousTrial(participant: participantID) || hapticManager.isRunning)
                }
            }
            
            Spacer()
        }
        .onAppear {
            hapticManager.prepareSequenceIfNeeded(for: participantID)
        }
    }
    
    private var trialsRemainingText: String {
        let completed = hapticManager.results.filter { $0.participant == participantID }.count
        let remaining = max(hapticManager.totalTrialsPerParticipant - completed, 0)
        return "Trials remaining: \(remaining) of \(hapticManager.totalTrialsPerParticipant)"
    }
}

// MARK: - Haptic Manager

class HapticManager: ObservableObject {
    @Published var isRunning = false
    @Published var isWaiting = false
    @Published var lastResult: ThresholdResult?
    @Published var results: [ThresholdResult] = []
    
    @Published private(set) var currentCondition: HapticCondition?
    @Published private(set) var currentTrialNumber: Int = 0   // 1-based
    let repetitionsPerCondition = 3
    var totalTrialsPerParticipant: Int { HapticCondition.allCases.count * repetitionsPerCondition }
    
    private var trialSequence: [HapticCondition] = []
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private var startTime: Date?
    
    private var pendingDelayWorkItem: DispatchWorkItem?

    private let rampDuration: TimeInterval = 2.0
    private let maxHoldDuration: TimeInterval = 3.0
    private let maxDelay: TimeInterval = 4.0
    
    init() {
        prepareHaptics()
    }
    
    // MARK: - Haptic Engine
    
    func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            print("Device doesn't support haptics")
            return
        }
        
        do {
            engine = try CHHapticEngine()
            engine?.isAutoShutdownEnabled = false   // <- keep engine alive
            
            engine?.stoppedHandler = { reason in
                print("Engine stopped: \(reason.rawValue)")
            }
            
            engine?.resetHandler = { [weak self] in
                print("Engine reset, restarting…")
                do {
                    try self?.engine?.start()
                } catch {
                    print("Failed to restart engine: \(error)")
                }
            }
            
            try engine?.start()
        } catch {
            print("Error creating/starting haptic engine: \(error)")
        }
    }
    // MARK: - Trial control
    
    func prepareSequenceIfNeeded(for participant: String) {
        guard !participant.isEmpty else { return }
        
        if trialSequence.isEmpty || currentTrialNumber == 0 {
            setupCounterbalancedOrder(for: participant)
            currentTrialNumber = 1
            currentCondition = trialSequence.first
        }
    }
    
    func startCurrentTrial(participant: String) {
        guard !participant.isEmpty,
              currentCondition != nil,
              !isRunning
        else { return }
        startRamp(participant: participant)
    }
    
    private func advanceToNextTrial() {
        currentTrialNumber += 1
        if currentTrialNumber <= trialSequence.count {
            currentCondition = trialSequence[currentTrialNumber - 1]
        } else {
            currentCondition = nil
        }
    }
    
    private func setupCounterbalancedOrder(for participant: String) {
        let conditions = HapticCondition.allCases
        
        let base = conditions
        let latinOrders: [[HapticCondition]] = [
            base,
            [base[1], base[2], base[3], base[0]],
            [base[2], base[3], base[0], base[1]],
            [base[3], base[0], base[1], base[2]]
        ]
        
        let index = abs(participant.hashValue) % latinOrders.count
        let orderForParticipant = latinOrders[index]
        
        var fullSequence: [HapticCondition] = []
        for _ in 0..<repetitionsPerCondition {
            fullSequence.append(contentsOf: orderForParticipant)
        }
        trialSequence = fullSequence
    }
    
    func hasAnyResult(for participant: String) -> Bool {
        results.contains(where: { $0.participant == participant })
    }
    
    func canRetryPreviousTrial(participant: String) -> Bool {
        let trialsForThisParticipant = results.filter { $0.participant == participant }
        return !trialsForThisParticipant.isEmpty && currentTrialNumber > 1
    }
    
    func retryPreviousTrial(participant: String) {
        guard canRetryPreviousTrial(participant: participant),
              !isRunning
        else { return }
        
        if let lastIndex = results.lastIndex(where: { $0.participant == participant }) {
            results.remove(at: lastIndex)
        }
        
        currentTrialNumber = max(currentTrialNumber - 1, 1)
        if currentTrialNumber - 1 < trialSequence.count {
            currentCondition = trialSequence[currentTrialNumber - 1]
        }
        
        lastResult = nil
    }
    
    private func recordTimeoutResult(participant: String) {
        guard let condition = currentCondition else { return }
        
        // If you want to store the full duration as time
        let elapsedTime = rampDuration + maxHoldDuration
        let intensity = 2.0   // special code: no response / timed out
        
        let trialsForThisParticipant = results.filter { $0.participant == participant }
        let previousForCondition = trialsForThisParticipant.filter { $0.condition == condition }.count
        let repetitionIndex = previousForCondition + 1
        
        let result = ThresholdResult(
            participant: participant,
            condition: condition,
            repetitionIndex: repetitionIndex,
            globalTrialIndex: currentTrialNumber,
            time: elapsedTime,
            intensity: intensity,
            timestamp: Date()
        )
        
        results.append(result)
        lastResult = result
        
        print("Timed out: participant=\(result.participant), " +
              "condition=\(result.condition.rawValue), " +
              "repetition=\(result.repetitionIndex), " +
              String(format: "time=%.4f s, intensity=%.1f", result.time, result.intensity))
        
        isRunning = false
        isWaiting = false
        startTime = nil
        player = nil
        
        advanceToNextTrial()
    }
    
    // MARK: - Haptics per trial
    
    private func startRamp(participant: String) {
        guard engine != nil else { return }

        isRunning = true
        isWaiting = true

        let randomDelay = TimeInterval.random(in: 0...maxDelay)

        // Cancel any previous pending delay
        pendingDelayWorkItem?.cancel()

        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem { [weak self] in
            // If this work item was cancelled, do nothing
            guard let self = self, workItem?.isCancelled == false else { return }

            self.startTime = Date()
            self.isWaiting = false

            do {
                try self.engine?.start()
                self.playHapticRamp(participant: participant)
            } catch {
                print("Failed to start engine before ramp: \(error)")
                self.isRunning = false
                self.isWaiting = false
            }
        }

        pendingDelayWorkItem = workItem
        if let workItem = workItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + randomDelay, execute: workItem)
        }
    }
    
    private func playHapticRamp(participant: String) {
        guard let engine = engine else { return }
        
        let totalDuration = rampDuration + maxHoldDuration
        
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
            ],
            relativeTime: 0,
            duration: totalDuration
        )
        
        let intensityCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0.0,          value: 0.0),
                .init(relativeTime: rampDuration, value: 1.0),
                .init(relativeTime: totalDuration, value: 1.0)
            ],
            relativeTime: 0
        )
        
        do {
            let pattern = try CHHapticPattern(events: [event], parameterCurves: [intensityCurve])
            let advancedPlayer = try engine.makeAdvancedPlayer(with: pattern)
            self.player = advancedPlayer
            
            advancedPlayer.completionHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    
                    // If user already responded, do nothing
                    if !self.isRunning { return }
                    
                    // Pattern finished while still running -> timeout
                    // You need the current participant string available here.
                    // If you store it in HapticManager, use that; otherwise pass it in.
                    let participant = participant
                    self.recordTimeoutResult(participant: participant)
                }
            }
            
            try advancedPlayer.start(atTime: 0)
        } catch {
            print("Error playing haptic pattern: \(error)")
            isRunning = false
            isWaiting = false
        }
    }
    
    func stopAndRecord(participant: String) {
        guard !participant.isEmpty,
              let condition = currentCondition
        else { return }
        
        // Determine if the ramp actually started
        let rampStarted = (startTime != nil && !isWaiting)
        
        let elapsedTime: TimeInterval
        let intensity: Double
        
        if rampStarted, let startTime = startTime {
            elapsedTime = Date().timeIntervalSince(startTime)
            intensity = min(elapsedTime / rampDuration, 1.0)
        } else {
            // Pressed before vibration started (during random delay)
            elapsedTime = 0
            intensity = 0
        }
        
        let trialsForThisParticipant = results.filter { $0.participant == participant }
        let previousForCondition = trialsForThisParticipant.filter { $0.condition == condition }.count
        let repetitionIndex = previousForCondition + 1
        
        let result = ThresholdResult(
            participant: participant,
            condition: condition,
            repetitionIndex: repetitionIndex,
            globalTrialIndex: currentTrialNumber,
            time: elapsedTime,
            intensity: intensity,
            timestamp: Date()
        )
        
        results.append(result)
        lastResult = result
        
        print("Trial result: participant=\(result.participant), " +
              "condition=\(result.condition.rawValue), " +
              "repetition=\(result.repetitionIndex), " +
              String(format: "time=%.4f s, intensity=%.4f", result.time, result.intensity))
        
        // Stop any pending or running haptics
        pendingDelayWorkItem?.cancel()
        pendingDelayWorkItem = nil
        try? player?.stop(atTime: 0)
        player = nil
        
        isRunning = false
        isWaiting = false
        startTime = nil
        
        advanceToNextTrial()
    }
    
    // MARK: - Export
    
    func exportResultsForParticipant(_ participant: String) {
        let participantResults = results.filter { $0.participant == participant }
        guard !participantResults.isEmpty else {
            print("No results to export for participant \(participant)")
            return
        }
        
        let header = "Participant,Condition,Repetition,GlobalTrial,Time(s),Intensity,Timestamp"
        let rows = participantResults.map { r in
            [
                r.participant,
                r.condition.rawValue,
                "\(r.repetitionIndex)",
                "\(r.globalTrialIndex)",
                String(format: "%.4f", r.time),
                String(format: "%.4f", r.intensity),
                ISO8601DateFormatter().string(from: r.timestamp)
            ].joined(separator: ",")
        }
        let csv = ([header] + rows).joined(separator: "\n")
        
        let safeName = participant
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let ts = dateFormatter.string(from: Date())
        
        let fileName = "threshold_\(safeName)_\(ts).csv"
        
        do {
            let docsURL = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let fileURL = docsURL.appendingPathComponent(fileName)
            try csv.data(using: .utf8)?.write(to: fileURL)
            print("Saved CSV for \(participant) to: \(fileURL.path)")
        } catch {
            print("Error saving CSV for \(participant): \(error)")
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
