package com.familyshield.agent.setup

import android.Manifest
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Roadmap 3.2, second half: reads the parent app's `osra://pair` QR code with CameraX and the
 * **bundled** ML Kit barcode model, and returns the raw string to [PairingActivity].
 *
 * The scanner deliberately does not pair. It returns text; [PairingActivity] validates it with
 * [PairQrPayload], shows what was read (masked) and waits for an explicit confirm. A frame that
 * contains a different QR code is ignored rather than falling back to a typed code.
 *
 * Camera permission is requested on first use with a rationale that says what the camera is for.
 * A denial (or a camera that cannot start) finishes with [EXTRA_ERROR] so the caller can explain why
 * and leave the typed form usable — never a silent return to a form that looks like nothing happened.
 */
class PairQrScanActivity : ComponentActivity() {

    private lateinit var previewView: PreviewView
    private lateinit var status: TextView
    private var cameraProvider: ProcessCameraProvider? = null
    private var scanner: BarcodeScanner? = null
    private val found = AtomicBoolean(false)

    private val cameraPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            startCamera()
        } else {
            finishWithError(
                "Camera permission was denied, so the QR scanner cannot start. " +
                    "Enter the server URL and pairing code below, or allow Camera in Settings and scan again.",
            )
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildLayout())
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else {
            showCameraRationale()
        }
    }

    override fun onDestroy() {
        found.set(true)
        scanner?.close()
        cameraProvider?.unbindAll()
        super.onDestroy()
    }

    private fun buildLayout(): View {
        val root = FrameLayout(this)
        previewView = PreviewView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            contentDescription = "Camera preview"
        }
        root.addView(previewView)

        val overlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setBackgroundColor(Color.argb(170, 0, 0, 0))
            val pad = (16 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad, pad, pad)
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.TOP,
            )
        }
        status = TextView(this).apply {
            text = "Starting the camera…"
            setTextColor(Color.WHITE)
            textSize = 16f
            contentDescription = text
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        overlay.addView(status)
        val close = Button(this).apply {
            text = "Cancel scanning"
            contentDescription = "Cancel scanning and return to the pairing form"
            setOnClickListener { finish() }
        }
        overlay.addView(close)
        root.addView(overlay)
        return root
    }

    private fun showCameraRationale() {
        AlertDialog.Builder(this)
            .setTitle("Scan the pairing QR code")
            .setMessage(
                "OSRA uses the camera only to read the QR code on your parent's screen. " +
                    "The picture is processed on this phone and is not saved or uploaded. " +
                    "You can always type the server URL and code instead.",
            )
            .setPositiveButton("Continue") { _, _ ->
                cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
            }
            .setNegativeButton("Enter code instead") { _, _ ->
                finishWithError(
                    "Camera permission was not granted, so the QR scanner cannot start. " +
                        "Enter the server URL and pairing code below.",
                )
            }
            .setCancelable(false)
            .show()
    }

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider = try {
                future.get()
            } catch (e: Exception) {
                finishWithError("The camera could not start. Enter the server URL and pairing code below.")
                return@addListener
            }
            cameraProvider = provider
            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analysis.setAnalyzer(ContextCompat.getMainExecutor(this)) { imageProxy -> analyze(imageProxy) }

            scanner = BarcodeScanning.getClient(
                BarcodeScannerOptions.Builder()
                    .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                    .build(),
            )
            try {
                provider.unbindAll()
                provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                status.text = "Camera ready. Point the phone at the QR code on the parent's screen."
                status.contentDescription = status.text
            } catch (e: Exception) {
                finishWithError("The camera could not start. Enter the server URL and pairing code below.")
            }
        }, ContextCompat.getMainExecutor(this))
    }

    @ExperimentalGetImage
    private fun analyze(imageProxy: ImageProxy) {
        val mediaImage = imageProxy.image
        if (mediaImage == null || found.get()) {
            imageProxy.close()
            return
        }
        val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
        val task = try {
            scanner?.process(image)
        } catch (e: Exception) {
            null // the scanner was closed while this frame was in flight
        }
        if (task == null) {
            imageProxy.close()
            return
        }
        task.addOnSuccessListener { barcodes ->
            val raw = barcodes.firstOrNull { !it.rawValue.isNullOrBlank() }?.rawValue
            if (!raw.isNullOrBlank() && found.compareAndSet(false, true)) {
                scanner?.close()
                scanner = null
                setResult(RESULT_OK, Intent().putExtra(EXTRA_RAW, raw))
                finish()
            }
        }.addOnCompleteListener { imageProxy.close() }
    }

    private fun finishWithError(message: String) {
        if (isFinishing || isDestroyed) return
        setResult(RESULT_CANCELED, Intent().putExtra(EXTRA_ERROR, message))
        finish()
    }

    companion object {
        const val EXTRA_RAW = "com.familyshield.agent.setup.PAIR_QR_RAW"
        const val EXTRA_ERROR = "com.familyshield.agent.setup.PAIR_QR_ERROR"
    }
}
