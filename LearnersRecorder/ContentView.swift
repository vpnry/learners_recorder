import SwiftUI
import AVFoundation
import Accelerate
import Combine
import Speech

// MARK: - Models
struct Recording: Identifiable, Codable {
    let id: UUID
    let filename: String
    let date: Date
    let duration: TimeInterval
    var name: String
    
    var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }
    
    var formattedDuration: String {
        let totalSeconds = duration
        let minutes = Int(totalSeconds) / 60
        let seconds = Int(totalSeconds) % 60
        let milliseconds = Int((totalSeconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, milliseconds)
    }
    
    init(url: URL, date: Date, duration: TimeInterval, name: String) {
        self.id = UUID()
        self.filename = url.lastPathComponent
        self.date = date
        self.duration = duration
        self.name = name
    }
}

// MARK: - Audio Manager
class AudioManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var recordings: [Recording] = []
    @Published var currentPlayingID: UUID?
    @Published var recordingLevel: Float = 0
    @Published var playbackProgress: Double = 0
    @Published var currentRecordingTime: TimeInterval = 0
    
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var levelTimer: Timer?
    private var playbackTimer: Timer?
    
    override init() {
        super.init()
        requestMicrophonePermission()
        loadRecordings()
    }
    
    private func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    print("Microphone permission denied")
                }
            }
        case .denied, .restricted:
            print("Microphone permission denied or restricted")
        @unknown default:
            break
        }
    }
    
    func startRecording() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentsPath.appendingPathComponent("\(UUID().uuidString).m4a")
        
        let settings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            // Reset and start elapsed time
            currentRecordingTime = 0

            isRecording = true
            
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                self.audioRecorder?.updateMeters()
                let level = self.audioRecorder?.averagePower(forChannel: 0) ?? -160
                self.recordingLevel = max(0, (level + 60) / 60)
                // Update elapsed recording time from recorder.currentTime for accuracy
                if let recorder = self.audioRecorder {
                    DispatchQueue.main.async {
                        self.currentRecordingTime = recorder.currentTime
                    }
                }
            }
        } catch {
            print("Could not start recording: \(error)")
        }
    }
    
    func stopRecording() async {
        levelTimer?.invalidate()
        levelTimer = nil
        recordingLevel = 0
        // Capture final recording time and reset
        let finalTime = audioRecorder?.currentTime ?? 0
        DispatchQueue.main.async {
            self.currentRecordingTime = finalTime
        }
        
        guard let recorder = audioRecorder else { return }
        
        // Ensure we have a valid URL before stopping
        let url = recorder.url
        
        recorder.stop()
        
        // Get duration from the audio file for accuracy
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            
            let recording = Recording(
                url: url,
                date: Date(),
                duration: duration,
                name: "Recording \(recordings.count + 1)"
            )
            
            DispatchQueue.main.async {
                self.isRecording = false
                self.currentRecordingTime = 0
                self.recordings.insert(recording, at: 0)
                self.saveRecordings()
                self.playRecording(recording)
            }
        } catch {
            print("Failed to load duration: \(error)")
            DispatchQueue.main.async {
                self.isRecording = false
            }
        }
    }
    
    func playRecording(_ recording: Recording) {
        stopPlayback()
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: recording.url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            isPlaying = true
            currentPlayingID = recording.id
            
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
                guard let player = self.audioPlayer else { return }
                self.playbackProgress = player.currentTime / player.duration
            }
        } catch {
            print("Could not play recording: \(error)")
        }
    }
    
    func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        audioPlayer?.stop()
        isPlaying = false
        currentPlayingID = nil
        playbackProgress = 0
    }
    
    func deleteRecording(_ recording: Recording) {
        if currentPlayingID == recording.id {
            stopPlayback()
        }
        
        do {
            try FileManager.default.removeItem(at: recording.url)
            recordings.removeAll { $0.id == recording.id }
            saveRecordings()
        } catch {
            print("Could not delete recording: \(error)")
        }
    }

    func deleteRecordings(ids: Set<UUID>) {
        for id in ids {
            if let recording = recordings.first(where: { $0.id == id }) {
                if currentPlayingID == recording.id {
                    stopPlayback()
                }
                do {
                    try FileManager.default.removeItem(at: recording.url)
                } catch {
                    print("Could not delete recording file: \(error)")
                }
            }
        }
        recordings.removeAll { ids.contains($0.id) }
        saveRecordings()
    }
    
    func renameRecording(_ recording: Recording, to newName: String) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index].name = newName
            saveRecordings()
        }
    }
    
    func generateWaveform(from recording: Recording) -> [Float] {
        guard let file = try? AVAudioFile(forReading: recording.url),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: file.fileFormat.sampleRate,
                                        channels: 1,
                                        interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: UInt32(file.length)) else {
            return Array(repeating: 0.1, count: 50)
        }
        
        do {
            try file.read(into: buffer)
        } catch {
            return Array(repeating: 0.1, count: 50)
        }
        
        guard let floatData = buffer.floatChannelData?[0] else {
            return Array(repeating: 0.1, count: 50)
        }
        
        let frameCount = Int(buffer.frameLength)
        let samplesPerPixel = max(1, frameCount / 100)
        var samples: [Float] = []
        
        for i in stride(from: 0, to: frameCount, by: samplesPerPixel) {
            let range = i..<min(i + samplesPerPixel, frameCount)
            let slice = Array(UnsafeBufferPointer(start: floatData.advanced(by: i),
                                                 count: range.count))
            let rms = sqrt(slice.map { $0 * $0 }.reduce(0, +) / Float(slice.count))
            samples.append(min(1.0, rms * 5))
        }
        
        return samples.isEmpty ? Array(repeating: 0.1, count: 50) : samples
    }
    
    private func saveRecordings() {
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(recordings) {
            UserDefaults.standard.set(encoded, forKey: "recordings")
        }
    }
    
    private func loadRecordings() {
        guard let data = UserDefaults.standard.data(forKey: "recordings"),
              let decoded = try? JSONDecoder().decode([Recording].self, from: data) else {
            return
        }
        
        // Filter out recordings whose files no longer exist
        recordings = decoded.filter { recording in
            FileManager.default.fileExists(atPath: recording.url.path)
        }
    }
}

