// Version 1.0.87 - Corrected Audio Routing for File and Mic
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import Accelerate
import Combine
import WatchKit

enum ActiveCrownTarget: Equatable {
    case none
    case speakerVolume
    case referenceA4
    case micGain
    case fileGain
    case defaultFileGain
}

enum DSPMode: String, CaseIterable, Identifiable, Hashable {
    case yinVector = "YIN"
    case yinFastHop = "STR"
    case fft = "FFT"
    
    var id: String { self.rawValue }
    
    var next: DSPMode {
        switch self {
        case .yinVector: return .yinFastHop
        case .yinFastHop: return .fft
        case .fft: return .yinVector
        }
    }
}

enum AudioSourceType: String {
    case microphone = "MIC"
    case file = "FILE"
}

class AudioTunerEngine: ObservableObject {
    @Published var frequency: Float = 0.0
    @Published var noteName: String = "--"
    @Published var centsDeviation: Float = 0.0
    @Published var activeSource: AudioSourceType = .file {
        didSet { updateNodeGains() }
    }
    
    @Published var micSampleRate: Double = 44100.0
    @Published var fileSampleRate: Double = 44100.0
    
    @Published var micRMSLevel: Float = 0.0
    @Published var fileRMSLevel: Float = 0.0
    
    @Published var selectedDSPMode: DSPMode = .yinVector {
        didSet {
            UserDefaults.standard.set(selectedDSPMode.rawValue, forKey: "savedDSPMode")
            reinstallTap()
        }
    }
    
    @Published var isSpeakerMuted: Bool = false {
        didSet { updateSpeakerOutput() }
    }
    
    @Published var speakerVolume: Double = UserDefaults.standard.double(forKey: "speakerVolume") == 0 ? 0.8 : UserDefaults.standard.double(forKey: "speakerVolume") {
        didSet {
            UserDefaults.standard.set(speakerVolume, forKey: "speakerVolume")
            updateSpeakerOutput()
        }
    }
    
    @Published var referenceA4: Float = UserDefaults.standard.float(forKey: "referenceA4") == 0 ? 440.0 : UserDefaults.standard.float(forKey: "referenceA4") {
        didSet {
            UserDefaults.standard.set(referenceA4, forKey: "referenceA4")
            updateNote()
        }
    }
    
    @Published var micGain: Float = UserDefaults.standard.object(forKey: "micGain") == nil ? 0.0 : UserDefaults.standard.float(forKey: "micGain") {
        didSet {
            UserDefaults.standard.set(micGain, forKey: "micGain")
            updateNodeGains()
        }
    }

    @Published var fileGain: Float = UserDefaults.standard.object(forKey: "fileGain") == nil ? 0.0 : UserDefaults.standard.float(forKey: "fileGain") {
        didSet {
            UserDefaults.standard.set(fileGain, forKey: "fileGain")
            updateNodeGains()
        }
    }

    @Published var defaultFileGain: Float = UserDefaults.standard.object(forKey: "defaultFileGain") == nil ? 0.0 : UserDefaults.standard.float(forKey: "defaultFileGain") {
        didSet {
            UserDefaults.standard.set(defaultFileGain, forKey: "defaultFileGain")
            updateNodeGains()
        }
    }

    @Published var isFilePlaying: Bool = false
    @Published var isLooping: Bool = UserDefaults.standard.bool(forKey: "isLooping") {
        didSet { UserDefaults.standard.set(isLooping, forKey: "isLooping") }
    }
    @Published var audioFileName: String = ""
    @Published var currentProgress: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var isRecording: Bool = false

    private let audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var micGainNode = AVAudioMixerNode()
    private var fileGainNode = AVAudioMixerNode()
    private var defaultFileGainNode = AVAudioMixerNode()
    private var analysisMixerNode = AVAudioMixerNode()
    private var speakerMixerNode = AVAudioMixerNode()
    
    private var audioFile: AVAudioFile?
    private var uiTimer: Timer?
    private var seekFrameOffset: AVAudioFramePosition = 0
    private var isEngineSetup = false
    private var playbackSessionID = 0
    
    private var audioRecorder: AVAudioRecorder?
    private var recordedFileURL: URL?
    
    private let analysisQueue = DispatchQueue(label: "com.guitartuner.analysis", qos: .userInteractive)
    private let engineQueue = DispatchQueue(label: "com.guitartuner.engineQueue", qos: .userInitiated)
    private var isProcessingBuffer = false

