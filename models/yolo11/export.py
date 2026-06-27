from ultralytics import YOLO
m = YOLO("yolo11n.pt")  # downloads weights if missing
# nms=True bakes NMS into the model so Vision yields VNRecognizedObjectObservation with labels.
path = m.export(format="coreml", nms=True, imgsz=640)
print("EXPORTED:", path)
