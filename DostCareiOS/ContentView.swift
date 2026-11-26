import SwiftUI
import AVFoundation
import Vision
import AudioToolbox

struct MedItem: Identifiable, Codable {
    var id: String = UUID().uuidString
    var name: String
    var time: String
    var doseTimes: String
    var foodCode: String
    var days: Int
    var dailyCount: Int
    var barcode: String
    var photoName: String
    var rx: String
    var taken: Bool
    var lastAlertDate: String
    var lastTakenDate: String
}

struct BarcodeCatalogEntry: Codable {
    var code: String
    var name: String
    var defaultTime: String
    var foodCode: String
    var dailyCount: Int
    var days: Int
    var rx: String
}

struct AppStateData: Codable {
    var lang: String
    var voiceMuted: Bool
    var accessibleMode: Bool
    var patientName: String
    var patientAge: String
    var emergencyContact: String
    var meds: [MedItem]
    var logs: [String]
    var compNotes: [String]
}

enum SafetyNotice {
    static func text(for lang: String) -> String {
        switch lang {
        case "DE":
            return "WICHTIGER HINWEIS: Dieses Programm kann hängenbleiben, verzögern oder Fehler machen. Prüfen Sie jede Angabe, Dosis, Uhrzeit und jedes Rezept stets gegen das Rezept Ihres Arztes."
        case "EN":
            return "IMPORTANT NOTICE: This software may freeze, delay, or make errors. Always verify every detail, dose, time, and prescription against the prescription given by your doctor."
        default:
            return "ÖNEMLİ UYARI: Bu program da takılabilir, gecikebilir veya hata yapabilir. Her bilgiyi, dozu, saati ve reçeteyi mutlaka doktorunuzun verdiği reçete ile karşılaştırıp doğrulayın."
        }
    }
}

final class SpeechHelper: NSObject, ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, lang: String, muted: Bool) {
        synthesizer.stopSpeaking(at: .immediate)
        guard !muted, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: lang == "DE" ? "de-DE" : (lang == "EN" ? "en-US" : "tr-TR"))
        utterance.rate = 0.43
        synthesizer.speak(utterance)
    }

    func playAlertChime() {
        AudioServicesPlayAlertSound(1005)
    }
}

final class CameraBarcodeController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureMetadataOutputObjectsDelegate {
    @Published var isAuthorized: Bool = false
    @Published var statusText: String = ""
    @Published var capturedImage: UIImage?
    @Published var detectedCode: String = ""
    @Published var lastPhotoName: String = ""

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let sessionQueue = DispatchQueue(label: "DostCare.CameraQueue")
    private var onCodeFound: ((String) -> Void)?