extension AudioManager: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopPlayback()
    }
}

// MARK: - Speech ViewModel
@MainActor
class SpeechViewModel: ObservableObject {
    @Published var transcribedText: String = "Your transcribed text will appear here."
    @Published var isRecording: Bool = false
    @Published var errorMessage: String?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    init() {
        speechRecognizer = SFSpeechRecognizer()
        requestSpeechAuthorization()
    }

    private func requestSpeechAuthorization() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus != .authorized {
                    self.errorMessage = "Speech recognition authorization was denied. Please enable it in System Settings."
                }
            }
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            self.errorMessage = "Speech recognizer is not available for the current locale."
            return
        }

        self.errorMessage = nil

        do {
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                fatalError("Unable to create an SFSpeechAudioBufferRecognitionRequest object.")
            }
            recognitionRequest.shouldReportPartialResults = true

            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
                var isFinal = false
                if let result = result {
                    self.transcribedText = result.bestTranscription.formattedString
                    isFinal = result.isFinal
                }

                if error != nil || isFinal {
                    self.audioEngine.stop()
                    inputNode.removeTap(onBus: 0)
                    self.recognitionRequest = nil
                    self.recognitionTask = nil

                    DispatchQueue.main.async {
                        self.isRecording = false
                    }
                }
            }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                self.recognitionRequest?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            self.transcribedText = "Listening..."
            self.isRecording = true
        } catch {
            self.errorMessage = "Error starting recording: \(error.localizedDescription)"
            self.isRecording = false
        }
    }

    private func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        self.isRecording = false
        self.recognitionRequest = nil
        self.recognitionTask = nil
    }
}

// MARK: - Views
struct ContentView: View {
    @StateObject private var audioManager = AudioManager()
    @StateObject private var speechViewModel = SpeechViewModel()
    @State private var selectedRecording: Recording?
    @State private var showingRenameAlert = false
    @State private var newName = ""
    @State private var selectedRecordingIDs: Set<UUID> = []
    
