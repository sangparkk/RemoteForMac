import SwiftUI
import AVFoundation

struct QRScanner: UIViewControllerRepresentable {
    var scanned: (String) -> Void
    var failed: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.scanned = scanned; controller.failed = failed
        return controller
    }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) { }
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var scanned: ((String) -> Void)?
    var failed: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "remotetv.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private var stopped = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else { self.failed?("설정에서 카메라 접근을 허용하거나 연결 정보를 직접 붙여넣으세요."); return }
                self.configure()
            }
        }
    }
    private func configure() {
        guard !stopped else { return }
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            failed?("카메라를 사용할 수 없습니다. 연결 정보를 직접 붙여넣으세요."); return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { failed?("QR 인식을 시작할 수 없습니다."); return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        self.preview = preview
        view.layer.addSublayer(preview)
        preview.frame = view.bounds
        queue.async { [session] in session.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { stopped = true; queue.async { [session] in session.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue, value.hasPrefix("remotetv:") else { return }
        delivered = true; stop(); scanned?(value)
    }
}