    private var fftSetup: FFTSetup?
    private let log2n: vDSP_Length = 11

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        if let savedModeRaw = UserDefaults.standard.string(forKey: "savedDSPMode"),
           let savedMode = DSPMode(rawValue: savedModeRaw) {
            self.selectedDSPMode = savedMode
        }
    }

    deinit {
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup) }
    }

    func startEngineIfNeeded() {
        guard !isEngineSetup else { return }
        isEngineSetup = true
        
        if #available(watchOS 10.0, *) {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                guard let self = self, granted else { return }
                self.engineQueue.async {
                    self.setupAudioSessionAndEngine()
                    DispatchQueue.main.async { self.restoreSavedAudioFile() }
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                guard let self = self, granted else { return }
                self.engineQueue.async {
                    self.setupAudioSessionAndEngine()
                    DispatchQueue.main.async { self.restoreSavedAudioFile() }
                }
            }
        }
    }

    private func setupAudioSessionAndEngine() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        if audioEngine.isRunning { audioEngine.stop() }

        audioEngine.attach(playerNode)
        audioEngine.attach(micGainNode)
        audioEngine.attach(fileGainNode)
        audioEngine.attach(defaultFileGainNode)
        audioEngine.attach(analysisMixerNode)
        audioEngine.attach(speakerMixerNode)

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        let connectionFormat = hardwareFormat.sampleRate > 0 ? hardwareFormat : nil

        // Mic -> micGain -> analysisMixer (Jamais vers speakerMixer)
        audioEngine.connect(inputNode, to: micGainNode, format: connectionFormat)
        audioEngine.connect(micGainNode, to: analysisMixerNode, format: connectionFormat)
        
        // File -> fileGain -> defaultFileGain -> analysisMixer ET speakerMixer
        audioEngine.connect(playerNode, to: fileGainNode, format: nil)
        audioEngine.connect(fileGainNode, to: defaultFileGainNode, format: nil)
        
        audioEngine.connect(defaultFileGainNode, to: analysisMixerNode, format: nil)
        audioEngine.connect(defaultFileGainNode, to: speakerMixerNode, format: nil)
        
        audioEngine.connect(speakerMixerNode, to: audioEngine.mainMixerNode, format: nil)

        if hardwareFormat.sampleRate > 0 {
            DispatchQueue.main.async { self.micSampleRate = hardwareFormat.sampleRate }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            
            installTroubleshootingTaps()
            reinstallTapInternal()
        } catch {
            print("Erreur Démarrage Engine Initial: \(error)")
        }

        DispatchQueue.main.async {
            self.activeSource = .file
            self.updateNodeGains()
            self.updateSpeakerOutput()
        }
    }

    private func installTroubleshootingTaps() {
        if micGainNode.engine != nil { micGainNode.removeTap(onBus: 0) }
        if fileGainNode.engine != nil { fileGainNode.removeTap(onBus: 0) }
        
        if micGainNode.engine != nil {
            let micFormat = micGainNode.inputFormat(forBus: 0)
            if micFormat.sampleRate > 0 && micFormat.channelCount > 0 {
                micGainNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [weak self] buffer, _ in
                    guard let self = self, let channelData = buffer.floatChannelData?[0] else { return }
                    var rms: Float = 0.0
                    vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(buffer.frameLength))
                    DispatchQueue.main.async { self.micRMSLevel = rms }
                }
            }
        }

        if fileGainNode.engine != nil {
            let fileFormat = fileGainNode.inputFormat(forBus: 0)
            if fileFormat.sampleRate > 0 && fileFormat.channelCount > 0 {
                fileGainNode.installTap(onBus: 0, bufferSize: 1024, format: fileFormat) { [weak self] buffer, _ in
                    guard let self = self, let channelData = buffer.floatChannelData?[0] else { return }
                    var rms: Float = 0.0
                    vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(buffer.frameLength))
                    DispatchQueue.main.async { self.fileRMSLevel = rms }
                }
            }
        }
    }

    func reinstallTap() {
        engineQueue.async { [weak self] in self?.reinstallTapInternal() }
    }

    private func reinstallTapInternal() {
        guard analysisMixerNode.engine != nil else { return }
        analysisMixerNode.removeTap(onBus: 0)
        
        let tapFormat = analysisMixerNode.inputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0 && tapFormat.channelCount > 0 else { return }
        
        let activeBufferSize: AVAudioFrameCount = selectedDSPMode == .yinFastHop ? 1024 : 2048

        analysisMixerNode.installTap(onBus: 0, bufferSize: activeBufferSize, format: tapFormat) { [weak self] (buffer, _) in
            guard let self = self, !self.isProcessingBuffer else { return }
            self.isProcessingBuffer = true
            self.analysisQueue.async {
                self.processAudioBuffer(buffer)
                self.isProcessingBuffer = false
            }
        }
    }

    private func updateNodeGains() {
        let micLinear = pow(10.0, micGain / 20.0)
        let fileLinear = pow(10.0, fileGain / 20.0)
        let defaultFileLinear = pow(10.0, defaultFileGain / 20.0)

        // Mic va TOUJOURS dans son VU-mètre (micGainNode actif), mais JAMAIS vers les haut-parleurs.
        micGainNode.outputVolume = micLinear

        if activeSource == .file {
            fileGainNode.outputVolume = isFilePlaying ? fileLinear : 0.0
            defaultFileGainNode.outputVolume = defaultFileLinear
        } else {
            fileGainNode.outputVolume = 0.0
            defaultFileGainNode.outputVolume = 0.0
        }
    }

    private func updateSpeakerOutput() {
        if isSpeakerMuted {
            speakerMixerNode.outputVolume = 0.0
        } else {
            let logVolume = Float(pow(speakerVolume, 2.0))
            speakerMixerNode.outputVolume = logVolume
        }
    }

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let timestamp = Int(Date().timeIntervalSince1970)
        let fileURL = docs.appendingPathComponent("rec_\(timestamp).wav")
        recordedFileURL = fileURL

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.record()
            DispatchQueue.main.async { self.isRecording = true }
        } catch {
            print("Erreur enregistrement: \(error)")
        }
    }

    private func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        DispatchQueue.main.async { self.isRecording = false }
        if let url = recordedFileURL { loadAudioFile(url: url) }
    }

    func loadAudioFile(url: URL) {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let file = try AVAudioFile(forReading: url)
                self.audioFile = file
                let fileFormat = file.processingFormat
                DispatchQueue.main.async {
                    self.audioFileName = url.lastPathComponent
                    self.duration = Double(file.length) / fileFormat.sampleRate
                    self.fileSampleRate = fileFormat.sampleRate
                    self.currentProgress = 0.0
                    self.seekFrameOffset = 0
                    UserDefaults.standard.set(url.path, forKey: "savedWatchAudioPath")
                }
            } catch {
                print("Erreur Chargement Fichier: \(error)")
            }
        }
    }

    private func restoreSavedAudioFile() {
        if let path = UserDefaults.standard.string(forKey: "savedWatchAudioPath") {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                loadAudioFile(url: url)
                return
            }
        }
        loadDefaultReferenceFile()
    }

    private func loadDefaultReferenceFile() {
        if let bundleURL = Bundle.main.url(forResource: "Guitar", withExtension: "wav") {
            loadAudioFile(url: bundleURL)
            return
        }
        
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let defaultURL = docs.appendingPathComponent("default_reference.wav")
        generateDefaultReferenceFile(at: defaultURL)
        if FileManager.default.fileExists(atPath: defaultURL.path) {
            loadAudioFile(url: defaultURL)
        }
    }

    private func generateDefaultReferenceFile(at url: URL) {
        let sampleRate: Double = 44100.0
        let notes: [(freq: Double, dur: Double)] = [
            (82.41, 1.5), (110.00, 1.5), (146.83, 1.5), (196.00, 1.5), (246.94, 1.5), (329.63, 2.0)
        ]

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { return }

        var totalFrames: AVAudioFrameCount = 0
        for note in notes { totalFrames += AVAudioFrameCount(note.dur * sampleRate) }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else { return }
        buffer.frameLength = totalFrames

        guard let floatData = buffer.floatChannelData?[0] else { return }

        var currentFrame = 0
        for note in notes {
            let frameCount = Int(note.dur * sampleRate)
            let freq = note.freq
            for i in 0..<frameCount {
                let time = Double(i) / sampleRate
                floatData[currentFrame] = Float(sin(2.0 * .pi * freq * time) * 0.6)
                currentFrame += 1
            }
        }

        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            let audioFile = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false
            ])
            try audioFile.write(from: buffer)
        } catch {
            print("Erreur génération fichier: \(error)")
        }
    }

    func playFile() {
        engineQueue.async { [weak self] in
            guard let self = self, let file = self.audioFile else { return }
            let fileFormat = file.processingFormat
            playbackSessionID += 1

            DispatchQueue.main.async {
                self.activeSource = .file
                self.isFilePlaying = true
                self.fileSampleRate = fileFormat.sampleRate
                self.updateNodeGains()
                self.startUITimer()
            }

            if !self.audioEngine.isRunning { try? self.audioEngine.start() }
            let startFrame = AVAudioFramePosition(self.currentProgress * fileFormat.sampleRate)
            self.scheduleFile(startingFrom: startFrame, sessionID: self.playbackSessionID)
            self.playerNode.play()
        }
    }

    private func scheduleFile(startingFrom frame: AVAudioFramePosition = 0, sessionID: Int) {
        guard let file = audioFile else { return }
        if playerNode.isPlaying { playerNode.stop() }
        playerNode.reset()
        
        let frameCount = AVAudioFrameCount(file.length - frame)
        guard frameCount > 0 else { return }
        seekFrameOffset = frame

        playerNode.scheduleSegment(file, startingFrame: frame, frameCount: frameCount, at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.playbackSessionID == sessionID else { return }
                if self.isLooping && self.isFilePlaying {
                    self.currentProgress = 0.0
                    self.playbackSessionID += 1
                    let currentID = self.playbackSessionID
                    self.engineQueue.async {
                        self.scheduleFile(startingFrom: 0, sessionID: currentID)
                        if self.audioEngine.isRunning { self.playerNode.play() }
                    }
                } else {
                    self.pauseFile()
                }
            }
        }
    }

    func pauseFile() {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            self.playbackSessionID += 1
            if self.playerNode.isPlaying { self.playerNode.pause() }
            DispatchQueue.main.async {
                self.stopUITimer()
                self.isFilePlaying = false
                self.activeSource = .microphone
                self.updateNodeGains()
            }
        }
    }

    func togglePlayPauseFile() { if isFilePlaying { pauseFile() } else { playFile() } }
    func stopFilePlayback() { pauseFile(); seek(to: 0) }
    func toggleLoop() { isLooping.toggle() }

    func seek(to time: Double) {
        guard let file = audioFile else { return }
        let targetTime = max(0.0, min(duration, time))
        let wasPlaying = isFilePlaying
        
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            self.playbackSessionID += 1
            let currentSessionID = self.playbackSessionID
            if self.playerNode.isPlaying { self.playerNode.stop() }
            self.playerNode.reset()

            let sampleRate = file.processingFormat.sampleRate
            let framePosition = AVAudioFramePosition(targetTime * sampleRate)

            DispatchQueue.main.async {
                self.currentProgress = targetTime
                self.clearTunerDisplay()
                if wasPlaying { self.activeSource = .file }
            }

            if wasPlaying {
                self.scheduleFile(startingFrom: framePosition, sessionID: currentSessionID)
                if self.audioEngine.isRunning { self.playerNode.play() }
            } else {
                self.seekFrameOffset = framePosition
            }
        }
    }

    private func startUITimer() {
        stopUITimer()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, self.isFilePlaying, let file = self.audioFile else { return }
            if let nodeTime = self.playerNode.lastRenderTime,
               let playerTime = self.playerNode.playerTime(forNodeTime: nodeTime) {
                let elapsedSeconds = Double(playerTime.sampleTime + self.seekFrameOffset) / file.processingFormat.sampleRate
                DispatchQueue.main.async {
                    if elapsedSeconds <= self.duration { self.currentProgress = elapsedSeconds }
                }
            }
        }
    }

    private func stopUITimer() { uiTimer?.invalidate(); uiTimer = nil }
    private func clearTunerDisplay() { self.frequency = 0.0; self.noteName = "--"; self.centsDeviation = 0.0 }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let sampleRate = Float(buffer.format.sampleRate)
        guard sampleRate > 0, let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var rms: Float = 0.0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameCount))

        if rms < 0.0005 {
            DispatchQueue.main.async { if self.frequency != 0.0 { self.clearTunerDisplay() } }
            return
        }

        let bufferArray = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        var detectedPitch: Float = 0.0
        var isValid = false

        switch selectedDSPMode {
        case .fft:
            detectedPitch = detectPitchFFTAutocorr(buffer: bufferArray, sampleRate: sampleRate)
            isValid = detectedPitch >= 60.0 && detectedPitch <= 1000.0
        case .yinVector, .yinFastHop:
            let (pitch, clarity) = detectPitchYINVectorized(buffer: bufferArray, sampleRate: sampleRate)
            detectedPitch = pitch
            let clarityThreshold: Float = selectedDSPMode == .yinVector ? 0.25 : 0.30
            isValid = clarity < clarityThreshold && detectedPitch >= 60.0 && detectedPitch <= 1000.0
        }

        DispatchQueue.main.async {
            if isValid {
                self.frequency = detectedPitch
                self.updateNote()
            } else if self.frequency != 0.0 {
                self.clearTunerDisplay()
            }
        }
    }

    private func detectPitchFFTAutocorr(buffer: [Float], sampleRate: Float) -> Float {
        let n = buffer.count, halfN = n / 2
        var padded = [Float](repeating: 0.0, count: n * 2)
        for i in 0..<n { padded[i] = buffer[i] }
        
        let fftSize = n * 2
        let log2FFT = vDSP_Length(log2(Double(fftSize)))
        guard let doubleFFTSetup = vDSP_create_fftsetup(log2FFT, FFTRadix(kFFTRadix2)) else { return 0.0 }
        defer { vDSP_destroy_fftsetup(doubleFFTSetup) }
        
        var realp = [Float](repeating: 0.0, count: n)
        var imagp = [Float](repeating: 0.0, count: n)
        
        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                padded.withUnsafeBufferPointer { bufferPtr in
                    let pointer = UnsafeRawPointer(bufferPtr.baseAddress!).assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ctoz(pointer, 2, &splitComplex, 1, vDSP_Length(n))
                }
                vDSP_fft_zrip(doubleFFTSetup, &splitComplex, 1, log2FFT, FFTDirection(1))
                var magSq = [Float](repeating: 0.0, count: n)
                vDSP_zvmags(&splitComplex, 1, &magSq, 1, vDSP_Length(n))
                for i in 0..<n { realPtr[i] = magSq[i]; imagPtr[i] = 0.0 }
                vDSP_fft_zrip(doubleFFTSetup, &splitComplex, 1, log2FFT, FFTDirection(-1))
            }
        }
        
        var autocorr = [Float](repeating: 0.0, count: n)
        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                autocorr.withUnsafeMutableBufferPointer { autocorrPtr in
                    let destPtr = UnsafeMutableRawPointer(autocorrPtr.baseAddress!).assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ztoc(&splitComplex, 1, destPtr, 2, vDSP_Length(halfN))
                }
            }
        }
        
        let minLag = Int(sampleRate / 1000.0)
        let maxLag = Int(sampleRate / 60.0)
        guard maxLag < halfN else { return 0.0 }
        
        var bestLag = -1
        var maxVal: Float = -1.0
        for lag in minLag..<maxLag {
            if autocorr[lag] > maxVal { maxVal = autocorr[lag]; bestLag = lag }
        }
        
        guard bestLag > minLag && bestLag < maxLag - 1 else { return 0.0 }
        let y1 = autocorr[bestLag - 1], y2 = autocorr[bestLag], y3 = autocorr[bestLag + 1]
        let denom = (2.0 * (2.0 * y2 - y1 - y3))
        let delta = abs(denom) > 1e-6 ? (y3 - y1) / denom : 0.0
        return sampleRate / (Float(bestLag) + delta)
    }

    private func detectPitchYINVectorized(buffer: [Float], sampleRate: Float) -> (pitch: Float, clarity: Float) {
        let n = buffer.count, halfN = n / 2
        var yinBuffer = [Float](repeating: 0.0, count: halfN)

        for tau in 1..<halfN {
            var diff = [Float](repeating: 0.0, count: halfN)
            buffer.withUnsafeBufferPointer { bufPtr in
                let ptrA = bufPtr.baseAddress!
                let ptrB = bufPtr.baseAddress! + tau
                vDSP_vsub(ptrB, 1, ptrA, 1, &diff, 1, vDSP_Length(halfN))
            }
            var sumSquare: Float = 0.0
            vDSP_svesq(diff, 1, &sumSquare, vDSP_Length(halfN))
            yinBuffer[tau] = sumSquare
        }

        yinBuffer[0] = 1.0
        var runningSum: Float = 0.0
        for tau in 1..<halfN {
            runningSum += yinBuffer[tau]
            yinBuffer[tau] = runningSum == 0 ? 1.0 : yinBuffer[tau] * (Float(tau) / runningSum)
        }

        let threshold: Float = 0.20
        var tauFound = -1
        var minClarity: Float = 1.0

        for tau in 2..<halfN {
            if yinBuffer[tau] < threshold {
                var localTau = tau
                while localTau + 1 < halfN && yinBuffer[localTau + 1] < yinBuffer[localTau] { localTau += 1 }
                tauFound = localTau
                minClarity = yinBuffer[localTau]
                break
            }
        }

        if tauFound == -1 {
            var minTau = 2
            minClarity = yinBuffer[2]
            for tau in 2..<halfN {
                if yinBuffer[tau] < minClarity { minClarity = yinBuffer[tau]; minTau = tau }
            }
            if minClarity < 0.40 { tauFound = minTau } else { return (0.0, 1.0) }
        }

        let betterTau: Float
        let x = tauFound
        if x > 0 && x < halfN - 1 {
            let s0 = yinBuffer[x - 1], s1 = yinBuffer[x], s2 = yinBuffer[x + 1]
            let denom = (2 * (2 * s1 - s0 - s2))
            betterTau = abs(denom) > 1e-6 ? Float(x) + (s2 - s0) / denom : Float(x)
        } else {
            betterTau = Float(x)
        }

        return (sampleRate / betterTau, minClarity)
    }

    private func updateNote() {
        guard frequency > 0 else { return }
        let midiNote = 12 * log2(frequency / referenceA4) + 69
        let roundedNote = Int(round(midiNote))
        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let index = (roundedNote % 12 + 12) % 12
        let octave = (roundedNote / 12) - 1

        noteName = "\(noteNames[index])\(octave)"
        centsDeviation = (midiNote - Float(roundedNote)) * 100
    }
}