    func checkAndStart(onCode: @escaping (String) -> Void) {
        self.onCodeFound = onCode
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { self.isAuthorized = true }
            configureSessionIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.isAuthorized = granted
                    if granted {
                        self.configureSessionIfNeeded()
                    } else {
                        self.statusText = "Kamera izni verilmedi. Barkod kodu girebilir veya fotoğraf seçebilirsiniz."
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                self.isAuthorized = false
                self.statusText = "Kamera kapalı. Ayarlar'dan izin verebilir veya barkod/fotoğraf kullanabilirsiniz."
            }
        }
    }

    private func configureSessionIfNeeded() {
        sessionQueue.async {
            if !self.session.inputs.isEmpty {
                if !self.session.isRunning { self.session.startRunning() }
                return
            }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.statusText = "Kamera algılanamadı, barkod ve görsel modu aktif."
                }
                return
            }
            self.session.addInput(input)
            if self.session.canAddPhotoOutput() {
                self.session.addPhotoOutput(self.photoOutput)
            }
            if self.session.canAddMetadataOutput() {
                self.session.addMetadataOutput(self.metadataOutput)
                self.metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                self.metadataOutput.metadataObjectTypes = [.ean13, .ean8, .code128, .qr, .dataMatrix]
            }
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async {
                self.statusText = "iPhone kamera aktif — barkod okutabilir veya fotoğraf çekebilirsiniz."
            }
        }
    }

    func stopSession() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func capturePhoto() {
        sessionQueue.async {
            let settings = AVCapturePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func usePickedImage(_ image: UIImage, fileHint: String) {
        DispatchQueue.main.async {
            self.capturedImage = image
            self.saveImageToDocuments(image)
            self.detectBarcodeInImage(image, fallbackHint: fileHint)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let uiImg = UIImage(data: data) else { return }
        DispatchQueue.main.async {
            self.capturedImage = uiImg
            self.saveImageToDocuments(uiImg)
            self.detectBarcodeInImage(uiImg, fallbackHint: "")
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        for obj in metadataObjects {
            if let readable = obj as? AVMetadataMachineReadableCodeObject,
               let val = readable.stringValue, !val.isEmpty {
                DispatchQueue.main.async {
                    self.detectedCode = val
                    self.statusText = "Barkod okundu: \(val)"
                    self.onCodeFound?(val)
                }
                break
            }
        }
    }

    private func detectBarcodeInImage(_ image: UIImage, fallbackHint: String) {
        guard let cgImg = image.cgImage else { return }
        let request = VNDetectBarcodesRequest { req, _ in
            DispatchQueue.main.async {
                if let first = (req.results as? [VNBarcodeObservation])?.first,
                   let payload = first.payloadStringValue, !payload.isEmpty {
                    self.detectedCode = payload
                    self.statusText = "Fotoğraftan barkod okundu: \(payload)"
                    self.onCodeFound?(payload)
                } else if !fallbackHint.isEmpty {
                    self.detectedCode = fallbackHint
                    self.statusText = "Fotoğraf kaydedildi, kod algılandı: \(fallbackHint)"
                    self.onCodeFound?(fallbackHint)
                } else {
                    self.statusText = "Kutu/görsel fotoğrafı kaydedildi. Barkod kodunu kontrol edebilirsiniz."
                }
            }
        }
        let handler = VNImageRequestHandler(cgImage: cgImg, options: [:])
        try? handler.perform([request])
    }

    private func saveImageToDocuments(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("DostCareCaptures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fname = "med_\(Int(Date().timeIntervalSince1970)).jpg"
        let url = dir.appendingPathComponent(fname)
        try? data.write(to: url)
        lastPhotoName = fname
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        v.layer.addSublayer(layer)
        context.coordinator.previewLayer = layer
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.previewLayer?.frame = uiView.bounds
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var previewLayer: AVCaptureVideoPreviewLayer? }
}

struct PhotoPickerView: UIViewControllerRepresentable {
    var onPick: (UIImage, String) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .photoLibrary
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage, String) -> Void
        init(onPick: @escaping (UIImage, String) -> Void) { self.onPick = onPick }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let img = (info[.originalImage] as? UIImage) ?? UIImage()
            let title = (info[.imageURL] as? URL)?.deletingPathExtension().lastPathComponent ?? ""
            onPick(img, title)
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

struct ContentView: View {
    @StateObject private var speaker = SpeechHelper()
    @StateObject private var cam = CameraBarcodeController()

    @State private var lang = "TR"
    @State private var voiceMuted = false
    @State private var accessibleMode = true
    @State private var selectedTab = 0

    @State private var patientName = "Hasta"
    @State private var patientAge = ""
    @State private var emergencyContact = ""

    @State private var meds: [MedItem] = [
        MedItem(name: "Coraspin 100 mg", time: "09:15", doseTimes: "09:15", foodCode: "FED", days: 30, dailyCount: 1, barcode: "8699546010014", photoName: "", rx: "E-Reçete #DC101", taken: false, lastAlertDate: "", lastTakenDate: ""),
        MedItem(name: "Pantoprazol 40 mg", time: "08:00", doseTimes: "08:00, 20:00", foodCode: "FASTING", days: 30, dailyCount: 2, barcode: "8699546020020", photoName: "", rx: "E-Reçete #DC102", taken: false, lastAlertDate: "", lastTakenDate: "")
    ]
    @State private var logs: [String] = []
    @State private var compNotes: [String] = []

    @State private var medName = "Coraspin 100 mg"
    @State private var medTimes = "09:15"
    @State private var medFood = "FED"
    @State private var medDays = "14"
    @State private var medRx = "E-Reçete #DC101"
    @State private var editingIndex: Int? = nil

    @State private var showScannerSheet = false
    @State private var showPhotoPicker = false
    @State private var barcodeInput = "8699546010014"
    @State private var scanDailyCount = 1
    @State private var scanResultText = ""

    @State private var logCat = "Tansiyon & Nabız"
    @State private var logVal = ""
    @State private var logNote = ""

    @State private var compType = "Olağandışı Durum"
    @State private var compBy = "Refakatçi"
    @State private var compText = ""

    @State private var showProfileSheet = false
    @State private var activeAlarmMed: MedItem? = nil
    @State private var alertBannerText: String? = nil

    private let catalog: [String: BarcodeCatalogEntry] = [
        "8699546010014": BarcodeCatalogEntry(code: "8699546010014", name: "Coraspin 100 mg", defaultTime: "09:15", foodCode: "FED", dailyCount: 1, days: 30, rx: "E-Reçete #DC101"),
        "8699546020020": BarcodeCatalogEntry(code: "8699546020020", name: "Pantoprazol 40 mg", defaultTime: "08:00, 20:00", foodCode: "FASTING", dailyCount: 2, days: 30, rx: "E-Reçete #DC102"),
        "8699546030036": BarcodeCatalogEntry(code: "8699546030036", name: "Parol 500 mg", defaultTime: "08:00, 14:00, 20:00", foodCode: "FED", dailyCount: 3, days: 20, rx: "E-Reçete #DC103")
    ]

    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var saveURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("dostcare_ios_data.json")
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dost Çare")
                            .font(.system(size: accessibleMode ? 22 : 18, weight: .bold))
                            .foregroundColor(.white)
                        Text("\(patientName)\(patientAge.isEmpty ? "" : " (\(patientAge))")")
                            .font(.system(size: accessibleMode ? 14 : 12, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.9))
                    }
                    Spacer()
                    Picker("Lang", selection: $lang) {
                        Text("TR").tag("TR")
                        Text("DE").tag("DE")
                        Text("EN").tag("EN")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                    .onChange(of: lang) { _ in persist() }
                }
                .padding()
                .background(Color(red: 0.06, green: 0.46, blue: 0.43))

                HStack(spacing: 8) {
                    Button(action: {
                        voiceMuted.toggle()
                        persist()
                        if !voiceMuted { speaker.speak("Ses aktif", lang: lang, muted: false) }
                    }) {
                        Text(voiceMuted ? "Ses: KAPALI" : "Ses: AÇIK")
                            .font(.system(size: accessibleMode ? 14 : 12, weight: .bold))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(voiceMuted ? Color.orange : Color.green)
                            .foregroundColor(.white).cornerRadius(8)
                    }

                    Button(action: {
                        accessibleMode.toggle()
                        persist()
                    }) {
                        Text(accessibleMode ? "Büyük Yazı: AÇIK" : "Büyük Yazı: STD")
                            .font(.system(size: accessibleMode ? 14 : 12, weight: .bold))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.blue)
                            .foregroundColor(.white).cornerRadius(8)
                    }

                    Button(action: { speakSummary() }) {
                        Text("Gün Özeti")
                            .font(.system(size: accessibleMode ? 14 : 12, weight: .bold))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.purple)
                            .foregroundColor(.white).cornerRadius(8)
                    }

                    Spacer()

                    Button(action: { showProfileSheet = true }) {
                        Text("Profil")
                            .font(.system(size: accessibleMode ? 14 : 12, weight: .bold))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.teal)
                            .foregroundColor(.white).cornerRadius(8)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))

                Picker("", selection: $selectedTab) {
                    Text("İlaç & Alarm").tag(0)
                    Text("Sağlık Kaydı").tag(1)
                    Text("Refakatçi").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)

                if selectedTab == 0 {
                    medsTab
                } else if selectedTab == 1 {
                    logsTab
                } else {
                    companionTab
                }

                Text(SafetyNotice.text(for: lang))
                    .font(.system(size: accessibleMode ? 13 : 11, weight: .bold))
                    .foregroundColor(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.10))
            }
            .navigationBarHidden(true)
            .onAppear {
                loadSaved()
                checkDueAlarms()
            }
            .onReceive(timer) { _ in
                checkDueAlarms()
            }
            .sheet(isPresented: $showScannerSheet) {
                scannerSheet
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPickerView { img, hint in
                    cam.usePickedImage(img, fileHint: hint)
                }
            }
            .sheet(isPresented: $showProfileSheet) {
                profileSheet
            }
            .alert(item: $activeAlarmMed) { item in
                Alert(
                    title: Text("İLAÇ VAKTİ — \(item.name)"),
                    message: Text("Saat: \(item.doseTimes) | Günde \(item.dailyCount)x | \(foodLabel(item.foodCode))\n\n\(SafetyNotice.text(for: lang))"),
                    primaryButton: .default(Text("İlacı İçtim")) {
                        toggleTaken(id: item.id, forceTaken: true)
                    },
                    secondaryButton: .cancel(Text("5 Dakika Ertele")) {
                        snoozeMed(id: item.id)
                    }
                )
            }
            .alert(item: Binding(
                get: { alertBannerText.map { AlertMsg(text: $0) } },
                set: { alertBannerText = $0?.text }
            )) { msg in
                Alert(title: Text("Uyarı"), message: Text(msg.text), dismissButton: .default(Text("Tamam")))
            }
        }
    }

    private var medsTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Button(action: {
                        showScannerSheet = true
                        cam.checkAndStart { code in
                            barcodeInput = code
                            applyBarcodeCode(code)
                        }
                    }) {
                        Label("Kamera / Barkod", systemImage: "barcode.viewfinder")
                            .font(.system(size: accessibleMode ? 16 : 14, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.teal)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }

                    Button(action: {
                        let sample = meds.first ?? MedItem(name: "Coraspin 100 mg", time: "09:15", doseTimes: "09:15", foodCode: "FED", days: 14, dailyCount: 1, barcode: "", photoName: "", rx: "", taken: false, lastAlertDate: "", lastTakenDate: "")
                        speaker.playAlertChime()
                        speaker.speak(alarmScript(sample, isTest: true), lang: lang, muted: voiceMuted)
                        activeAlarmMed = sample
                    }) {
                        Label("Test Alarm", systemImage: "alarm")
                            .font(.system(size: accessibleMode ? 16 : 14, weight: .bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }

                ForEach(Array(meds.enumerated()), id: \.element.id) { idx, m in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(m.name)
                                .font(.system(size: accessibleMode ? 19 : 16, weight: .bold))
                            Spacer()
                            Text(m.taken ? "İÇİLDİ" : "BEKLİYOR")
                                .font(.system(size: accessibleMode ? 14 : 12, weight: .bold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(m.taken ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                                .foregroundColor(m.taken ? .green : .orange)
                                .cornerRadius(6)
                        }
                        Text("Saat(ler): \(m.doseTimes) • Günde \(m.dailyCount)x • \(foodLabel(m.foodCode))")
                            .font(.system(size: accessibleMode ? 15 : 13))
                        HStack {
                            Text("Kalan: \(m.days) Gün • \(m.rx)\(m.days <= 3 ? " • REÇETE YENİLE" : "")")
                                .font(.system(size: accessibleMode ? 14 : 12, weight: m.days <= 3 ? .bold : .regular))
                                .foregroundColor(m.days <= 3 ? .red : .secondary)
                            Spacer()
                        }
                        HStack(spacing: 8) {
                            Button(m.taken ? "Geri Al" : "İçildi") {
                                toggleTaken(id: m.id, forceTaken: nil)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)

                            Button("Düzenle") {
                                editingIndex = idx
                                medName = m.name
                                medTimes = m.doseTimes
                                medFood = m.foodCode
                                medDays = "\(m.days)"
                                medRx = m.rx
                            }
                            .buttonStyle(.bordered)

                            Button("Sil") {
                                meds.removeAll { $0.id == m.id }
                                persist()
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(editingIndex == nil ? "Yeni İlaç Ekle" : "İlacı Düzenle")
                        .font(.system(size: accessibleMode ? 18 : 15, weight: .bold))
                    TextField("İlaç Adı", text: $medName).textFieldStyle(.roundedBorder)
                    TextField("Saat(ler) (örn. 08:00, 20:00)", text: $medTimes).textFieldStyle(.roundedBorder)
                    Picker("Aç / Tok", selection: $medFood) {
                        Text("Tok Karnına").tag("FED")
                        Text("Aç Karnına").tag("FASTING")
                        Text("Yemekle Birlikte").tag("WITH_MEAL")
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        TextField("Gün", text: $medDays).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        TextField("Reçete", text: $medRx).textFieldStyle(.roundedBorder)
                    }
                    Button(editingIndex == nil ? "Listeye Ekle" : "Değişikliği Kaydet") {
                        saveMedForm()
                    }
                    .font(.system(size: accessibleMode ? 17 : 15, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(red: 0.06, green: 0.46, blue: 0.43))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }
            .padding()
        }
    }

    private var logsTab: some View {
        VStack(spacing: 10) {
            Picker("Çizelge", selection: $logCat) {
                Text("Tansiyon").tag("Tansiyon & Nabız")
                Text("Şeker").tag("Diyabet")
                Text("Migren").tag("Migren Atağı")
                Text("Nefes/SpO2").tag("Nefes / SpO2")
            }
            .pickerStyle(.segmented)
            TextField("Ölçüm / Değer (örn. 135/85)", text: $logVal).textFieldStyle(.roundedBorder)
            TextField("Not", text: $logNote).textFieldStyle(.roundedBorder)
            Button("Kaydı Ekle") {
                guard !logVal.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                let entry = "[\(nowStamp())] \(logCat) -> \(logVal.trim()) | \(logNote.trim())"
                logs.insert(entry, at: 0)
                checkCriticalReading(val: logVal.trim())
                logVal = ""; logNote = ""
                persist()
            }
            .font(.system(size: accessibleMode ? 16 : 14, weight: .bold))
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(Color.blue).foregroundColor(.white).cornerRadius(10)

            List(logs, id: \.self) { row in
                Text(row).font(.system(size: accessibleMode ? 15 : 13))
            }
        }
        .padding()
    }

    private var companionTab: some View {
        VStack(spacing: 10) {
            Picker("Durum", selection: $compType) {
                Text("Olağandışı").tag("Olağandışı Durum")
                Text("Belirti").tag("Belirti / Yan Etki")
                Text("Gecikme").tag("İlaç Gecikmesi")
                Text("Doktor Sorusu").tag("Doktor Sorusu")
            }
            .pickerStyle(.segmented)
            Picker("Kaydeden", selection: $compBy) {
                Text("Refakatçi").tag("Refakatçi")
                Text("Hasta").tag("Hasta")
            }
            .pickerStyle(.segmented)
            TextField("Refakatçi / Doktor Notu", text: $compText).textFieldStyle(.roundedBorder)
            Button("Notu Kaydet") {
                guard !compText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                compNotes.insert("[\(nowStamp()) | \(compBy)] \(compType): \(compText.trim())", at: 0)
                compText = ""
                persist()
            }
            .font(.system(size: accessibleMode ? 16 : 14, weight: .bold))
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(Color(red: 0.06, green: 0.46, blue: 0.43)).foregroundColor(.white).cornerRadius(10)

            List(compNotes, id: \.self) { row in
                Text(row).font(.system(size: accessibleMode ? 15 : 13))
            }
        }
        .padding()
    }

    private var scannerSheet: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    if cam.isAuthorized {
                        CameraPreviewView(session: cam.session)
                            .frame(height: 210)
                            .cornerRadius(12)
                    } else if let img = cam.capturedImage {
                        Image(uiImage: img)
                            .resizable().scaledToFit()
                            .frame(height: 210)
                            .cornerRadius(12)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.85))
                            .frame(height: 180)
                            .overlay(Text("Kamera önizleme kapalı\nBarkod yazın veya fotoğraf seçin").foregroundColor(.white).multilineTextAlignment(.center))
                    }

                    Text(cam.statusText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.teal)

                    HStack(spacing: 8) {
                        Button("Fotoğraf Çek") { cam.capturePhoto() }.buttonStyle(.borderedProminent).tint(.teal)
                        Button("Fotoğraf Seç") { showPhotoPicker = true }.buttonStyle(.bordered)
                    }

                    HStack {
                        TextField("Barkod / İlaç Kodu", text: $barcodeInput).textFieldStyle(.roundedBorder)
                        Button("Tanımla") { applyBarcodeCode(barcodeInput) }.buttonStyle(.borderedProminent)
                    }

                    Stepper("Günde Kaç Kez: \(scanDailyCount) kez", value: $scanDailyCount, in: 1...4)

                    TextField("İlaç Adı", text: $medName).textFieldStyle(.roundedBorder)
                    TextField("Saat(ler)", text: $medTimes).textFieldStyle(.roundedBorder)

                    if !scanResultText.isEmpty {
                        Text(scanResultText).font(.system(size: 14, weight: .bold)).foregroundColor(.green)
                    }

                    Text(SafetyNotice.text(for: lang))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.red)
                        .padding(8)
                        .background(Color.red.opacity(0.10))
                        .cornerRadius(8)

                    Button("Forma Aktar") {
                        let d = Int(medDays) ?? 30
                        let item = MedItem(
                            name: medName.trimmingCharacters(in: .whitespaces),
                            time: medTimes.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? "09:00",
                            doseTimes: medTimes.trimmingCharacters(in: .whitespaces),
                            foodCode: medFood,
                            days: max(0, d),
                            dailyCount: scanDailyCount,
                            barcode: barcodeInput.trimmingCharacters(in: .whitespaces),
                            photoName: cam.lastPhotoName,
                            rx: medRx,
                            taken: false,
                            lastAlertDate: "",
                            lastTakenDate: ""
                        )
                        if !item.name.isEmpty {
                            meds.append(item)
                            persist()
                        }
                        cam.stopSession()
                        showScannerSheet = false
                    }
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color.green).foregroundColor(.white).cornerRadius(10)
                }
                .padding()
            }
            .navigationTitle("Kamera & Barkod")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") {
                        cam.stopSession()
                        showScannerSheet = false
                    }
                }
            }
        }
    }

    private var profileSheet: some View {
        NavigationView {
            Form {
                Section("Hasta & Acil Yakını") {
                    TextField("Adı Soyadı", text: $patientName)
                    TextField("Yaşı", text: $patientAge)
                    TextField("Acil Yakını", text: $emergencyContact)
                }
                Section("Uyarı") {
                    Text(SafetyNotice.text(for: lang))
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
            .navigationTitle("Profil")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        persist()
                        showProfileSheet = false
                    }
                }
            }
        }
    }

    private func applyBarcodeCode(_ raw: String) {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        if let hit = catalog[code] {
            medName = hit.name
            scanDailyCount = hit.dailyCount
            medTimes = hit.defaultTime
            medFood = hit.foodCode
            medDays = "\(hit.days)"
            medRx = hit.rx
            scanResultText = "Tanındı: \(hit.name) — Günde \(hit.dailyCount) kez"
        } else {
            let cnt = code.hasSuffix("3") ? 3 : (code.hasSuffix("2") ? 2 : 1)
            scanDailyCount = cnt
            if medName.trimmingCharacters(in: .whitespaces).isEmpty { medName = "İlaç (\(code))" }
            scanResultText = "Kod okundu: Günde \(cnt) kez"
        }
    }

    private func saveMedForm() {
        let cleanName = medName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let parts = medTimes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let sched = parts.isEmpty ? "09:00" : parts.joined(separator: ", ")
        let primary = parts.first ?? "09:00"
        let daysVal = max(0, Int(medDays) ?? 14)
        let dailyVal = max(1, parts.count)

        if let idx = editingIndex, idx < meds.count {
            meds[idx].name = cleanName
            meds[idx].time = primary
            meds[idx].doseTimes = sched
            meds[idx].foodCode = medFood
            meds[idx].days = daysVal
            meds[idx].dailyCount = dailyVal
            meds[idx].rx = medRx
            editingIndex = nil
        } else {
            meds.append(MedItem(name: cleanName, time: primary, doseTimes: sched, foodCode: medFood, days: daysVal, dailyCount: dailyVal, barcode: barcodeInput, photoName: cam.lastPhotoName, rx: medRx, taken: false, lastAlertDate: "", lastTakenDate: ""))
        }
        persist()
        speaker.speak("\(cleanName) kaydedildi.", lang: lang, muted: voiceMuted)
    }

    private func toggleTaken(id: String, forceTaken: Bool?) {
        guard let idx = meds.firstIndex(where: { $0.id == id }) else { return }
        let today = dayStamp()
        let nextTaken = forceTaken ?? !meds[idx].taken
        if nextTaken && !meds[idx].taken {
            meds[idx].taken = true
            if meds[idx].lastTakenDate != today {
                meds[idx].lastTakenDate = today
                if meds[idx].days > 0 { meds[idx].days -= 1 }
            }
        } else if !nextTaken && meds[idx].taken {
            meds[idx].taken = false
            if meds[idx].lastTakenDate == today {
                meds[idx].lastTakenDate = ""
                meds[idx].days += 1
            }
        }
        persist()
    }

    private func snoozeMed(id: String) {
        guard let idx = meds.firstIndex(where: { $0.id == id }) else { return }
        let snoozeDate = Date().addingTimeInterval(300)
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let s = f.string(from: snoozeDate)
        meds[idx].time = s
        meds[idx].doseTimes = s
        meds[idx].lastAlertDate = ""
        persist()
    }

    private func checkDueAlarms() {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let hhmm = f.string(from: Date())
        let td = dayStamp()
        for idx in meds.indices {
            if meds[idx].taken || meds[idx].lastAlertDate == td { continue }
            let slots = meds[idx].doseTimes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if slots.contains(hhmm) {
                meds[idx].lastAlertDate = td
                persist()
                speaker.playAlertChime()
                speaker.speak(alarmScript(meds[idx], isTest: false), lang: lang, muted: voiceMuted)
                activeAlarmMed = meds[idx]
                break
            }
        }
    }

    private func checkCriticalReading(val: String) {
        let nums = val.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        if let first = nums.first, first >= 160 || first >= 250 {
            alertBannerText = "Kritik değer girildi: \(val)\nAcil yakın: \(emergencyContact)\n\n\(SafetyNotice.text(for: lang))"
        }
    }

    private func speakSummary() {
        let takenCount = meds.filter { $0.taken }.count
        let txt = "Bugün \(meds.count) ilaçtan \(takenCount) tanesi içildi. \(SafetyNotice.text(for: lang))"
        speaker.speak(txt, lang: lang, muted: voiceMuted)
        alertBannerText = txt
    }

    private func alarmScript(_ m: MedItem, isTest: Bool) -> String {
        let prefix = isTest ? "Test uyarısı. " : "Dikkat, ilaç vaktiniz geldi. "
        return "\(prefix)İlaç adı: \(m.name). Günde \(m.dailyCount) kez. Kullanım şekli: \(foodLabel(m.foodCode)). Saat \(m.doseTimes). Lütfen doktorunuzun verdiği reçete ile karşılaştırın."
    }

    private func foodLabel(_ code: String) -> String {
        code == "FASTING" ? "Aç Karnına" : (code == "WITH_MEAL" ? "Yemekle Birlikte" : "Tok Karnına")
    }

    private func nowStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm"; return f.string(from: Date())
    }

    private func dayStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    private func persist() {
        let state = AppStateData(lang: lang, voiceMuted: voiceMuted, accessibleMode: accessibleMode, patientName: patientName, patientAge: patientAge, emergencyContact: emergencyContact, meds: meds, logs: logs, compNotes: compNotes)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: saveURL)
        }
    }

    private func loadSaved() {
        guard let data = try? Data(contentsOf: saveURL),
              let state = try? JSONDecoder().decode(AppStateData.self, from: data) else { return }
        lang = state.lang; voiceMuted = state.voiceMuted; accessibleMode = state.accessibleMode
        patientName = state.patientName; patientAge = state.patientAge; emergencyContact = state.emergencyContact
        meds = state.meds; logs = state.logs; compNotes = state.compNotes
    }
}

private struct AlertMsg: Identifiable {
    let id = UUID()
    let text: String
}
