"""Time actual existing V2 predictions on an already captured JPEG.

Uses the existing /predict endpoint, outside the single-shot gateway evidence.
Does not capture images, use a cached prediction, or alter server configuration.
"""
import argparse
import hashlib
import http.client
import json
import pathlib
import ssl
import statistics
import time


def benchmark(image, host, port, tls, persistent, count):
    digest = hashlib.sha256(image).hexdigest()
    boundary = "RiceLatency" + digest[:24]
    body = (
        ('--' + boundary + '\r\nContent-Disposition: form-data; name="file"; '
         'filename="hololens-latency-existing-photo.jpg"\r\n'
         'Content-Type: image/jpeg\r\n\r\n').encode()
        + image + ('\r\n--' + boundary + '--\r\n').encode()
    )
    connection = None
    rows = []
    try:
        for index in range(count):
            start = time.perf_counter()
            connect_ms = 0.0
            if connection is None:
                connection = (http.client.HTTPSConnection(host, port, timeout=30, context=ssl.create_default_context())
                              if tls else http.client.HTTPConnection(host, port, timeout=30))
                connection.connect()
                connect_ms = (time.perf_counter() - start) * 1000
            request_start = time.perf_counter()
            connection.request("POST", "/predict", body=body, headers={
                "Content-Type": "multipart/form-data; boundary=" + boundary,
                "Content-Length": str(len(body)),
                "User-Agent": "RiceHoloLensLatencyTest/1.0 (same actual photograph)",
            })
            sent = time.perf_counter()
            response = connection.getresponse()
            response_body = response.read()
            end = time.perf_counter()
            if response.status != 200:
                raise RuntimeError("Prediction HTTP " + str(response.status))
            result = json.loads(response_body)
            if not isinstance(result.get("is_valid"), bool):
                raise RuntimeError("Invalid existing model result")
            rows.append({"index": index + 1, "connect_ms": round(connect_ms, 2),
                         "send_ms": round((sent - request_start) * 1000, 2),
                         "response_wait_ms": round((end - sent) * 1000, 2),
                         "total_ms": round((end - start) * 1000, 2),
                         "predicted_class": result["predicted_class"],
                         "confidence": result["confidence"], "is_valid": result["is_valid"]})
            if not persistent or response.will_close:
                connection.close()
                connection = None
    finally:
        if connection:
            connection.close()
    return {"image_sha256": digest, "image_bytes": len(image), "persistent": persistent,
            "endpoint": ("https://" if tls else "http://") + host + ":" + str(port) + "/predict",
            "cached_inference": False, "samples": rows,
            "median_total_ms": round(statistics.median(row["total_ms"] for row in rows), 2)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", type=pathlib.Path, required=True)
    parser.add_argument("--local-server", action="store_true")
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--count", type=int, choices=(1, 2, 3), default=3)
    options = parser.parse_args()
    image = options.image.read_bytes()
    if not image.startswith(b"\xff\xd8") or len(image) > 7 * 1024 * 1024:
        raise ValueError("Expected a bounded existing JPEG")
    host, port, tls = ("127.0.0.1", 8002, False) if options.local_server else ("rice-srt.cn", 443, True)
    modes = (True,) if options.local_server else (False, True)
    output = {"scope": "Repeated real predictions on the same existing camera photo; no new exposure or model changes.",
              "results": [benchmark(image, host, port, tls, mode, options.count) for mode in modes]}
    text = json.dumps(output, ensure_ascii=True, indent=2)
    if options.output:
        options.output.write_text(text, encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
