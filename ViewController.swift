import UIKit
import Vision
import AVFoundation
import CoreMedia

class ViewController: UIViewController,AVCaptureVideoDataOutputSampleBufferDelegate, UIGestureRecognizerDelegate  {
  @IBOutlet weak var videoPreview: UIView!
  @IBOutlet weak var timeLabel: UILabel!
  @IBOutlet weak var debugImageView: UIImageView!
    
    
   //var pinchGesture  = UIPinchGestureRecognizer()
    //private var baseZoomFanctor: CGFloat = 1.0
    
    
    
    // true: use Vision to drive Core ML, false: use plain Core ML
    
    let useVision = false

  // Disable this to see the energy impact of just running the neural net,
  // otherwise it also counts the GPU activity of drawing the bounding boxes.
  let drawBoundingBoxes = true

  // How many predictions we can do concurrently.
  static let maxInflightBuffers = 3

  let yolo = YOLO()

  var videoCapture: VideoCapture!
    
    //VNCoreMLRequest: CoreMLの画像解析リクエスト
  var requests = [VNCoreMLRequest]()
  var startTimes: [CFTimeInterval] = []

  var boundingBoxes = [BoundingBox]()
  var colors: [UIColor] = []
    
    //CIContext(): 画像処理結果をレンダリングし、画像解析を実行するための評価コンテキスト。
  let ciContext = CIContext()
  var resizedPixelBuffers: [CVPixelBuffer?] = []

  var framesDone = 0
  var frameCapturingStartTime = CACurrentMediaTime()

  var inflightBuffer = 0
    //非同期処理を同期的なメソッドと同じような書き方で処理したい場合に使うやつ
  let semaphore = DispatchSemaphore(value: ViewController.maxInflightBuffers)
    
    
    let focusView = UIView()
    var oldZoomScale: CGFloat = 1.0


  override func viewDidLoad() {
    super.viewDidLoad()
    
    
    
   
    
    let tapGesture:UITapGestureRecognizer = UITapGestureRecognizer(
        target: self,
        action: #selector(self.tappedScreen(gestureRecognizer:)))
    
    // デリゲートをセット
    tapGesture.delegate = self as? UIGestureRecognizerDelegate
    
    self.view.addGestureRecognizer(tapGesture)
    
    
    
    

    timeLabel.text = ""
    
    

    setUpBoundingBoxes()
    setUpCoreImage()
    setUpVision()
    setUpCamera()
    
    frameCapturingStartTime = CACurrentMediaTime()
    
    let pinchGesture = UIPinchGestureRecognizer(target: self.videoCapture, action: #selector(self.videoCapture.pinchedGesture(gestureRecgnizer:)))
    
    //self.view.isUserInteractionEnabled = true
    self.view.addGestureRecognizer(pinchGesture)
    
    
    
    // PINCH Gesture
       //pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(ViewController.pinchedView))
    //videoPreview.isUserInteractionEnabled = true
       //videoPreview.addGestureRecognizer(pinchGesture)
    
    
    
  }

  override func didReceiveMemoryWarning() {
    super.didReceiveMemoryWarning()
    print(#function)
  }
    
    
    //@objc func pinchedView(sender:UIPinchGestureRecognizer){
        //self.view.bringSubviewToFront(videoPreview)
        //sender.view?.transform = (sender.view?.transform)!.scaledBy(x: sender.scale, y: sender.scale)
        //sender.scale = 1.0
        
        //let g = (videoCapture.setUpCamera(sessionPreset: AVCaptureSession.Preset) as AnyObject).captureDevice
        
        //guard let device = videoCapture else { return }

        //if sender.state == .changed {

            //let maxZoomFactor = device.activeFormat.videoMaxZoomFactor
            //let pinchVelocityDividerFactor: CGFloat = 5.0

            //do {

                //try device.lockForConfiguration()
                //defer { device.unlockForConfiguration() }

                //let desiredZoomFactor = device.videoZoomFactor + atan2(sender.velocity, pinchVelocityDividerFactor)
                //device.videoZoomFactor = max(1.0, min(desiredZoomFactor, maxZoomFactor))

            //} catch {
                //print(error)
            //}
        //}
    //}
    
    
    
   
    
    
    
  // MARK: - Initialization

  func setUpBoundingBoxes() {
    for _ in 0..<YOLO.maxBoundingBoxes {
      boundingBoxes.append(BoundingBox())
    }
//色を指定したいので今回はこちらを使わず,var colors: [UIColor] = []に直接色を指定する
    // Make colors for the bounding boxes. There is one color for each class,
    // 20 classes in total.
    let g1 = UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.5)
    let g2 = UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.5)
    let b1 = UIColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1)
    let b2 = b1
    let b3 = b1
    let b4 = b1
    let b5 = b1
    
    let gb = [g1, g2, b1, b2, b3, b4, b5]
    
    for color in gb {
       colors.append(color)
    }
    //for r: CGFloat in [0.2, 0.4, 0.6, 0.8, 1.0] {
      //for g: CGFloat in [0.3, 0.7] {
        //for b: CGFloat in [0.4, 0.8] {
          //let color = UIColor(red: r, green: g, blue: b, alpha: 1)
          //colors.append(color)
        //}
      //}
    //}
  }

