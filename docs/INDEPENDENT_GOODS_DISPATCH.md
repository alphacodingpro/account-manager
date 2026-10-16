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

The standard conversion matches full quantities; the allocated-invoice form supports split invoicing of a posted dispatch. Already converted drafts cannot be retrospectively stock-posted. Reversed dispatches cannot be reused. Existing ordinary invoices and unposted goods draft conversions keep their original stock posting behavior. Posted dispatch and receipt snapshots are immutable and company-scoped; audit triggers record source activity.

## Invoice a dispatch in parts

On a posted delivery without a full-invoice link, open View → Invoice dispatch in parts. Review dispatched, reserved and available quantities, set quantities to invoice (zero skips a product), review selling prices/GST and create an allocated invoice draft. Review reference and dates from Sales invoices before posting.

Draft and posted invoices reserve immutable product quantities. Delete a draft to change its allocation; invoice posting rejects changed allocated products/quantities. Prices/GST may be edited before posting. Voiding an unpaid posted invoice releases its quantity and restores only the allocated dispatch clearing cost. Stock stays dispatched. Existing payment and credit-note restrictions apply. Full conversion and active partial allocations cannot overlap. Retried saves with the same request UUID return the same draft.

Each invoice transfers only its cumulative share of original dispatch cost to COGS, with final rounding clearing the original cost exactly. Partial-invoice returns retain immutable cost snapshots; cumulative return costs account for earlier posted returns and voided return holes, so allocated COGS cannot be over-reversed. Return voiding restores the snapshot journal and stock movement. Inventory uses two-decimal movement unit costs: returns that cannot represent the exact allocated money value at that precision are blocked for a reviewed valuation adjustment, rather than silently changing valuation. Small negative rounding allocations are likewise blocked.

The generic posted correction shortcut cannot detach an allocated invoice from its dispatch. Void it and create another allocated invoice from the delivery. All active full/partial invoices must be deleted or voided before reversing dispatch; later stock activity still requires a separate valuation workflow.
