import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from uuid import UUID
import json
import httpx
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from PIL import Image
import fitz

MAX_BYTES = 12 * 1024 * 1024
BASE = Path(__file__).parent
app = FastAPI(docs_url=None, redoc_url=None)
app.add_middleware(CORSMiddleware, allow_origins=os.environ.get('WEB_ORIGIN', 'http://localhost:5173').split(','),
                   allow_methods=['POST', 'GET'], allow_headers=['Authorization', 'Content-Type'])
slot = threading.Lock()


def authorize(token, company):
    try: UUID(company)
    except ValueError: raise HTTPException(400, 'Invalid company.')
    if not token or not token.startswith('Bearer '): raise HTTPException(401, 'Sign in first.')
    url, key = os.environ.get('SUPABASE_URL'), os.environ.get('SUPABASE_ANON_KEY')
    if not url or not key: raise HTTPException(503, 'OCR authentication is not configured.')
    headers = {'apikey': key, 'Authorization': token}
    try:
        with httpx.Client(timeout=10) as client:
            user = client.get(f'{url}/auth/v1/user', headers=headers)
            if user.status_code != 200: raise HTTPException(401, 'Session expired.')
            role = client.post(f'{url}/rest/v1/rpc/get_my_company_role', headers=headers, json={'target_company': company})
            if role.status_code != 200 or not role.json(): raise HTTPException(403, 'Company access denied.')
    except httpx.HTTPError: raise HTTPException(503, 'Unable to verify company access.')


def validate_document(path, extension):
    if extension == '.pdf':
        try:
            with fitz.open(path) as pdf:
                if pdf.is_encrypted: raise HTTPException(400, 'Password-protected PDFs are unsupported.')
                if not 1 <= len(pdf) <= 10: raise HTTPException(400, 'Maximum 10 PDF pages.')
                if any(p.rect.width * p.rect.height > 4_000_000 for p in pdf): raise HTTPException(400, 'PDF page dimensions are too large.')
        except HTTPException: raise
        except Exception: raise HTTPException(400, 'Invalid PDF.')
    else:
        try:
            with Image.open(path) as image:
                if image.width * image.height > 20_000_000: raise HTTPException(400, 'Maximum image size is 20 megapixels.')
                if image.format not in ('PNG', 'JPEG', 'WEBP'): raise HTTPException(400, 'Unsupported image format.')
                image.verify()
        except HTTPException: raise
        except Exception: raise HTTPException(400, 'Invalid image.')


@app.get('/health')
def health(): return {'status': 'ok', 'service': 'cloudledger-document-ocr'}


@app.post('/scan')
def scan(file: UploadFile = File(...), company_id: str = Form(...), authorization: str | None = Header(None)):
    authorize(authorization, company_id)
    extension = Path(file.filename or '').suffix.lower()
    if extension not in ('.pdf', '.png', '.jpg', '.jpeg', '.webp'): raise HTTPException(400, 'Upload PDF, PNG, JPG or WebP.')
    if not slot.acquire(blocking=False): raise HTTPException(429, 'Scanner is busy. Try again shortly.')
    try:
        with tempfile.TemporaryDirectory(prefix='cloudledger-scan-') as directory:
            path, output = Path(directory) / ('document' + extension), Path(directory) / 'result.json'
            content = file.file.read(MAX_BYTES + 1)
            if not content or len(content) > MAX_BYTES: raise HTTPException(413, 'Maximum upload size is 12 MB.')
            path.write_bytes(content)
            validate_document(path, extension)
            try:
                run = subprocess.run([sys.executable, str(BASE / 'scan.py'), str(path), str(output)],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=240)
            except subprocess.TimeoutExpired: raise HTTPException(504, 'Scan timed out. Try fewer pages.')
            if run.returncode or not output.exists(): raise HTTPException(503, 'Local OCR could not process this document. Check scanner setup.')
            result = json.loads(output.read_text(encoding='utf8'))
            if not result['text'].strip(): raise HTTPException(422, 'No readable text found.')
            return result
    finally:
        slot.release()
        file.file.close()