struct PetersonStrobeViewWatch: View {
    let centsDeviation: Float
    let isActive: Bool
    
    @State private var rotationAngle: Double = 0.0

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                let ringCount = 3

                for ring in 0..<ringCount {
                    let outerR = radius * CGFloat(ringCount - ring) / CGFloat(ringCount)
                    let innerR = radius * CGFloat(ringCount - ring - 1) / CGFloat(ringCount)
                    let segmentCount = 8 * (ring + 1)
                    let angleStep = (2.0 * .pi) / Double(segmentCount)

                    for i in 0..<segmentCount {
                        if i % 2 == 0 {
                            let startAngle = Double(i) * angleStep + (rotationAngle * (ring % 2 == 0 ? 1.0 : -1.0) * .pi / 180.0)
                            let endAngle = startAngle + angleStep

                            var path = Path()
                            path.addArc(center: center, radius: outerR, startAngle: Angle(radians: startAngle), endAngle: Angle(radians: endAngle), clockwise: false)
                            path.addArc(center: center, radius: innerR, startAngle: Angle(radians: endAngle), endAngle: Angle(radians: startAngle), clockwise: true)
                            path.closeSubpath()

                            let opacity = abs(centsDeviation) < 5 ? 0.9 : 0.6
                            let color = abs(centsDeviation) < 5 ? Color.green : (centsDeviation > 0 ? Color.orange : Color.cyan)
                            context.fill(path, with: .color(color.opacity(opacity)))
                        }
                    }
                }
            }
            .onChange(of: timeline.date) {
                if isActive {
                    if abs(centsDeviation) > 1.0 {
                        let speed = Double(centsDeviation) * 0.15
                        rotationAngle += speed
                    }
                }
            }
        }
    }
}