  func setUpCoreImage() {
    // Since we might be running several requests in parallel, we also need
    // to do the resizing in different pixel buffers or we might overwrite a
    // pixel buffer that's already in use.
    for _ in 0..<YOLO.maxBoundingBoxes {
      var resizedPixelBuffer: CVPixelBuffer?
      let status = CVPixelBufferCreate(nil, YOLO.inputWidth, YOLO.inputHeight,
                                       kCVPixelFormatType_32BGRA, nil,
                                       &resizedPixelBuffer)

      if status != kCVReturnSuccess {
        print("Error: could not create resized pixel buffer", status)
      }
      resizedPixelBuffers.append(resizedPixelBuffer)
    }
  }

  func setUpVision() {
    guard let visionModel = try? VNCoreMLModel(for: yolo.model.model) else {
      print("Error: could not create Vision model")
      return
    }

    for _ in 0..<ViewController.maxInflightBuffers {
      let request = VNCoreMLRequest(model: visionModel, completionHandler: visionRequestDidComplete)

      // NOTE: If you choose another crop/scale option, then you must also
      // change how the BoundingBox objects get scaled when they are drawn.
      // Currently they assume the full input image is used.
      request.imageCropAndScaleOption = .scaleFill
      requests.append(request)
    }
  }

  func setUpCamera() {
    videoCapture = VideoCapture()
    videoCapture.delegate = self
    videoCapture.desiredFrameRate = 240
    
    
    //AVCaptureSession.Preset.hd1280x720 → .high に変更
    videoCapture.setUp(sessionPreset: AVCaptureSession.Preset.high) { success in
      if success {
        // Add the video preview into the UI.
        if let previewLayer = self.videoCapture.previewLayer {
          self.videoPreview.layer.addSublayer(previewLayer)
          self.resizePreviewLayer()
        }

        // Add the bounding box layers to the UI, on top of the video preview.
        for box in self.boundingBoxes {
          box.addToLayer(self.videoPreview.layer)
        }

        // Once everything is set up, we can start capturing live video.
        self.videoCapture.start()
        
        
      }
    }
  }
    
    
    
    
    

