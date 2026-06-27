# YOLO11n object detector (Core ML)

Powers the interactive **Subject Lock** stabilization picker: detects objects on a frame so the
user can click one to track. Bundled (5.2 MB) at `Sources/PalmierPro/Resources/Models/Detector.mlmodelc`.

## Regenerate

```bash
python3.12 -m venv venv && . venv/bin/activate
pip install ultralytics coremltools "numpy<2"
python export.py                       # -> yolo11n.mlpackage (NMS baked in)
xcrun coremlcompiler compile yolo11n.mlpackage .
cp -R yolo11n.mlmodelc ../../Sources/PalmierPro/Resources/Models/Detector.mlmodelc
```

`nms=True` bakes non-max-suppression into the model so Vision returns `VNRecognizedObjectObservation`
(label + normalized box) directly. 80 COCO classes. Requires Python 3.12 (coremltools BlobWriter
has no wheel for 3.14) and numpy<2 (coremltools scalar-cast bug on numpy 2.x).
