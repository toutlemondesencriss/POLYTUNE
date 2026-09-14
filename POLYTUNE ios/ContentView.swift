// Version 1.0.88 - iOS 16+ Compatibility & Single Instance Enforcement
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import Accelerate
import Combine

enum DSPMode: String, CaseIterable, Identifiable, Hashable {
    case fft = "MODE FFT"
    case yinVector = "MODE YIN"
    case yinFastHop = "MODE STR"
    
    var id: String { self.rawValue }
}

enum AudioSourceType: String {
    case microphone = "MIC"
    case file = "FILE"
}

final class AudioTunerEngine: ObservableObject {
    static let shared = AudioTunerEngine()

    @Published var frequency: Float = 0.0
    @Published var noteName: String = "--"
    @Published var centsDeviation: Float = 0.0
    
    @Published var activeSource: AudioSourceType = .microphone {
        didSet { updateRoutingAndGains() }
    }
    
    @Published var micSampleRate: Double = 44100.0
    @Published var fileSampleRate: Double = 44100.0
    
    @Published var micRMSLevel: Float = 0.0
    @Published var fileRMSLevel: Float = 0.0
    
    @Published var selectedDSPMode: DSPMode = .yinVector {
        didSet {
            UserDefaults.standard.set(selectedDSPMode.rawValue, forKey: "savedDSPMode")
            updateTapBufferSize()
        }
    }
    
    @Published var isSpeakerEnabled: Bool = true {
        didSet { updateSpeakerOutput() }
    }
    
    @Published var referenceA4: Float = {
        let val = UserDefaults.standard.float(forKey: "referenceA4")
        return val == 0 ? 440.0 : val
    }() {
        didSet {
            UserDefaults.standard.set(referenceA4, forKey: "referenceA4")
            updateNote()
        }
    }
    
    @Published var micGain: Float = {
        return UserDefaults.standard.object(forKey: "micGain") == nil ? 0.0 : UserDefaults.standard.float(forKey: "micGain")
    }() {
        didSet {
            UserDefaults.standard.set(micGain, forKey: "micGain")
            updateRoutingAndGains()
        }
    }

    @Published var fileGain: Float = {
        return UserDefaults.standard.object(forKey: "fileGain") == nil ? 0.0 : UserDefaults.standard.float(forKey: "fileGain")
    }() {
        didSet {
            UserDefaults.standard.set(fileGain, forKey: "fileGain")
            updateRoutingAndGains()
        }
    }

    @Published var isFilePlaying: Bool = false
    @Published var isLooping: Bool = UserDefaults.standard.bool(forKey: "isLooping") {
        didSet { UserDefaults.standard.set(isLooping, forKey: "isLooping") }
    }
    @Published var audioFileName: String = ""
    @Published var currentProgress: Double = 0.0
    @Published var duration: Double = 0.0

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let micGainNode = AVAudioMixerNode()
    private let fileGainNode = AVAudioMixerNode()
    private let speakerMixerNode = AVAudioMixerNode()
    
    private var audioFile: AVAudioFile?
    private var activeSecurityURL: URL?
    private var uiTimer: AnyCancellable?
    private var seekFrameOffset: AVAudioFramePosition = 0
    private var isEngineSetup = false
    private var playbackSessionID = 0
    private var currentEngineFormat: AVAudioFormat?
    
    private let analysisQueue = DispatchQueue(label: "com.guitartuner.analysis", qos: .userInteractive)
    private let engineQueue = DispatchQueue(label: "com.guitartuner.engineQueue", qos: .userInitiated)
    private let atomicQueue = DispatchQueue(label: "com.guitartuner.atomic", qos: .userInteractive)
    private var isProcessingBuffer = false

    private var fftSetup: FFTSetup?
    private let log2n: vDSP_Length = 11

