import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
const source = readFileSync(new URL('../src/lib/documentImport.ts', import.meta.url), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText;
const { extractBillFields, extractItemRows, extractTableItems } = await import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`);
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
test('structured tables support reordered columns and keep serial details', () => {
  const tables = [[['Amount','Quantity','Item name','Price/ Unit'],['Rs 200','2','Camera\nSerial No.: A, B','Rs 100'],['Rs 200','2','Total','Rs 100']]];
  assert.deepEqual(extractTableItems(tables),[{description:'Camera\nSerial No.: A, B',quantity:2,unitPrice:100,amount:200}]);
});
test('structured table mismatches and merged/incomplete rows need manual review', () => {
  assert.equal(extractTableItems([[['Item','Qty','Price','Amount'],['Cable','2','100','999'],['Camera','1']]]).length,0);
});
test('ambiguous spaced amounts are not silently joined into another number', () => {
  assert.equal(extractTableItems([[['Item','Qty','Price','Amount'],['Cable','1 2','10','120']]]).length,0);
});

const reviewSource = readFileSync(new URL('../src/lib/documentReview.ts', import.meta.url), 'utf8');
const reviewCompiled = ts.transpileModule(reviewSource, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText;
const { reviewDocumentLines } = await import(`data:text/javascript;base64,${Buffer.from(reviewCompiled).toString('base64')}`);
const validReviewLine = { description: 'Cable', quantity: '2', unitPrice: '100', gstRate: '18', accountId: 'expense-1' };
const printedReview = { subtotal: '200', gst: '36', total: '236' };
test('review reconciles all three printed amounts and identifies missing lines', () => {
  assert.equal(reviewDocumentLines([validReviewLine], printedReview, ['expense-1']).error, '');
  const missing = reviewDocumentLines([{ ...validReviewLine, quantity: '1' }], printedReview, ['expense-1']);
  assert.deepEqual(missing.differences, { subtotal: -100, gst: -18, total: -118 });
  assert.match(missing.error, /do not match/);
});
test('blank prices and GST cannot silently become zero and stale accounts are rejected', () => {
  for (const change of [{ unitPrice: '' }, { gstRate: '' }, { quantity: 'Infinity' }, { accountId: 'inactive-account' }]) {
    assert.match(reviewDocumentLines([{ ...validReviewLine, ...change }], printedReview, ['expense-1']).error, /Line 1/);
  }
  assert.match(reviewDocumentLines([], printedReview, ['expense-1']).error, /at least one/);
});
test('explicit zero price and zero GST remain valid, with line-level rounding', () => {
  const lines = [{ ...validReviewLine, quantity: '1', unitPrice: '0', gstRate: '0' }, { ...validReviewLine, quantity: '3', unitPrice: '0.33', gstRate: '0' }];
  const result = reviewDocumentLines(lines, { subtotal: '.99', gst: '0', total: '.99' }, ['expense-1']);
  assert.equal(result.error, '');
  assert.equal(result.totals.total, .99);
});

test("overflowing line arithmetic cannot pass review", () => {
  const result = reviewDocumentLines([{ ...validReviewLine, quantity: "1e300", unitPrice: "1e300" }], printedReview, ["expense-1"]);
  assert.match(result.error, /too large/);
});
