import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
const source = readFileSync(new URL('../src/lib/documentImport.ts', import.meta.url), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText;
const { extractBillFields, extractItemRows } = await import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`);
// Synthetic data reproducing wrapped invoice rows; no uploaded customer file.
const text = `EXAMPLE TRADERS
Invoice
Bill To: Invoice No.: 107
Date: 30/09/2026
# Item name Quantity Price/ Unit Amount
RECORDER-A
1 1 ₨ 14500.00 ₨ 14500.00
Serial No.: SAMPLE-001
CAMERA-B
2 3 ₨ 6600.00 ₨ 19800.00
Serial No.: SAMPLE-002, SAMPLE-003, SAMPLE-004
CAMERA-C
3 3 ₨ 6600.00 ₨ 19800.00
SWITCH-D
4 1 ₨ 6000.00 ₨ 6000.00
5 10X12 BOX 1 ₨ 1500.00 ₨ 1500.00
6 4X4-BOX 6 ₨ 100.00 ₨ 600.00
7 1U 1 ₨ 2000.00 ₨ 2000.00
8 CONNECTOR 100 ₨ 8.00 ₨ 800.00
Total 116 ₨ 65000.00
Sub Total ₨ 65000.00
Invoice Amount In Words
Total ₨ 65000.00`;
test('wrapped descriptions and serial numbers become eight complete bill lines', () => {
  const bill = extractBillFields(text);
  assert.equal(bill.items.length, 8);
  assert.equal(bill.items.reduce((n, i) => n + i.quantity, 0), 116);
  assert.equal(bill.items.reduce((n, i) => n + i.amount, 0), 65000);
  assert.equal(bill.items[0].description, 'RECORDER-A\nSerial No.: SAMPLE-001');
  assert.equal(bill.items[6].description, '1U');
  assert.equal(bill.supplier, 'EXAMPLE TRADERS');
  assert.equal(bill.reference, '107');
  assert.equal(bill.invoiceDate, '2026-09-30');
  assert.equal(bill.total, 65000);
  assert.equal(bill.gst, 0);
});
test('single-line OCR rows and grouped prices still work', () => {
  assert.deepEqual(extractItemRows('1 Cable 2 Rs 1,000.00 Rs 2,000.00'), [{description:'Cable',quantity:2,unitPrice:1000,amount:2000}]);
});
test('summary rows are never imported as products', () => {
  assert.equal(extractItemRows('Total 116 560.34 65000\nSub Total 1 65000 65000').length,0);
});
test('incorrect row arithmetic is rejected and missing amount raises a warning', () => {
  const bill = extractBillFields(text.replace('1 1 ₨ 14500.00 ₨ 14500.00', '1 1 ₨ 14500.00 ₨ 14000.00'));
  assert.equal(bill.items.length,7);
  assert.equal(bill.items[0].description, 'CAMERA-B\nSerial No.: SAMPLE-002, SAMPLE-003, SAMPLE-004');
  assert.ok(bill.warnings.some(w => w.includes('do not match')));
});
test('no zero GST is inferred when the printed totals differ', () => {
  const bill = extractBillFields('Cable 2 100 200\nSub Total 200\nTotal 236');
  assert.equal(bill.gst,null);
  assert.ok(bill.warnings.some(w => w.includes('do not balance')));
});
