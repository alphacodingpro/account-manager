process.env.TEST_STOCK_PRECISION='1';
await import('./test-partial-delivery-invoicing.mjs');
console.log('Stock cost precision: exact fractional return money, zero-cost weighted averaging, inverse return-void valuation, immutable historical amounts, finite-input guard and private view permissions passed.');