struct TunerMainPage: View {
    @ObservedObject var tuner: AudioTunerEngine
    @Binding var crownTarget: ActiveCrownTarget
    @FocusState private var isSpkrFocused: Bool
    @FocusState private var isA4Focused: Bool

    @State private var speakerCrownValue: Double = 0.0
    @State private var a4CrownValue: Double = 440.0

    var body: some View {
        ZStack {
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 2) {
                            Circle()
                                .fill(tuner.activeSource == .microphone ? Color.red : Color.clear)
                                .frame(width: 4, height: 4)
                            Text("M")
                                .font(.system(size: 6, weight: .bold))
                                .foregroundColor(tuner.activeSource == .microphone ? .red : .gray)
                            CapsuleMeterWatch(level: tuner.micRMSLevel, color: .red)
                        }

                        HStack(spacing: 2) {
                            Circle()
                                .fill(tuner.activeSource == .file ? Color.green : Color.clear)
                                .frame(width: 4, height: 4)
                            Text("F")
                                .font(.system(size: 6, weight: .bold))
                                .foregroundColor(tuner.activeSource == .file ? .green : .gray)
                            CapsuleMeterWatch(level: tuner.fileRMSLevel, color: .green)
                        }
                    }

                    Spacer()

                    Text("POLYTUNE")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundColor(.yellow)