    private init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        if let savedModeRaw = UserDefaults.standard.string(forKey: "savedDSPMode"),
           let savedMode = DSPMode(rawValue: savedModeRaw) {
            self.selectedDSPMode = savedMode
        }
    }

    deinit {
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup) }
        stopAccessingCurrentURL()
        uiTimer?.cancel()
    }

    private func stopAccessingCurrentURL() {
        if let url = activeSecurityURL {
            url.stopAccessingSecurityScopedResource()
            activeSecurityURL = nil
        }
    }

    func startEngineIfNeeded() {
        guard !isEngineSetup else { return }
        isEngineSetup = true
        
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard let self = self, granted else { return }
            self.engineQueue.async {
                self.setupAudioSessionAndEngine()
                DispatchQueue.main.async { self.restoreSavedAudioFile() }
            }
        }
    }

    private func setupAudioSessionAndEngine() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            if let inputs = session.availableInputs, let builtInMic = inputs.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtInMic)
            }
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Erreur Session Audio: \(error)")
        }

        if audioEngine.isRunning { audioEngine.stop() }

        audioEngine.attach(playerNode)
        audioEngine.attach(micGainNode)
        audioEngine.attach(fileGainNode)
        audioEngine.attach(speakerMixerNode)

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        self.currentEngineFormat = hardwareFormat

        audioEngine.connect(inputNode, to: micGainNode, format: hardwareFormat)
        
        let standardFormat = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 1) ?? hardwareFormat
        audioEngine.connect(playerNode, to: fileGainNode, format: standardFormat)
        audioEngine.connect(fileGainNode, to: speakerMixerNode, format: standardFormat)
        audioEngine.connect(speakerMixerNode, to: audioEngine.mainMixerNode, format: hardwareFormat)

        if hardwareFormat.sampleRate > 0 {
            DispatchQueue.main.async { self.micSampleRate = hardwareFormat.sampleRate }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("Erreur Démarrage Engine: \(error)")
        }

        updateRoutingAndGains()
        updateTapRouting()
    }

    func updateRoutingAndGains() {
        let micLinear = pow(10.0, micGain / 20.0)
        let fileLinear = pow(10.0, fileGain / 20.0)

        micGainNode.outputVolume = micLinear
        fileGainNode.outputVolume = fileLinear
        speakerMixerNode.outputVolume = isSpeakerEnabled ? 1.0 : 0.0
    }

    private func updateTapBufferSize() {
        engineQueue.async { [weak self] in
            self?.updateTapRouting()
        }
    }

    private func updateTapRouting() {
        guard audioEngine.isRunning else { return }
        
        micGainNode.removeTap(onBus: 0)
        fileGainNode.removeTap(onBus: 0)
        
        guard let tapFormat = currentEngineFormat, tapFormat.sampleRate > 0 else { return }
        let bufferSize: AVAudioFrameCount = selectedDSPMode == .yinFastHop ? 1024 : 2048

        if activeSource == .file {
            fileGainNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [weak self] buffer, _ in
                guard let self = self else { return }
                if let channelData = buffer.floatChannelData?[0] {
                    var rms: Float = 0.0
                    vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(buffer.frameLength))
                    DispatchQueue.main.async {
                        self.fileRMSLevel = rms
                        self.micRMSLevel = 0.0
                    }
                }
                self.dispatchBufferForAnalysis(buffer)
            }
        } else {
            micGainNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [weak self] buffer, _ in
                guard let self = self else { return }
                if let channelData = buffer.floatChannelData?[0] {
                    var rms: Float = 0.0
                    vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(buffer.frameLength))
                    DispatchQueue.main.async {
                        self.micRMSLevel = rms
                        self.fileRMSLevel = 0.0
                    }
                }
                self.dispatchBufferForAnalysis(buffer)
            }
        }
    }

    private func dispatchBufferForAnalysis(_ buffer: AVAudioPCMBuffer) {
        atomicQueue.async {
            guard !self.isProcessingBuffer else { return }
            self.isProcessingBuffer = true
            self.analysisQueue.async {
                self.processAudioBuffer(buffer)
                self.atomicQueue.async { self.isProcessingBuffer = false }
            }
        }
    }

    private func updateSpeakerOutput() {
        speakerMixerNode.outputVolume = isSpeakerEnabled ? 1.0 : 0.0
    }
    
    func toggleSpeaker() { isSpeakerEnabled.toggle() }
    
    func switchSource(to source: AudioSourceType) {
        activeSource = source
        engineQueue.async { [weak self] in self?.updateTapRouting() }
    }

    func loadAudioFile(url: URL) {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopAccessingCurrentURL()
            guard url.startAccessingSecurityScopedResource() else { return }
            self.activeSecurityURL = url

            do {
                let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(bookmarkData, forKey: "savedAudioBookmark")
                UserDefaults.standard.set(url.lastPathComponent, forKey: "savedAudioFileName")
            } catch { print("Erreur sauvegarde bookmark: \(error)") }

            do {
                let file = try AVAudioFile(forReading: url)
                self.audioFile = file
                let fileFormat = file.processingFormat
                
                let wasRunning = self.audioEngine.isRunning
                if wasRunning { self.audioEngine.stop() }
                
                self.audioEngine.disconnectNodeOutput(self.playerNode)
                self.audioEngine.connect(self.playerNode, to: self.fileGainNode, format: fileFormat)
                
                if wasRunning {
                    try self.audioEngine.start()
                }

                DispatchQueue.main.async {
                    self.audioFileName = url.lastPathComponent
                    self.duration = Double(file.length) / fileFormat.sampleRate
                    self.fileSampleRate = fileFormat.sampleRate
                    self.currentProgress = 0.0
                    self.seekFrameOffset = 0
                }
            } catch {
                print("Erreur Chargement Fichier: \(error)")
                self.stopAccessingCurrentURL()
            }
        }
    }

    private func restoreSavedAudioFile() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: "savedAudioBookmark") else { return }
        var isStale = false
        do {
            let recoveredURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if !isStale { loadAudioFile(url: recoveredURL) }
        } catch { print("Erreur résolution bookmark: \(error)") }
    }

    func playFile() {
        clearTunerDisplay()
        isFilePlaying = true
        activeSource = .file
        engineQueue.async { [weak self] in self?.updateTapRouting() }

        engineQueue.async { [weak self] in
            guard let self = self, let file = self.audioFile else { return }
            self.playbackSessionID += 1

            DispatchQueue.main.async {
                self.startUITimer()
                self.updateRoutingAndGains()
            }

            if !self.audioEngine.isRunning { try? self.audioEngine.start() }
            let startFrame = AVAudioFramePosition(self.currentProgress * file.processingFormat.sampleRate)
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
        stopUITimer()
        clearTunerDisplay()
        isFilePlaying = false
        activeSource = .microphone
        engineQueue.async { [weak self] in self?.updateTapRouting() }

        engineQueue.async { [weak self] in
            guard let self = self else { return }
            self.playbackSessionID += 1
            if self.playerNode.isPlaying { self.playerNode.pause() }
        }
    }

    func togglePlayPauseFile() { if isFilePlaying { pauseFile() } else { playFile() } }
    
    func stopFilePlayback() {
        pauseFile()
        seek(to: 0)
        activeSource = .microphone
        engineQueue.async { [weak self] in self?.updateTapRouting() }
    }
    
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
            }

            if wasPlaying {
                self.scheduleFile(startingFrom: framePosition, sessionID: currentSessionID)
                if self.audioEngine.isRunning { self.playerNode.play() }
            } else {
                self.seekFrameOffset = framePosition
            }
        }
    }

    func rewind5Seconds() { seek(to: currentProgress - 5.0) }
    func fastForward5Seconds() { seek(to: currentProgress + 5.0) }

    private func startUITimer() {
        uiTimer?.cancel()
        uiTimer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.isFilePlaying, let file = self.audioFile else { return }
                if let nodeTime = self.playerNode.lastRenderTime,
                   let playerTime = self.playerNode.playerTime(forNodeTime: nodeTime) {
                    let elapsedSeconds = Double(playerTime.sampleTime + self.seekFrameOffset) / file.processingFormat.sampleRate
                    if elapsedSeconds <= self.duration { self.currentProgress = elapsedSeconds }
                }
            }
    }

    private func stopUITimer() { uiTimer?.cancel(); uiTimer = nil }
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
        let n = buffer.count
        let halfN = n / 2
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
                vDSP_fft_zrip(doubleFFTSetup, &splitComplex, 1, log2FFT, 1)
                var magSq = [Float](repeating: 0.0, count: n)
                vDSP_zvmags(&splitComplex, 1, &magSq, 1, vDSP_Length(n))
                for i in 0..<n { realPtr[i] = magSq[i]; imagPtr[i] = 0.0 }
                vDSP_fft_zrip(doubleFFTSetup, &splitComplex, 1, log2FFT, -1)
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
        var diff = [Float](repeating: 0.0, count: halfN)

        buffer.withUnsafeBufferPointer { bufPtr in
            let base = bufPtr.baseAddress!
            for tau in 1..<halfN {
                vDSP_vsub(base + tau, 1, base, 1, &diff, 1, vDSP_Length(halfN))
                var sumSquare: Float = 0.0
                vDSP_svesq(diff, 1, &sumSquare, vDSP_Length(halfN))
                yinBuffer[tau] = sumSquare
            }
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

struct ResetGainSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let step: Float
    let accentColor: Color
    
    private func resetToZero() {
        DispatchQueue.main.async {
            self.value = 0.0
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(accentColor)
                Spacer()
                Text(String(format: "%+.1f dB", value))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(accentColor)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { resetToZero() }

            Slider(value: $value, in: range, step: step)
                .accentColor(accentColor)
                .simultaneousGesture(TapGesture(count: 2).onEnded { resetToZero() })
        }
    }
}

