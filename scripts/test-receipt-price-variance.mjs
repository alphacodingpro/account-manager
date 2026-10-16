process.env.TEST_RECEIPT_VARIANCE='1';
await import('./test-costed-goods-receipts.mjs');
console.log('Receipt price variance: higher/lower bill cost, GST, complete GRNI clearing, retained stock valuation, void/rebill and custom account rollback passed.');
