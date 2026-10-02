# Self-hosted document scanner

This optional Python service runs PaddleOCR 3.7.0 / PaddleX 3.7.2 PP-StructureV3 on CPU, using PP-OCRv5 detection and English mobile recognition. It does not use a paid OCR/LLM API. Model weights download once from PaddleOCR's official hosts and are cached. Uploaded documents are processed in a temporary directory and removed after the request. OCR results require human review before any accounting draft is saved.

## Run on your own server

Use Python 3.11 or 3.12, install `requirements.txt`, and run:

```sh
uvicorn app:app --host 0.0.0.0 --port 8000 --workers 1 --limit-concurrency 8
```

Or build the Dockerfile in this directory. Set these server environment variables:

- `SUPABASE_URL`: the existing Supabase project URL.
- `SUPABASE_ANON_KEY`: existing public anon key (not the service-role key).
- `WEB_ORIGIN`: exact CloudLedger web origin, comma-separated if necessary.
- `PADDLE_PDX_MODEL_SOURCE=bos`: optional official Paddle model mirror.
- `OMP_NUM_THREADS=2`: bound CPU thread usage.

The service validates the user's Supabase session and active company membership using their own JWT. There is no public document-upload endpoint without sign-in. Health responds at `/health`; it is a process check, not proof that all models are available.

Warm the cache before exposing the worker: run `python scan.py /path/to/test-bill.png /tmp/scan-result.json`. Do not activate the frontend until this succeeds and a real document is checked. Keep cached models across restarts using the PaddleX cache directory (`~/.paddlex`). Measure peak RAM and processing time on the target host; the existing free Node API is not configured to run this worker. No paid hosting plan is created by this change.

Set `VITE_DOCUMENT_SCAN_URL` on the web build to the HTTPS origin of this worker, then rebuild/deploy the web app. Without this variable, the existing browser extraction stays available. With it configured, images and scanned/unmatched PDFs use the worker; a text PDF with complete matching line totals keeps exact native text; DOCX/TXT use local text extraction. Worker errors are shown explicitly, rather than claiming a successful server scan.

Limits: 12 MB, 10 PDF pages, 20-megapixel images, one inference at a time, 240-second child-process timeout. Reverse proxy body limits should also be set to 12 MB. English recognition is configured; Urdu, handwriting and unfamiliar table headers have not been validated. Merged cells and unmatched arithmetic require manual corrections.

## Measured smoke test

A 2400-pixel invoice image rasterized from a supplied text PDF was scanned successfully: 8 items, quantity 116, PKR 65,000, including serial details. Full layout inference with cached weights took 45.1 seconds and peak child-process RSS was about 3.2 GiB in the development environment. This is one document, not an accuracy guarantee for all bills. A 512 MB worker is insufficient for this configuration. Provision memory above this measured peak and repeat the smoke test on the actual host before activation.

## Render setup

Create a separate Web Service from this repository using Docker. Set Root Directory to `services/document-ocr`, Dockerfile Path to `Dockerfile`, and Health Check Path to `/health`. Enter the environment variables above in Render. Start with enough RAM for the measured model footprint and verify an actual scan before enabling the web variable; no plan is selected automatically. Set the web service `VITE_DOCUMENT_SCAN_URL` to the new worker HTTPS URL and redeploy the static web service. Do not change the existing API service.

## Tests

```sh
python -m unittest discover -s . -p 'test_*.py'
```

Unit tests cover normalization, session enforcement, company denial, invalid images and cleanup. They mock inference and do not establish model recognition accuracy. Use real image/PDF inference as a separate release gate.