struct VerticalSourceSwitch: View {
    @Binding var activeSource: AudioSourceType
    let onToggle: (AudioSourceType) -> Void
    
    var body: some View {
        Button(action: {
            let nextSource: AudioSourceType = (activeSource == .microphone) ? .file : .microphone
            onToggle(nextSource)
        }) {
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 26, height: 50)
                
                Circle()
                    .fill(activeSource == .microphone ? Color.red : Color.green)
                    .frame(width: 22, height: 22)
                    .offset(y: activeSource == .microphone ? -12 : 12)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: activeSource)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct PetersonStrobeView: View {
    let centsDeviation: Float
    let isActive: Bool
    
    @State private var rotationAngle: Double = 0.0

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                let ringCount = 4

                for ring in 0..<ringCount {
                    let outerR = radius * CGFloat(ringCount - ring) / CGFloat(ringCount)
                    let innerR = radius * CGFloat(ringCount - ring - 1) / CGFloat(ringCount)
                    let segmentCount = 12 * (ring + 1)
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
            .onChange(of: timeline.date) { _ in
                if isActive && abs(centsDeviation) > 0.1 {
                    rotationAngle += Double(centsDeviation) * 0.15
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var tuner = AudioTunerEngine.shared
    @State private var isFileImporterPresented = false

    private func resetA4ToDefault() {
        DispatchQueue.main.async {
            tuner.referenceA4 = 440.0
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            #endif
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 4) {
                Text("POLYTUNE")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundColor(.yellow)
                    .padding(.top, 4)

                VStack(spacing: 4) {
                    HStack(alignment: .center, spacing: 10) {
                        VerticalSourceSwitch(activeSource: $tuner.activeSource) { newSource in
                            tuner.switchSource(to: newSource)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "mic.fill")
                                    .foregroundColor(tuner.activeSource == .microphone ? .red : .gray)
                                Text(String(format: "%.1fkHz", tuner.micSampleRate / 1000.0))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                                CapsuleMeter(level: tuner.micRMSLevel, color: .red)
                            }

                            HStack(spacing: 6) {
                                Image(systemName: "doc.fill")
                                    .foregroundColor(tuner.activeSource == .file ? .green : .gray)
                                Text(String(format: "%.1fkHz", tuner.fileSampleRate / 1000.0))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                                CapsuleMeter(level: tuner.fileRMSLevel, color: .green)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 3) {
                            Button(action: { tuner.toggleSpeaker() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: tuner.isSpeakerEnabled ? "speaker.wave.3.fill" : "speaker.slash.fill")
                                        .font(.system(size: 12, weight: .bold))
                                    Text("SPKR")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(tuner.isSpeakerEnabled ? Color.green.opacity(0.3) : Color.red.opacity(0.3))
                                .foregroundColor(tuner.isSpeakerEnabled ? .green : .red)
                                .cornerRadius(4)
                            }

                            if !tuner.audioFileName.isEmpty {
                                Text(tuner.audioFileName)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                                    .lineLimit(1)
                                    .frame(maxWidth: 120, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.horizontal)

                    HStack {
                        Text("DSP:")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)

                        Picker("", selection: $tuner.selectedDSPMode) {
                            ForEach(DSPMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .frame(width: 150)
                    }
                    .padding(.horizontal)

                    ZStack {
                        PetersonStrobeView(centsDeviation: tuner.centsDeviation, isActive: tuner.frequency > 0)
                            .frame(width: 180, height: 180)

                        Circle()
                            .fill(Color.black.opacity(0.40))
                            .frame(width: 115, height: 115)

                        VStack(spacing: 0) {
                            Text(tuner.noteName)
                                .font(.system(size: 48, weight: .black, design: .rounded))
                                .foregroundColor(.yellow)

                            Text(tuner.frequency > 0 ? String(format: "%.1f Hz", tuner.frequency) : "--- Hz")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(.yellow)
                        }
                    }
                    .frame(height: 185)

                    VStack(spacing: 2) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 260, height: 10)

                            Rectangle()
                                .fill(Color.yellow)
                                .frame(width: 2, height: 16)

                            Circle()
                                .fill(abs(tuner.centsDeviation) < 5 ? Color.green : Color.orange)
                                .frame(width: 12, height: 12)
                                .offset(x: CGFloat(max(-120, min(120, tuner.centsDeviation * 2.4))))
                        }

                        HStack {
                            Text("-50ct").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.yellow)
                            Spacer()
                            Text("0").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.yellow)
                            Spacer()
                            Text("+50ct").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.yellow)
                        }
                        .frame(width: 260)
                    }
                }

                Spacer(minLength: 2)

                HStack(spacing: 20) {
                    Button(action: { tuner.referenceA4 -= 1.0 }) { Image(systemName: "minus.square").foregroundColor(.yellow) }
                    Text("A4: \(Int(tuner.referenceA4)) Hz")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.yellow)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { resetA4ToDefault() }
                    Button(action: { tuner.referenceA4 += 1.0 }) { Image(systemName: "plus.square").foregroundColor(.yellow) }
                }

                VStack(spacing: 4) {
                    if tuner.activeSource == .file {
                        ResetGainSlider(title: "FILE VOLUME", value: $tuner.fileGain, range: -40...40, step: 0.5, accentColor: .green)
                    } else {
                        ResetGainSlider(title: "MIC GAIN", value: $tuner.micGain, range: -40...40, step: 0.5, accentColor: .yellow)
                    }
                }
                .padding(.horizontal, 20)

                if tuner.duration > 0 {
                    VStack(spacing: 0) {
                        Slider(value: Binding(get: { tuner.currentProgress }, set: { tuner.seek(to: $0) }), in: 0...tuner.duration)
                            .accentColor(.green)
                        HStack {
                            Text(formatTime(tuner.currentProgress))
                            Spacer()
                            Text(formatTime(tuner.duration))
                        }
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.yellow)
                    }
                    .padding(.horizontal, 20)
                }

                HStack(spacing: 8) {
                    ProToolsButton(icon: "backward.fill") { tuner.rewind5Seconds() }
                    ProToolsButton(icon: tuner.isFilePlaying ? "pause.fill" : "play.fill", isActive: tuner.isFilePlaying, activeColor: .green) { tuner.togglePlayPauseFile() }
                    ProToolsButton(icon: "square.fill", activeColor: .red) { tuner.stopFilePlayback() }
                    ProToolsButton(icon: "forward.fill") { tuner.fastForward5Seconds() }
                    ProToolsButton(icon: tuner.isLooping ? "repeat.circle.fill" : "repeat", isActive: tuner.isLooping, activeColor: .green) { tuner.toggleLoop() }
                    ProToolsButton(icon: "doc.badge.plus", activeColor: .blue) { isFileImporterPresented = true }
                }
                .padding(.bottom, 6)
            }
        }
        .onAppear { tuner.startEngineIfNeeded() }
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { tuner.loadAudioFile(url: url) }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct CapsuleMeter: View {
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
            .cornerRadius(2)
        }
        .frame(width: 50, height: 8)
    }
}

struct ProToolsButton: View {
    let icon: String
    var isActive: Bool = false
    var activeColor: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(isActive ? activeColor : .yellow)
                .frame(width: 40, height: 34)
                .background(Color.white.opacity(0.1))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(isActive ? activeColor : Color.yellow.opacity(0.3), lineWidth: 1))
        }
    }
}

