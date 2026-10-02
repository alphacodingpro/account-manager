"""Isolated CPU inference process. Input/output paths are supplied by the service."""
import json
import sys
from pathlib import Path
from normalize import normalize_page


def scan(input_path, output_path):
    from paddleocr import PPStructureV3
    pipeline = PPStructureV3(lang='en', ocr_version='PP-OCRv5', device='cpu', cpu_threads=2,
                             text_det_limit_side_len=1600, text_det_limit_type='max',
                             text_recognition_model_name='en_PP-OCRv5_mobile_rec', use_formula_recognition=False,
                             use_chart_recognition=False, use_doc_orientation_classify=True,
                             use_doc_unwarping=False, use_textline_orientation=True)
    pages, tables, low = [], [], 0
    for result in pipeline.predict(input=str(input_path)):
        data = result.json
        if isinstance(data, str): data = json.loads(data)
        text, page_tables, uncertain = normalize_page(data)
        pages.append(text)
        tables.extend(page_tables)
        low += uncertain
    Path(output_path).write_text(json.dumps({'text': '\n'.join(pages), 'tables': tables,
        'engine': 'PaddleOCR PP-StructureV3', 'warnings': [f'{low} text regions have low OCR confidence. Check against the original.'] if low else []}), encoding='utf8')


if __name__ == '__main__': scan(sys.argv[1], sys.argv[2])
