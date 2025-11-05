import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

import 'home_screen.dart';

class StationaryVehicleDetectionPage extends StatefulWidget {
  const StationaryVehicleDetectionPage({super.key});

  @override
  State<StationaryVehicleDetectionPage> createState() =>
      _StationaryVehicleDetectionPageState();
}

class _StationaryVehicleDetectionPageState
    extends State<StationaryVehicleDetectionPage> {
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  bool _isCameraInitializing = true;
  final AudioPlayer _audioPlayer = AudioPlayer();
  late final TextRecognizer _textRecognizer;
  final FlutterTts _tts = FlutterTts();

  // Detection flow state
  String _currentStep = 'initial_countdown';
  String _statusMessage = 'Initializing...';
  bool _isProcessing = false;

  // Initial countdown timer
  int _initialCountdown = 15;
  Timer? _initialCountdownTimer;

  // Stationary detection
  bool _isStationary = false;
  int _stationarySeconds = 0;
  Timer? _stationaryTimer;
  StreamSubscription? _accelerometerSubscription;
  double _lastAccelX = 0, _lastAccelY = 0, _lastAccelZ = 0;

  // Plate numbers
  String? _regNo1;
  String? _regNo2;
  String? _regNo3;

  // Result
  bool? _testPassed;

  // Result countdown timer
  int _resultCountdown = 10;
  Timer? _resultCountdownTimer;

  @override
  void initState() {
    super.initState();
    _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    _initializeApp();
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _audioPlayer.dispose();
    _textRecognizer.close();
    _stationaryTimer?.cancel();
    _accelerometerSubscription?.cancel();
    _initialCountdownTimer?.cancel();
    _resultCountdownTimer?.cancel();
    _tts.stop();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    // Request permissions FIRST
    final permissions = await _requestPermissions();

    if (!permissions) {
      setState(() {
        _isCameraInitializing = false;
        _statusMessage = 'Permissions denied. Please grant permissions.';
      });
      return;
    }

    // Wait a bit for permissions to settle
    await Future.delayed(const Duration(milliseconds: 500));

    // THEN initialize camera
    await _initCamera();
  }

  Future<bool> _requestPermissions() async {
    final statuses = await [
      Permission.camera,
      Permission.microphone,
    ].request();

    return statuses[Permission.camera]?.isGranted == true;
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        if (mounted) {
          setState(() {
            _isCameraInitializing = false;
            _statusMessage = 'No camera found';
          });
        }
        return;
      }

      final cam = _cameras!.first;
      _cameraController = CameraController(
        cam,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();

      if (mounted) {
        setState(() => _isCameraInitializing = false);
        // Start automatic countdown after camera initializes
        await Future.delayed(const Duration(milliseconds: 500));
        _startInitialCountdown();
      }
    } catch (e) {
      debugPrint('❌ Camera init error: $e');
      if (mounted) {
        setState(() {
          _isCameraInitializing = false;
          _statusMessage = 'Camera initialization failed: $e';
        });
      }
    }
  }

  // ============ INITIAL COUNTDOWN (15 SEC) ============
  void _startInitialCountdown() {
    setState(() {
      _currentStep = 'initial_countdown';
      _statusMessage = 'Detection starting in $_initialCountdown seconds...';
    });

    _initialCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _initialCountdown--;
        _statusMessage = 'Detection starting in $_initialCountdown seconds...';
      });

      if (_initialCountdown <= 0) {
        timer.cancel();
        _startStationaryDetection();
      }
    });
  }

  // ============ AUDIO METHODS ============
  Future<void> _playSound(String assetName) async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.setReleaseMode(ReleaseMode.stop);
      await _audioPlayer.setVolume(1.0);

      // Try playing from assets
      await _audioPlayer.play(AssetSource(assetName));
      debugPrint("🔊 Playing sound: $assetName");

      // Wait for sound to complete
      await Future.delayed(const Duration(milliseconds: 1500));
    } catch (e) {
      debugPrint("❌ Audio error: $e");
      // If asset fails, try generating a beep tone
      try {
        await _audioPlayer.play(AssetSource('$assetName'));
      } catch (e2) {
        debugPrint("❌ Audio fallback error: $e2");
      }
    }
  }

  Future<void> _speakInstruction(String instruction) async {
    try {
      debugPrint("🔊 Speaking: $instruction");
      await _tts.setLanguage("en-IN");
      await _tts.setSpeechRate(0.9);
      await _tts.setVolume(1.0);
      await _tts.speak(instruction);

      // Wait for speech to complete
      await Future.delayed(Duration(milliseconds: instruction.length * 80));
    } catch (e) {
      debugPrint("❌ TTS error: $e");
    }
  }

  // ============ STATIONARY DETECTION ============
  void _startStationaryDetection() {
    setState(() {
      _currentStep = 'waiting_stationary';
      _statusMessage = 'Please dock your device on tripod...';
      _stationarySeconds = 0;
      _isStationary = false;
    });

    _speakInstruction("Please dock your device on the tripod");

    _accelerometerSubscription = accelerometerEvents.listen((event) {
      final diffX = (event.x - _lastAccelX).abs();
      final diffY = (event.y - _lastAccelY).abs();
      final diffZ = (event.z - _lastAccelZ).abs();

      _lastAccelX = event.x;
      _lastAccelY = event.y;
      _lastAccelZ = event.z;

      if (diffX < 0.5 && diffY < 0.5 && diffZ < 0.5) {
        if (!_isStationary) {
          _isStationary = true;
          _startStationaryTimer();
        }
      } else {
        if (_isStationary) {
          _isStationary = false;
          _stationaryTimer?.cancel();
          setState(() {
            _stationarySeconds = 0;
            _statusMessage = 'Device moving... Hold steady!';
          });
        }
      }
    });
  }

  void _startStationaryTimer() {
    _stationaryTimer?.cancel();
    _stationaryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isStationary) {
        timer.cancel();
        return;
      }

      setState(() {
        _stationarySeconds++;
        _statusMessage = 'Device steady... ${5 - _stationarySeconds}s';
      });

      if (_stationarySeconds >= 5) {
        timer.cancel();
        _accelerometerSubscription?.cancel();
        _onDeviceReady();
      }
    });
  }

  void _onDeviceReady() {
    setState(() {
      _currentStep = 'ready';
      _statusMessage = 'Device ready! Starting capture...';
    });

    _speakInstruction("Device in stationary mode for 5 seconds");
    _playSound("beepSound.mp3");

    Future.delayed(const Duration(seconds: 2), _captureFirstPhoto);
  }

  // ============ CAPTURE SEQUENCE ============
  Future<void> _captureFirstPhoto() async {
    setState(() {
      _currentStep = 'capture1';
      _statusMessage = 'Capturing first photo...';
      _isProcessing = true;
    });

    try {
      final xfile = await _cameraController!.takePicture();
      final bytes = await xfile.readAsBytes();

      setState(() {
        _statusMessage = 'Processing first photo...';
      });

      final plateNo = await _extractPlateNumber(bytes);

      setState(() {
        _regNo1 = plateNo;
        _statusMessage = plateNo != null
            ? 'Photo 1: $plateNo\nWaiting...'
            : 'Photo 1: No plate detected\nWaiting...';
        _isProcessing = false;
      });

      debugPrint("📸 Photo 1 - Detected: $plateNo");

      await Future.delayed(const Duration(seconds: 5));

      // FIRST speak, THEN play sound
      await _speakInstruction("Raising alarm");
      await Future.delayed(const Duration(milliseconds: 500));
      await _playSound("beepSound.mp3");
      await Future.delayed(const Duration(milliseconds: 500));

      _captureSecondPhoto();
    } catch (e) {
      debugPrint("❌ Capture 1 error: $e");
      setState(() => _isProcessing = false);
      _resetTest();
    }
  }

  Future<void> _captureSecondPhoto() async {
    setState(() {
      _currentStep = 'capture2';
      _statusMessage = 'Capturing second photo...';
      _isProcessing = true;
    });

    try {
      final xfile = await _cameraController!.takePicture();
      final bytes = await xfile.readAsBytes();

      setState(() {
        _statusMessage = 'Processing second photo...';
      });

      final plateNo = await _extractPlateNumber(bytes);

      setState(() {
        _regNo2 = plateNo;
        _statusMessage = plateNo != null
            ? 'Photo 2: $plateNo\nMatching...'
            : 'Photo 2: No plate detected\nMatching...';
        _isProcessing = false;
      });

      debugPrint("📸 Photo 2 - Detected: $plateNo");

      await Future.delayed(const Duration(seconds: 5));

      await _playSound("beepSound.mp3");
      await Future.delayed(const Duration(milliseconds: 500));

      await _captureVideo();
    } catch (e) {
      debugPrint("❌ Capture 2 error: $e");
      setState(() => _isProcessing = false);
      _resetTest();
    }
  }

  Future<void> _captureVideo() async {
    debugPrint("🎥 Starting video capture sequence...");
    setState(() {
      _currentStep = 'video';
      _statusMessage = 'Recording video (3 seconds)...';
      _isProcessing = true;
    });

    try {
      await _cameraController!.startVideoRecording();
      debugPrint("🎥 Video recording started");

      await Future.delayed(const Duration(seconds: 3));

      final videoFile = await _cameraController!.stopVideoRecording();
      debugPrint("🎥 Video saved: ${videoFile.path}");

      setState(() {
        _statusMessage = 'Processing video frame...';
      });

      await Future.delayed(const Duration(milliseconds: 500));

      final xfile = await _cameraController!.takePicture();
      final bytes = await xfile.readAsBytes();

      final plateNo = await _extractPlateNumber(bytes);

      setState(() {
        _regNo3 = plateNo;
        _statusMessage = plateNo != null
            ? 'Video: $plateNo\nCalculating result...'
            : 'Video: No plate detected\nCalculating result...';
        _isProcessing = false;
      });

      debugPrint("🎥 Video frame - Detected: $plateNo");

      await Future.delayed(const Duration(seconds: 1));
      _calculateResult();
    } catch (e) {
      debugPrint("❌ Video capture error: $e");
      setState(() => _isProcessing = false);
      _calculateResult();
    }
  }

  Future<void> _calculateResult() async {
    debugPrint("🔍 === CALCULATING RESULT ===");
    debugPrint("  regNo1: $_regNo1");
    debugPrint("  regNo2: $_regNo2");
    debugPrint("  regNo3: $_regNo3");

    final allDetected = _regNo1 != null && _regNo2 != null && _regNo3 != null;

    bool passed = false;
    if (allDetected) {
      final n1 = _normalizeForMatch(_regNo1!);
      final n2 = _normalizeForMatch(_regNo2!);
      final n3 = _normalizeForMatch(_regNo3!);

      debugPrint("🔍 Comparing normalized values:");
      debugPrint("  Photo 1: $n1");
      debugPrint("  Photo 2: $n2");
      debugPrint("  Video:   $n3");

      passed = (n1 == n2 && n2 == n3);
      debugPrint("🔍 Result: ${passed ? 'PASSED ✅' : 'FAILED ❌'}");
    } else {
      debugPrint("🔍 Not all plates detected - FAILED ❌");
    }

    setState(() {
      _currentStep = 'result';
      _testPassed = passed;
      _statusMessage = passed ? '✅ PASSED' : '❌ FAILED';
    });

    await _speakInstruction(
        passed ? "Test passed successfully" : "Test failed");

    _showResultDialog();
  }

  // ============ OCR METHODS ============
  Future<String?> _extractPlateNumber(Uint8List bytes) async {
    try {
      final tmp = await _writeTempImage(bytes);
      final inputImage = InputImage.fromFilePath(tmp.path);
      final recognized = await _textRecognizer.processImage(inputImage);

      if (recognized.text.trim().isNotEmpty) {
        final plateInfo = _findPlateFromRecognized(recognized);
        if (plateInfo != null) {
          return plateInfo;
        }
      }

      final enhanced = await _enhanceForOcr(bytes);
      if (enhanced != null) {
        final tmp2 = await _writeTempImage(enhanced);
        final inputImage2 = InputImage.fromFilePath(tmp2.path);
        final recognized2 = await _textRecognizer.processImage(inputImage2);

        final plateInfo2 = _findPlateFromRecognized(recognized2);
        if (plateInfo2 != null) {
          return plateInfo2;
        }
      }

      return null;
    } catch (e) {
      debugPrint("❌ OCR error: $e");
      return null;
    }
  }

  Future<Uint8List?> _enhanceForOcr(Uint8List bytes) async {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;

      img.Image gray = img.grayscale(decoded);
      gray = img.adjustColor(gray, contrast: 1.2, brightness: 0.05);

      for (int y = 0; y < gray.height; y++) {
        for (int x = 0; x < gray.width; x++) {
          final pixel = gray.getPixel(x, y);
          final luma = img.getLuminance(pixel);
          if (luma < 90) {
            gray.setPixelRgba(x, y, 0, 0, 0, 255);
          } else {
            gray.setPixelRgba(x, y, 255, 255, 255, 255);
          }
        }
      }

      final out = img.encodeJpg(gray, quality: 85);
      return Uint8List.fromList(out);
    } catch (e) {
      debugPrint("❌ Enhance error: $e");
      return null;
    }
  }

  Future<io.File> _writeTempImage(Uint8List bytes) async {
    final dir = await io.Directory.systemTemp.createTemp();
    final file = io.File(p.join(dir.path, 'temp_${DateTime.now().microsecondsSinceEpoch}.jpg'));
    await file.writeAsBytes(bytes);
    return file;
  }

  String? _findPlateFromRecognized(RecognizedText recognized) {
    final blocks = recognized.blocks;
    for (var block in blocks) {
      final bText = block.text;
      final normalized = _normalizeOcrText(bText);
      final plate = _matchPlateRegex(normalized);
      if (plate != null) return plate;

      for (var line in block.lines) {
        final lText = line.text;
        final normalizedLine = _normalizeOcrText(lText);
        final plateLine = _matchPlateRegex(normalizedLine);
        if (plateLine != null) return plateLine;
      }
    }

    final whole = recognized.text;
    final normalizedWhole = _normalizeOcrText(whole);
    final plateWhole = _matchPlateRegex(normalizedWhole);
    return plateWhole;
  }

  String _normalizeOcrText(String text) {
    String s = text.toUpperCase();
    s = s.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    s = s
        .replaceAll('O', '0')
        .replaceAll('Q', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1')
        .replaceAll('Z', '2')
        .replaceAll('B', '8')
        .replaceAll('S', '5');
    return s;
  }

  String? _matchPlateRegex(String normalized) {
    normalized = normalized
        .replaceAll(RegExp(r'[\n\r\s]+'), '')
        .replaceAll(RegExp(r'[^A-Z0-9]'), '')
        .toUpperCase();

    normalized = normalized
        .replaceAll(RegExp(r'(?<=D)1'), 'L')
        .replaceAll(RegExp(r'(?<=D)I'), 'L')
        .replaceAllMapped(RegExp(r'(?<=\d)O(?=\d)'), (m) => '0')
        .replaceAllMapped(RegExp(r'(?<=\d)O(?=$)'), (m) => '0')
        .replaceAllMapped(RegExp(r'(?<=\d)O(?=[A-Z])'), (m) => '0')
        .replaceAllMapped(RegExp(r'(?<=[A-Z])5(?=[A-Z])'), (m) => 'S')
        .replaceAllMapped(RegExp(r'(?<=[A-Z])8(?=[A-Z])'), (m) => 'B');

    final reg = RegExp(r'[A-Z]{2}\d{1,2}[A-Z]{1,3}\d{3,4}', caseSensitive: false);
    final m = reg.firstMatch(normalized);

    return m?.group(0);
  }

  String _normalizeForMatch(String text) {
    String normalized = text.toUpperCase();
    normalized = normalized.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    normalized = normalized
        .replaceAll(RegExp(r'\bD1\b'), 'DL')
        .replaceAll(RegExp(r'\bDI\b'), 'DL')
        .replaceAll(RegExp(r'(?<=D)1'), 'L')
        .replaceAll(RegExp(r'(?<=D)I'), 'L')
        .replaceAll('8', 'B');
    return normalized;
  }

  // ============ UI METHODS ============
  void _showResultDialog() {
    String detectedPlate = _regNo3 ?? _regNo2 ?? _regNo1 ?? 'Not Detected';
    String resultMessage = _testPassed == true
        ? "Vehicle Number $detectedPlate Matched Successfully!"
        : "Vehicle Number $detectedPlate Did Not Match — Test Failed!";

    _resultCountdown = 10;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          _resultCountdownTimer?.cancel();
          _resultCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
            if (_resultCountdown > 0) {
              setDialogState(() {
                _resultCountdown--;
              });
            } else {
              timer.cancel();
              Navigator.of(dialogContext).pop(); // Close dialog
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (context) => const HomeScreen()),
                    (Route<dynamic> route) => false,
              );
            }
          });

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            backgroundColor: Colors.white,
            contentPadding: EdgeInsets.zero,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 🔷 Header with gradient
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: _testPassed == true
                          ? [const Color(0xFF4CAF50), const Color(0xFF66BB6A)]
                          : [const Color(0xFFFF6B6B), const Color(0xFFFF8E53)],
                    ),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(24),
                      topRight: Radius.circular(24),
                    ),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        _testPassed == true
                            ? Icons.check_circle_outline
                            : Icons.cancel_outlined,
                        color: Colors.white,
                        size: 80,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _testPassed == true ? 'TEST PASSED' : 'TEST FAILED',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 24,
                        ),
                      ),
                    ],
                  ),
                ),

                // 🔷 Body content
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        resultMessage,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 24,
                          color: _testPassed == true
                              ? Colors.green[700]
                              : Colors.red[700],
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 20),

                      // ✅ Show mismatch details ONLY if test failed
                      if (_testPassed != true) ...[
                        _buildResultRow('Photo 1:', _regNo1),
                        const SizedBox(height: 8),
                        _buildResultRow('Photo 2:', _regNo2),
                        const SizedBox(height: 8),
                        _buildResultRow('Video:', _regNo3),
                        const SizedBox(height: 24),
                      ],

                      // ✅ Countdown timer box
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Text(
                              'Returning to home in',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey[700],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '$_resultCountdown',
                              style: TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                                color: _testPassed == true
                                    ? const Color(0xFF4CAF50)
                                    : const Color(0xFFFF6B6B),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'seconds',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey[700],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }


  Widget _buildResultRow(String label, String? value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            value ?? 'Not Detected',
            style: TextStyle(
              fontSize: 14,
              color: value != null ? Colors.green[700] : Colors.red[700],
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  void _resetTest() {
    setState(() {
      _currentStep = 'initial_countdown';
      _statusMessage = 'Initializing...';
      _regNo1 = null;
      _regNo2 = null;
      _regNo3 = null;
      _testPassed = null;
      _stationarySeconds = 0;
      _isStationary = false;
      _initialCountdown = 15;
    });
    _stationaryTimer?.cancel();
    _accelerometerSubscription?.cancel();
    _resultCountdownTimer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    if (_isCameraInitializing) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1A237E), Color(0xFF3949AB)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(color: Colors.white),
                SizedBox(height: 16),
                Text(
                  'Initializing Camera...',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final controller = _cameraController;
    return Scaffold(
      backgroundColor: Colors.black,
      body: controller == null || !controller.value.isInitialized
          ? Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.camera_alt_outlined,
              color: Colors.white,
              size: 80,
            ),
            const SizedBox(height: 16),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('Go Back'),
            ),
          ],
        ),
      )
          : Stack(
        children: [
          Positioned.fill(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: controller.value.previewSize?.height,
                height: controller.value.previewSize?.width,
                child: CameraPreview(controller),
              ),
            ),
          ),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.5),
                    Colors.transparent,
                    Colors.transparent,
                    Colors.black.withOpacity(0.7),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Expanded(
                      child: Text(
                        'Stationary Detection',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 100,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _getStepColor(),
                  width: 2,
                ),
              ),
              child: Column(
                children: [
                  Text(
                    _statusMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (_currentStep == 'initial_countdown')
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(
                        value: (15 - _initialCountdown) / 15,
                        backgroundColor: Colors.white30,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.blue,
                        ),
                      ),
                    ),
                  if (_currentStep == 'waiting_stationary' && _isStationary)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(
                        value: _stationarySeconds / 5,
                        backgroundColor: Colors.white30,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          _getStepColor(),
                        ),
                      ),
                    ),
                  if (_regNo1 != null) ...[
                    const SizedBox(height: 16),
                    _buildPlateDisplay('Photo 1', _regNo1),
                  ],
                  if (_regNo2 != null) ...[
                    const SizedBox(height: 8),
                    _buildPlateDisplay('Photo 2', _regNo2),
                  ],
                  if (_regNo3 != null) ...[
                    const SizedBox(height: 8),
                    _buildPlateDisplay('Video', _regNo3),
                  ],
                ],
              ),
            ),
          ),
          if (_isProcessing)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.5),
                child: const Center(
                  child: CircularProgressIndicator(
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlateDisplay(String label, String? plate) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green, width: 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
            ),
          ),
          Text(
            plate ?? 'N/A',
            style: const TextStyle(
              color: Colors.greenAccent,
              fontSize: 16,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    );
  }

  Color _getStepColor() {
    switch (_currentStep) {
      case 'initial_countdown':
        return Colors.blue;
      case 'waiting_stationary':
        return Colors.orange;
      case 'ready':
        return Colors.green;
      case 'capture1':
      case 'capture2':
      case 'video':
        return Colors.blue;
      case 'result':
        return _testPassed == true ? Colors.green : Colors.red;
      default:
        return Colors.white;
    }
  }
}