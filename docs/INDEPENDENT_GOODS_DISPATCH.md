# Dispatch goods before invoicing

1. Open Delivery Notes and save an independent delivery draft with customer, warehouse, date and full product quantities.
2. Open View and choose Post stock dispatch. Review quantities first. Sales, inventory and accounting permissions are required. Positive inventory average cost and sufficient stock in the selected warehouse are required.
3. Dispatch atomically credits Inventory (1200), debits reserved system asset Goods Dispatched Not Invoiced (1210), and issues the stock at its current average cost. A conflicting custom 1210 account is preserved and prevents posting.
4. Choose Create invoice, review selling prices and GST, then post from Sales invoices. Full original product quantities, customer, branch and warehouse must match. The invoice records revenue/GST/receivable and transfers the original dispatch cost from 1210 to COGS (5000). It does not issue stock again.

The clearing-asset policy defers COGS until invoicing; stock physically leaves at dispatch. This is not a delivery-only revenue-recognition policy. No revenue or GST is posted on the dispatch itself.

## Corrections and returns

Voiding an unpaid invoice reverses revenue/GST/COGS and restores the dispatch clearing balance, keeping dispatched stock unchanged. On its delivery choose Replace voided invoice and then Create invoice. The old voided invoice remains in history. The generic posted-invoice correction shortcut is blocked for costed dispatches to avoid losing their source link. Existing payment/credit-note restrictions still apply.

Posted sales returns use the original dispatch cost and warehouse even if later purchases changed average cost. Supplier-side return behavior is unchanged.

Delete an unposted linked invoice or void its posted invoice before reversing the dispatch. Reverse stock dispatch requires a reason and restores stock, original average cost and the source journal atomically. Repeating the request does not repeat stock. Ledger-only reversal is blocked. Any later product stock movement blocks dispatch reversal because it requires a separate valuation adjustment workflow.

## Boundaries

Full quantities only; no split invoicing of a dispatch. Already converted drafts cannot be retrospectively stock-posted. Reversed dispatches cannot be reused. Existing ordinary invoices and unposted goods draft conversions keep their original stock posting behavior. Posted dispatch and receipt snapshots are immutable and company-scoped; audit triggers record source activity.
