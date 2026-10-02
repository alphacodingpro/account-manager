"""Turn OCR output into plain rows/cells; never return executable HTML."""
from html.parser import HTMLParser


class TableParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.rows, self.row, self.cell = [], None, None

    def handle_starttag(self, tag, attrs):
        if tag == 'tr': self.row = []
        elif tag in ('td', 'th'): self.cell = []
        elif tag == 'br' and self.cell is not None: self.cell.append('\n')

    def handle_data(self, data):
        if self.cell is not None: self.cell.append(data)

    def handle_endtag(self, tag):
        if tag in ('td', 'th') and self.cell is not None:
            if self.row is not None: self.row.append(''.join(self.cell).strip())
            self.cell = None
        elif tag == 'tr' and self.row is not None:
            if self.row: self.rows.append(self.row)
            self.row = None


def normalize_page(result):
    data = result.get('res', result)
    ocr = data.get('overall_ocr_res', {})
    texts, boxes = ocr.get('rec_texts', []), ocr.get('rec_boxes', [])
    rows = []
    for index, text in enumerate(texts):
        if not text.strip(): continue
        box = boxes[index] if index < len(boxes) else [0, index * 20, 0, index * 20 + 15]
        x, y = float(box[0]), (float(box[1]) + float(box[3])) / 2
        height = max(1, float(box[3]) - float(box[1]))
        row = next((r for r in rows if abs(r['y'] - y) <= min(r['height'], height) * .4), None)
        if row is None:
            row = {'y': y, 'height': height, 'parts': []}
            rows.append(row)
        row['parts'].append((x, text))
    text = '\n'.join(' '.join(t for _, t in sorted(r['parts'])) for r in sorted(rows, key=lambda r: r['y']))
    tables = []
    for table in data.get('table_res_list', []):
        parser = TableParser()
        parser.feed(table.get('pred_html', ''))
        if parser.rows: tables.append(parser.rows)
    low = sum(1 for score in ocr.get('rec_scores', []) if float(score) < .8)
    return text, tables, low
