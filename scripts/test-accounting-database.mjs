import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
// These fixtures use isolated embedded PostgreSQL databases, never production.
const suites=[
 'test-costed-goods-receipts.mjs','test-receipt-price-variance.mjs',
 'test-atomic-sales-drafts.mjs','test-atomic-purchase-drafts.mjs',
 'test-manual-reversal-guards.mjs',
 'test-inter-account-transfers.mjs','test-expense-claims.mjs',
 'test-expense-reimbursement.mjs','test-partial-claim-reimbursement.mjs',
 'test-claim-approvals.mjs','test-claim-attachments.mjs',
 'test-late-payment-fees.mjs','test-purchase-quotes.mjs',
 'test-inventory-writeoffs.mjs','test-goods-drafts.mjs',
 'test-goods-receipt-conversion.mjs','test-goods-delivery-conversion.mjs',
 'test-goods-handover.mjs','test-partial-goods-handover.mjs',
];
for(const suite of suites){
 console.log(`\nDatabase regression: ${suite}`);
 const result=spawnSync(process.execPath,[`scripts/${suite}`],{cwd:root,stdio:'inherit',timeout:60000});
 if(result.error||result.status!==0){console.error(`FAILED: ${suite}`,result.error?.message??result.signal??result.status);process.exit(1);}
}
console.log(`\n${suites.length} isolated accounting/database regression suites passed.`);