                    Spacer()

                    Button(action: {
                        crownTarget = crownTarget == .speakerVolume ? .none : .speakerVolume
                        WKInterfaceDevice.current().play(.click)
                    }) {
                        VStack(spacing: 0) {
                            Text("SPKR")
                                .font(.system(size: 6, weight: .black))
                            Text(tuner.isSpeakerMuted ? "MUTE" : "\(Int(tuner.speakerVolume * 100))%")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                        }
                    }
                    .frame(width: 36, height: 22)
                    .background(crownTarget == .speakerVolume ? Color.yellow : (tuner.isSpeakerMuted ? Color.red.opacity(0.3) : Color.white.opacity(0.15)))
                    .foregroundColor(crownTarget == .speakerVolume ? .black : (tuner.isSpeakerMuted ? .red : .green))
                    .cornerRadius(4)
                    .focusable(crownTarget == .speakerVolume)
                    .focused($isSpkrFocused)
                    .digitalCrownRotation($speakerCrownValue, from: 0.0, through: 5.0, sensitivity: .low, isContinuous: false)
                    .onAppear {
                        speakerCrownValue = tuner.speakerVolume * 5.0
                    }
                    .onChange(of: speakerCrownValue) { _, newValue in
                        tuner.speakerVolume = max(0.0, min(1.0, newValue / 5.0))
                    }
                }
                .padding(.horizontal, 2)

                Spacer(minLength: 2)

                VStack(spacing: 2) {
                    ZStack {
                        PetersonStrobeViewWatch(centsDeviation: tuner.centsDeviation, isActive: tuner.frequency > 0)
                            .frame(width: 104, height: 104)

                        Circle()
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 42, height: 42)

                        VStack(spacing: 0) {
                            Text(tuner.noteName)
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                .foregroundColor(.yellow)

                            Text(tuner.frequency > 0 ? String(format: "%.1fHz", tuner.frequency) : "---Hz")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundColor(.yellow)
                        }
                    }

                    HStack {
                        Button(action: {
                            tuner.selectedDSPMode = tuner.selectedDSPMode.next
                            WKInterfaceDevice.current().play(.click)
                        }) {
                            Text(tuner.selectedDSPMode.rawValue)
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                        }
                        .frame(width: 30, height: 18)
                        .background(Color.white.opacity(0.15))
                        .foregroundColor(.yellow)
                        .cornerRadius(4)

                        Spacer()

                        Button(action: {
                            crownTarget = (crownTarget == .referenceA4) ? .none : .referenceA4
                            WKInterfaceDevice.current().play(.click)
                        }) {
                            Text("\(Int(tuner.referenceA4))")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                        }
                        .frame(width: 30, height: 18)
                        .background(crownTarget == .referenceA4 ? Color.yellow : Color.white.opacity(0.15))
                        .foregroundColor(crownTarget == .referenceA4 ? .black : .yellow)
                        .cornerRadius(4)
                    }
                    .frame(width: 104)

                    HStack(spacing: 3) {
                        Text("♭")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.cyan)

                        ZStack {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 80, height: 5)

                            Rectangle()
                                .fill(Color.yellow)
                                .frame(width: 1, height: 8)

                            Circle()
                                .fill(abs(tuner.centsDeviation) < 5 ? Color.green : (tuner.centsDeviation > 0 ? Color.orange : Color.cyan))
                                .frame(width: 7, height: 7)
                                .offset(x: CGFloat(max(-38, min(38, tuner.centsDeviation * 0.76))))
                        }

                        Text("♯")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.orange)
                    }
                }

                Spacer(minLength: 2)
            }

            if crownTarget == .referenceA4 {
                HStack {
                    Spacer()
                    VStack {
                        Text("A4")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(.yellow)

                        ZStack(alignment: .bottom) {
                            Capsule()
                                .fill(Color.white.opacity(0.2))
                                .frame(width: 4, height: 70)

                            Capsule()
                                .fill(Color.yellow)
                                .frame(width: 4, height: CGFloat((tuner.referenceA4 - 430.0) / 20.0) * 70.0)
                        }

                        Text("\(Int(tuner.referenceA4))")
                            .font(.system(size: 6, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                    }
                    .padding(.trailing, 1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        tuner.referenceA4 = 440.0
                        a4CrownValue = 440.0
                        WKInterfaceDevice.current().play(.directionUp)
                    }
                    .focusable(true)
                    .focused($isA4Focused)
                    .digitalCrownRotation($a4CrownValue, from: 430.0, through: 450.0, sensitivity: .low, isContinuous: false)
                    .onAppear {
                        a4CrownValue = Double(tuner.referenceA4)
                    }
                    .onChange(of: a4CrownValue) { _, newValue in
                        tuner.referenceA4 = max(430.0, min(450.0, Float(newValue)))
                    }
                }
            }
        }
        .onChange(of: crownTarget) { _, newTarget in
            if newTarget == .speakerVolume {
                isSpkrFocused = true
            } else if newTarget == .referenceA4 {
                isA4Focused = true
            }
        }
    }
}

