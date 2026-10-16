# Receive known-cost stock before the supplier bill

1. Open Goods Receipts and save a new independent goods draft with supplier, warehouse, date and product quantities.
2. Open **View** on that draft. In **Receive stock before billing**, review each unit cost excluding GST, then choose **Post stock receipt**. Purchase, inventory and accounting permissions are all required.
3. The system posts **Inventory debit / Goods Received Not Invoiced (GRNI) credit** and receives stock atomically. Receipt GRNI is reserved system liability account 2020. Existing conflicting accounts are preserved and must be reviewed before this feature can post.
4. Choose **Create bill** on the receipt. Receipt costs are prefilled; review the bill's GST and due date.
5. Review and post the draft in Purchase bills. The standard full-bill flow must match the full receipt; for split quantities use Bill receipt in parts below. The bill clears the original GRNI amount, records input GST and credits the actual Accounts Payable. Higher or lower bill prices are expensed as a debit or credit to reserved system expense account 5060, Purchase Price Variance. An existing conflicting account is preserved and blocks posting. Stock quantity and weighted average cost remain at receipt valuation; this is an expense variance policy, not retrospective inventory revaluation. It does not receive stock again.

## Correct a bill

Void its posted bill through Purchases; reverse payments/returns first when required by existing source controls. The bill reversal restores GRNI without removing the received stock. On the receipt use **Replace voided bill**, then **Create bill** to prepare a replacement. The old voided bill stays in history.

## Reverse an unused receipt

Delete its linked unposted bill or void its posted bill first, then use **Reverse stock receipt** with a reason. This restores the original product average cost and quantity and reverses the receipt's journal in one transaction. The source record stays read-only.

Receipt reversal is intentionally blocked if any later stock movement exists for a product on the receipt; changing an earlier receipt after sales/transfers/returns needs a separate valuation workflow. A reversed receipt cannot be reposted or billed: create a new draft.

## Current boundaries

- Known, positive unit costs with two decimals; full or allocated receipt quantity matching. Bill prices may differ.
- GST is recorded on the supplier bill, never claimed on an unbilled receipt.
- Partial dispatch invoicing, retrospective inventory cost adjustments and reversal after later stock activity remain separate roadmap items. Independent delivery posting is documented in INDEPENDENT_GOODS_DISPATCH.md.
- Draft goods documents and invoice/bill-backed printouts do not independently move stock.

## Price difference example

Receive 2 units at PKR 100: inventory 200 / GRNI 200. A bill at PKR 110 plus 18% GST clears GRNI 200, debits price variance 20 and input GST 39.60, and credits payable 259.60. A bill at PKR 90 produces a variance credit of 20. Voiding the bill reverses its variance and GST without moving stock. Purchase returns retain the existing current-average-cost inventory policy; the difference from supplier credit goes to Purchase Return Variance (5050).

## Split a receipt across bills

On a posted receipt without an existing full-bill link, open View → Bill receipt in parts. The table shows received, reserved and available quantities. Enter quantities to bill (zero skips a product), review selling supplier prices/GST and due date, then Create allocated bill draft. Review the supplier reference, bill date and due date in Purchases before posting.

Each draft reserves an immutable product/quantity allocation. Its bill may change prices, GST, description and dates, but posting rejects changed allocated products or quantities. To change an allocation, delete its draft and create another. Draft deletion or posted bill void releases the reservation; returns alone do not release it. Posted bills retain payment/return void restrictions. Reverse or delete all active allocated bills before reversing the receipt.

A request UUID prevents an interrupted save from creating duplicate drafts on retry with the same data. Full-bill conversion and active partial allocations cannot overlap. The full-bill shortcut remains available for receipts without active partial allocations; otherwise use the partial form.

Each bill clears only its allocated receipt cost, and records its actual GST/payable and price variance. Cumulative rounding clears the exact original receipt accrual after all active quantities are billed. Very small re-allocations after voiding rounded allocations can require a larger quantity or a reviewed correction; the system blocks a negative cost allocation rather than posting it. Stock is never received again by allocation, posting, voiding or replacing these bills.
