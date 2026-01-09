import SwiftUI
import CoreHaptics
import Combine

struct ContentView: View {
    @StateObject private var hapticManager = HapticManager()
    
    var body: some View {
        VStack(spacing: 30) {
            Text("Vibration Threshold Test")
                .font(.title)
                .padding()
            
            Text("Press START and tap FELT IT when you first feel the vibration")
                .multilineTextAlignment(.center)
                .padding()
            
            if hapticManager.isRunning {
                if hapticManager.isWaiting {
                    Text("Waiting to start...")
                        .foregroundColor(.orange)
                } else {
                    Text("Test in progress...")
                        .foregroundColor(.blue)
                }
                
                Button("FELT IT") {
                    hapticManager.stopAndRecord()
                }
                .font(.title2)
                .padding()
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(10)
                .disabled(hapticManager.isWaiting)
                .opacity(hapticManager.isWaiting ? 0.5 : 1.0)
            } else {
                Button("START TEST") {
                    hapticManager.startRamp()
                }
                .font(.title2)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            
            if let result = hapticManager.lastResult {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Last Result:")
                        .font(.headline)
                    Text("Time: \(String(format: "%.2f", result.time))s")
                    Text("Intensity: \(String(format: "%.2f", result.intensity))")
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
            }
            
            if !hapticManager.results.isEmpty {
                Button("Export Results") {
                    hapticManager.exportResults()
                }
                .padding()
                
                Text("Trials completed: \(hapticManager.results.count)")
                    .foregroundColor(.gray)
            }
        }
        .padding()
    }
}

class HapticManager: ObservableObject {
    @Published var isRunning = false
    @Published var isWaiting = false
    @Published var lastResult: ThresholdResult?
    @Published var results: [ThresholdResult] = []
    
    private var engine: CHHapticEngine?
    private var startTime: Date?
    private let rampDuration: TimeInterval = 10.0
    private let maxDelay: TimeInterval = 4.0 // Maximum random delay in seconds
    
    struct ThresholdResult {
        let time: TimeInterval
        let intensity: Double
        let timestamp: Date
    }
    
    init() {
        prepareHaptics()
    }
    
    func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            print("Device doesn't support haptics")
            return
        }
        
        do {
            engine = try CHHapticEngine()
            try engine?.start()
        } catch {
            print("Error creating haptic engine: \(error)")
        }
    }
    
    func startRamp() {
        guard engine != nil else { return }
        
        isRunning = true
        isWaiting = true
        
        // Generate random delay between 0 and maxDelay seconds
        let randomDelay = TimeInterval.random(in: 0...maxDelay)
        
        // Wait for random delay, then start vibration
        DispatchQueue.main.asyncAfter(deadline: .now() + randomDelay) {
            self.isWaiting = false
            self.startTime = Date()
            self.playHapticRamp()
        }
    }
    
    private func playHapticRamp() {
        guard let engine = engine else { return }
        
        // Create a ramping intensity pattern
        var events: [CHHapticEvent] = []
        let steps = 100
        
        for i in 0...steps {
            let time = TimeInterval(i) * (rampDuration / TimeInterval(steps))
            let intensity = Float(i) / Float(steps)
            
            let intensityParam = CHHapticEventParameter(
                parameterID: .hapticIntensity,
                value: intensity
            )
            let sharpnessParam = CHHapticEventParameter(
                parameterID: .hapticSharpness,
                value: 0.5
            )
            
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [intensityParam, sharpnessParam],
                relativeTime: time,
                duration: rampDuration / TimeInterval(steps)
            )
            
            events.append(event)
        }
        
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
            
            // Auto-stop after ramp completes
            DispatchQueue.main.asyncAfter(deadline: .now() + rampDuration) {
                if self.isRunning && !self.isWaiting {
                    self.isRunning = false
                }
            }
        } catch {
            print("Error playing haptic pattern: \(error)")
            isRunning = false
            isWaiting = false
        }
    }
    
    func stopAndRecord() {
        guard let startTime = startTime, isRunning, !isWaiting else { return }
        
        let elapsedTime = Date().timeIntervalSince(startTime)
        let intensity = min(elapsedTime / rampDuration, 1.0)
        
        let result = ThresholdResult(
            time: elapsedTime,
            intensity: intensity,
            timestamp: Date()
        )
        
        results.append(result)
        lastResult = result
        isRunning = false
        isWaiting = false
        
        // Stop the engine
        engine?.stop(completionHandler: { error in
            if let error = error {
                print("Error stopping engine: \(error)")
            }
            try? self.engine?.start()
        })
    }
    
    func exportResults() {
        let csv = "Trial,Time(s),Intensity,Timestamp\n" +
            results.enumerated().map { index, result in
                "\(index + 1),\(result.time),\(result.intensity),\(result.timestamp)"
            }.joined(separator: "\n")
        
        print("Results CSV:\n\(csv)")
    }
}

#Preview {
    ContentView()
}