  // MARK: - UI stuff

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    resizePreviewLayer()
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    return .lightContent
  }

  func resizePreviewLayer() {
    videoCapture.previewLayer?.frame = videoPreview.bounds
  }

  // MARK: - Doing inference

  func predict(image: UIImage) {
    if let pixelBuffer = image.pixelBuffer(width: YOLO.inputWidth, height: YOLO.inputHeight) {
      predict(pixelBuffer: pixelBuffer, inflightIndex: 0)
    }
  }

  func predict(pixelBuffer: CVPixelBuffer, inflightIndex: Int) {
    // Measure how long it takes to predict a single video frame.
    let startTime = CACurrentMediaTime()

    // This is an alternative way to resize the image (using vImage):
    //if let resizedPixelBuffer = resizePixelBuffer(pixelBuffer,
    //                                              width: YOLO.inputWidth,
    //                                              height: YOLO.inputHeight) {

    // Resize the input with Core Image to 416x416.
    if let resizedPixelBuffer = resizedPixelBuffers[inflightIndex] {
      let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
      let sx = CGFloat(YOLO.inputWidth) / CGFloat(CVPixelBufferGetWidth(pixelBuffer))
      let sy = CGFloat(YOLO.inputHeight) / CGFloat(CVPixelBufferGetHeight(pixelBuffer))
      let scaleTransform = CGAffineTransform(scaleX: sx, y: sy)
      let scaledImage = ciImage.transformed(by: scaleTransform)
      ciContext.render(scaledImage, to: resizedPixelBuffer)

      // Give the resized input to our model.
      if let result = ((try? yolo.predict(image: resizedPixelBuffer)) as [YOLO.Prediction]??),
         let boundingBoxes = result {
        let elapsed = CACurrentMediaTime() - startTime
        showOnMainThread(boundingBoxes, elapsed)
      } else {
        print("BOGUS")
      }
    }

    self.semaphore.signal()
  }

  func predictUsingVision(pixelBuffer: CVPixelBuffer, inflightIndex: Int) {
    // Measure how long it takes to predict a single video frame. Note that
    // predict() can be called on the next frame while the previous one is
    // still being processed. Hence the need to queue up the start times.
    startTimes.append(CACurrentMediaTime())

    // Vision will automatically resize the input image.
    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)
    let request = requests[inflightIndex]

    // Because perform() will block until after the request completes, we
    // run it on a concurrent background queue, so that the next frame can
    // be scheduled in parallel with this one.
    DispatchQueue.global().async {
      try? handler.perform([request])
    }
  }

  func visionRequestDidComplete(request: VNRequest, error: Error?) {
    if let observations = request.results as? [VNCoreMLFeatureValueObservation],
       let features = observations.first?.featureValue.multiArrayValue {

      let boundingBoxes = yolo.computeBoundingBoxes(features: features)
      let elapsed = CACurrentMediaTime() - startTimes.remove(at: 0)
      showOnMainThread(boundingBoxes, elapsed)
    } else {
      print("BOGUS!")
    }

    self.semaphore.signal()
  }

  func showOnMainThread(_ boundingBoxes: [YOLO.Prediction], _ elapsed: CFTimeInterval) {
    if drawBoundingBoxes {
      DispatchQueue.main.async {
        // For debugging, to make sure the resized CVPixelBuffer is correct.
        //var debugImage: CGImage?
        //VTCreateCGImageFromCVPixelBuffer(resizedPixelBuffer, nil, &debugImage)
        //self.debugImageView.image = UIImage(cgImage: debugImage!)

        self.show(predictions: boundingBoxes)

        let fps = self.measureFPS()
        self.timeLabel.text = String(format: "Elapsed %.5f seconds - %.2f FPS", elapsed, fps)
      }
    }
  }

  func measureFPS() -> Double {
    // Measure how many frames were actually delivered per second.
    framesDone += 1
    let frameCapturingElapsed = CACurrentMediaTime() - frameCapturingStartTime
    let currentFPSDelivered = Double(framesDone) / frameCapturingElapsed
    if frameCapturingElapsed > 1 {
      framesDone = 0
      frameCapturingStartTime = CACurrentMediaTime()
    }
    return currentFPSDelivered
  }

  func show(predictions: [YOLO.Prediction]) {
    for i in 0..<boundingBoxes.count {
      if i < predictions.count {
        let prediction = predictions[i]

        // The predicted bounding box is in the coordinate space of the input
        // image, which is a square image of 416x416 pixels. We want to show it
        // on the video preview, which is as wide as the screen and has a 16:9
        // aspect ratio. The video preview also may be letterboxed at the top
        // and bottom.
        let width = view.bounds.width
        let height = width * 16 / 9
        let scaleX = width / CGFloat(YOLO.inputWidth)
        let scaleY = height / CGFloat(YOLO.inputHeight)
        let top = (view.bounds.height - height) / 2

        // Translate and scale the rectangle to our own coordinate system.
        var rect = prediction.rect
        rect.origin.x *= scaleX
        rect.origin.y *= scaleY
        rect.origin.y += top
        rect.size.width *= scaleX
        rect.size.height *= scaleY

        // Show the bounding box.
        let label = String(format: "%@ %.1f", labels[prediction.classIndex], prediction.score * 100)
        let color = colors[prediction.classIndex]
        boundingBoxes[i].show(frame: rect, label: label, color: color)
      } else {
        boundingBoxes[i].hide()
      }
    }
  }
    @objc func tappedScreen(gestureRecognizer: UITapGestureRecognizer) {
        let tapCGPoint = gestureRecognizer.location(ofTouch: 0, in: gestureRecognizer.view)
        focusView.frame.size = CGSize(width: 120, height: 120)
        focusView.center = tapCGPoint
        focusView.backgroundColor = UIColor.white.withAlphaComponent(0)
        focusView.layer.borderColor = UIColor(red: 1.0, green: 1.0, blue: 0.0, alpha:1.0).cgColor
        focusView.layer.borderWidth = 2
        focusView.alpha = 1
        self.view.addSubview(focusView)

        UIView.animate(withDuration: 0.5, animations: {
            self.focusView.frame.size = CGSize(width: 80, height: 80)
            self.focusView.center = tapCGPoint
        }, completion: { Void in
            UIView.animate(withDuration: 0.5, animations: {
                self.focusView.alpha = 0
            })
        })

        videoCapture.focusWithMode(focusMode: AVCaptureDevice.FocusMode.autoFocus, exposeWithMode: AVCaptureDevice.ExposureMode.autoExpose, atDevicePoint: tapCGPoint, motiorSubjectAreaChange: true)
    }
    
    
    
    
    
    
    
   
    
    
}




extension ViewController: VideoCaptureDelegate {
  func videoCapture(_ capture: VideoCapture, didCaptureVideoFrame pixelBuffer: CVPixelBuffer?, timestamp: CMTime) {
    // For debugging.
    //predict(image: UIImage(named: "dog416")!); return

    if let pixelBuffer = pixelBuffer {
      // The semaphore will block the capture queue and drop frames when
      // Core ML can't keep up with the camera.
      semaphore.wait()

      // For better throughput, we want to schedule multiple prediction requests
      // in parallel. These need to be separate instances, and inflightBuffer is
      // the index of the current request.
      let inflightIndex = inflightBuffer
      inflightBuffer += 1
      if inflightBuffer >= ViewController.maxInflightBuffers {
        inflightBuffer = 0
      }

      if useVision {
        // This method should always be called from the same thread!
        // Ain't nobody likes race conditions and crashes.
        self.predictUsingVision(pixelBuffer: pixelBuffer, inflightIndex: inflightIndex)
      } else {
        // For better throughput, perform the prediction on a concurrent
        // background queue instead of on the serial VideoCapture queue.
        DispatchQueue.global().async {
          self.predict(pixelBuffer: pixelBuffer, inflightIndex: inflightIndex)
        }
      }
    }
    
    }
    
    
    
}