struct TunerSettingsPage: View {
    @ObservedObject var tuner: AudioTunerEngine
    @Binding var crownTarget: ActiveCrownTarget

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 6) {
                    CursorGainSliderWatch(
                        title: "MIC GAIN",
                        value: $tuner.micGain,
                        minVal: -40.0,
                        maxVal: 40.0,
                        unit: "dB",
                        accentColor: .yellow,
                        isSelected: crownTarget == .micGain,
                        onSelect: { crownTarget = crownTarget == .micGain ? .none : .micGain }
                    )

                    CursorGainSliderWatch(
                        title: "FILE VOL",
                        value: $tuner.fileGain,
                        minVal: -40.0,
                        maxVal: 40.0,
                        unit: "dB",
                        accentColor: .green,
                        isSelected: crownTarget == .fileGain,
                        onSelect: { crownTarget = crownTarget == .fileGain ? .none : .fileGain }
                    )

                    CursorGainSliderWatch(
                        title: "DEFAULT FILE VOL",
                        value: $tuner.defaultFileGain,
                        minVal: -40.0,
                        maxVal: 40.0,
                        unit: "dB",
                        accentColor: .cyan,
                        isSelected: crownTarget == .defaultFileGain,
                        onSelect: { crownTarget = crownTarget == .defaultFileGain ? .none : .defaultFileGain }
                    )

                    Button(action: {
                        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        if let files = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
                            if let firstAudio = files.first(where: { $0.pathExtension == "wav" || $0.pathExtension == "m4a" || $0.pathExtension == "mp3" }) {
                                tuner.loadAudioFile(url: firstAudio)
                            }
                        }
                        WKInterfaceDevice.current().play(.click)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("RELOAD LOCAL AUDIO")
                                .font(.system(size: 8, weight: .bold))
                        }
                    }
                    .frame(height: 22)
                    .background(Color.white.opacity(0.12))
                    .foregroundColor(.green)
                    .cornerRadius(4)

                    if !tuner.audioFileName.isEmpty {
                        VStack(spacing: 2) {
                            Text(tuner.audioFileName)
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.green)
                                .lineLimit(1)

                            if tuner.duration > 0 {
                                Slider(value: Binding(get: { tuner.currentProgress }, set: { tuner.seek(to: $0) }), in: 0...tuner.duration)
                                    .accentColor(.green)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollDisabled(crownTarget != .none)

            Spacer(minLength: 2)

            HStack(spacing: 6) {
                ProToolsButtonWatch(icon: tuner.isRecording ? "stop.circle.fill" : "mic.badge.plus", isActive: tuner.isRecording, activeColor: .red) {
                    tuner.toggleRecording()
                }
                ProToolsButtonWatch(icon: tuner.isFilePlaying ? "pause.fill" : "play.fill", isActive: tuner.isFilePlaying, activeColor: .green) {
                    tuner.togglePlayPauseFile()
                }
                ProToolsButtonWatch(icon: tuner.isLooping ? "repeat.circle.fill" : "repeat", isActive: tuner.isLooping, activeColor: .green) {
                    tuner.toggleLoop()
                }
            }
            .padding(.vertical, 2)
            .background(Color.black)
        }
    }
}