    var body: some View {
        HSplitView {
            // Left panel - Recording list
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Recordings")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()

                    if !audioManager.recordings.isEmpty {
                        Button(action: {
                            if selectedRecordingIDs.count == audioManager.recordings.count {
                                selectedRecordingIDs.removeAll()
                            } else {
                                selectedRecordingIDs = Set(audioManager.recordings.map { $0.id })
                            }
                        }) {
                            Text(selectedRecordingIDs.count == audioManager.recordings.count ? "Deselect All" : "Select All")
                        }

                        Button(action: {
                            audioManager.deleteRecordings(ids: selectedRecordingIDs)
                            selectedRecordingIDs.removeAll()
                        }) {
                            Image(systemName: "trash")
                        }
                        .disabled(selectedRecordingIDs.isEmpty)
                    }

                    Text("\(audioManager.recordings.count)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(8)
                }
                .padding()
                
                Divider()
                
                // Recordings list
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(audioManager.recordings) { recording in
                            RecordingRow(
                                recording: recording,
                                isSelected: selectedRecordingIDs.contains(recording.id),
                                isPlaying: audioManager.currentPlayingID == recording.id,
                                playbackProgress: audioManager.currentPlayingID == recording.id ? audioManager.playbackProgress : 0,
                                audioManager: audioManager,
                                onPlay: { audioManager.playRecording(recording) },
                                onDelete: { audioManager.deleteRecording(recording) },
                                onRename: {
                                    selectedRecording = recording
                                    newName = recording.name
                                    showingRenameAlert = true
                                }
                            )
                            .onTapGesture {
                                if selectedRecordingIDs.contains(recording.id) {
                                    selectedRecordingIDs.remove(recording.id)
                                } else {
                                    selectedRecordingIDs.insert(recording.id)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .frame(minWidth: 200, idealWidth: 250, maxWidth: 300) // Adjusted width constraints
            .background(Color(NSColor.controlBackgroundColor))
            
            // Right panel - Record button and speech-to-text
            VStack(spacing: 30) {
                // Title and description
                VStack(spacing: 8) {
                    Text("Learner's Recorder")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("...voice recorder & instant playback")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)
                
                // Recording button
                RecordButton(
                    isRecording: audioManager.isRecording,
                    recordingLevel: audioManager.recordingLevel,
                    currentRecordingTime: audioManager.currentRecordingTime,
                    onStartRecording: audioManager.startRecording,
                    onStopRecording: {
                        Task {
                            await audioManager.stopRecording()
                        }
                    }
                )
                
                // Speech-to-text section
                VStack(spacing: 20) {
                    Text("Live Speech to Text")
                        .font(.headline)

                    ScrollView {
                        Text(speechViewModel.transcribedText)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 100, maxHeight: 200)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(10)

                    Button(action: speechViewModel.toggleRecording) {
                        ZStack {
                            Circle()
                                .fill(speechViewModel.isRecording ? Color.orange : Color.green) // Changed colors to differentiate
                                .frame(width: 150, height: 150)

                            VStack(spacing: 8) {
                                Image(systemName: speechViewModel.isRecording ? "stop.fill" : "mic.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(.white)

                                Text(speechViewModel.isRecording ? "Stop Transcription" : "Live Transcription")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(PlainButtonStyle()) // Removed default button background

                    if let errorMessage = speechViewModel.errorMessage {
                        Text("Error: \(errorMessage)")
                            .foregroundColor(.red)
                            .padding()
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
                .frame(maxWidth: 500)
                
                Spacer()
            }
            .frame(minWidth: 500)
            .padding()
        }
        .frame(minWidth: 900, minHeight: 600)
        .alert("Rename Recording", isPresented: $showingRenameAlert) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                if let recording = selectedRecording {
                    audioManager.renameRecording(recording, to: newName)
                }
            }
        }
    }
}

struct RecordButton: View {
    let isRecording: Bool
    let recordingLevel: Float
    let currentRecordingTime: TimeInterval
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    
    @State private var pulseAnimation = false
    
    var body: some View {
        ZStack {
            // Pulse effect when recording
            if isRecording {
                Circle()
                    .fill(Color.red.opacity(0.3))
                    .frame(width: 180, height: 180)
                    .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulseAnimation)
            }
            
            // Level indicator
            Circle()
                .fill(Color.red.opacity(isRecording ? 0.2 : 0))
                .frame(width: 150 + CGFloat(recordingLevel * 50),
                       height: 150 + CGFloat(recordingLevel * 50))
                .animation(.easeOut(duration: 0.1), value: recordingLevel)
            
            // Main button
            Circle()
                .fill(isRecording ? Color.red : Color.accentColor)
                .frame(width: 150, height: 150)
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
            
            VStack(spacing: 8) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
                // Show live elapsed recording time when recording
                if isRecording {
                    Text(formatTime(currentRecordingTime))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                }

                Text(isRecording ? "Tap to Stop" : "Tap to Record")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .onTapGesture {
            if isRecording {
                onStopRecording()
                pulseAnimation = false
            } else {
                onStartRecording()
                pulseAnimation = true
            }
        }
        .onAppear {
            if isRecording {
                pulseAnimation = true
            }
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval * 100)) // hundredths
        let minutes = total / (60 * 100)
        let seconds = (total / 100) % 60
        let hundredths = total % 100
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }
}

struct RecordingRow: View {
    let recording: Recording
    let isSelected: Bool
    let isPlaying: Bool
    let playbackProgress: Double
    let audioManager: AudioManager
    let onPlay: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void
    
    @State private var isHovered = false
    @State private var waveformSamples: [Float] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .onTapGesture {
                        // This is handled by the parent view's onTapGesture now
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.name)
                        .font(.system(size: 14, weight: .medium))
                    
                    Text(recording.formattedDuration)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    if isHovered {
                        Button(action: onRename) {
                            Image(systemName: "pencil")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            
            // Waveform visualization
            WaveformView(samples: waveformSamples, progress: playbackProgress)
                .frame(height: 30)
            
            // Progress bar
            if isPlaying {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 2)
                        
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: geometry.size.width * playbackProgress, height: 2)
                    }
                }
                .frame(height: 2)
            }
        }
        .padding(12)
        .background(isSelected ? Color.accentColor.opacity(0.3) : Color(NSColor.controlBackgroundColor).opacity(isHovered ? 1 : 0.5))
        .cornerRadius(8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .onAppear {
            // Generate waveform on appear
            DispatchQueue.global(qos: .background).async {
                let samples = audioManager.generateWaveform(from: recording)
                DispatchQueue.main.async {
                    self.waveformSamples = samples
                }
            }
        }
    }
}

struct WaveformView: View {
    let samples: [Float]
    let progress: Double
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(0..<samples.count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Double(index) / Double(samples.count) < progress ?
                              Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: max(1, geometry.size.width / CGFloat(samples.count) - 2),
                               height: CGFloat(samples[index]) * geometry.size.height)
                }
            }
        }
    }
}

