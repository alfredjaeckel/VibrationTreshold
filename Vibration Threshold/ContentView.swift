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
    private var player: CHHapticPatternPlayer?
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
    
    func startRamp() {
        guard let engine = engine else { return }
        
        isRunning = true
        isWaiting = true
        
        let randomDelay = TimeInterval.random(in: 0...maxDelay)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + randomDelay) { [weak self] in
            guard let self = self else { return }
            self.isWaiting = false
            self.startTime = Date()
            
            do {
                try engine.start()
                self.playHapticRamp()
            } catch {
                print("Failed to start engine before ramp: \(error)")
                self.isRunning = false
                self.isWaiting = false
            }
        }
    }
    
    private func playHapticRamp() {
        guard let engine = engine else { return }
        
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
            self.player = player
            
            try player.start(atTime: 0)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + rampDuration) { [weak self] in
                guard let self = self else { return }
                if self.isRunning && !self.isWaiting {
                    self.isRunning = false
                }
                try? self.player?.stop(atTime: 0)
                self.player = nil
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
        
        // Stop only the current pattern, keep engine alive
        try? player?.stop(atTime: 0)
        player = nil
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