struct PolyTuneview: View {
    @StateObject private var tuner = AudioTunerEngine()
    @State private var crownTarget: ActiveCrownTarget = .none

    var body: some View {
        TabView {
            TunerMainPage(tuner: tuner, crownTarget: $crownTarget)
            TunerSettingsPage(tuner: tuner, crownTarget: $crownTarget)
        }
        .tabViewStyle(.page)
        .onAppear {
            tuner.startEngineIfNeeded()
        }
    }
}

typealias PolyTuneView = PolyTuneview

struct CursorGainSliderWatch: View {
    let title: String
    @Binding var value: Float
    var minVal: Float = -40.0
    var maxVal: Float = 40.0
    let unit: String
    let accentColor: Color
    let isSelected: Bool
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool
    @State private var crownValue: Double = 0.0

    var body: some View {
        Button(action: {
            onSelect()
            WKInterfaceDevice.current().play(.click)
        }) {
            VStack(spacing: 1) {
                HStack {
                    Text(title)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(isSelected ? .black : accentColor)
                    Spacer()
                    Text(String(format: "%+.1f %@", value, unit))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(isSelected ? .black : accentColor)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.15))
                            .frame(height: 4)

                        Rectangle()
                            .fill(isSelected ? Color.white : accentColor)
                            .frame(width: 3, height: 10)
                            .offset(x: CGFloat((value - minVal) / (maxVal - minVal)) * (geo.size.width - 3))
                    }
                }
                .frame(height: 10)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(isSelected ? accentColor : Color.white.opacity(0.08))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onTapGesture(count: 2) {
            value = 0.0
            crownValue = 0.0
            WKInterfaceDevice.current().play(.directionUp)
        }
        .focusable(isSelected)
        .focused($isFocused)
        .digitalCrownRotation($crownValue, from: -5.0, through: 5.0, sensitivity: .low, isContinuous: false)
        .onAppear {
            crownValue = Double(value) / 8.0
        }
        .onChange(of: isSelected) { _, selected in
            if selected {
                isFocused = true
                crownValue = Double(value) / 8.0
            }
        }
        .onChange(of: crownValue) { _, newValue in
            let mappedVal = Float(newValue * 8.0)
            value = max(minVal, min(maxVal, mappedVal))
        }
    }
}

struct CapsuleMeterWatch: View {
    let level: Float
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.2))
                Rectangle()
                    .fill(color)
                    .frame(width: CGFloat(min(1.0, level * 5.0)) * geo.size.width)
            }
            .cornerRadius(1)
        }
        .frame(width: 18, height: 4)
    }
}

struct ProToolsButtonWatch: View {
    let icon: String
    var isActive: Bool = false
    var activeColor: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isActive ? activeColor : .yellow)
        }
        .frame(width: 34, height: 26)
        .background(Color.white.opacity(0.12))
        .cornerRadius(4)
    }
}


