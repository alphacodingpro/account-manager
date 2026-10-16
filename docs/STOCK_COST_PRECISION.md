# Fractional stock cost precision

Migration 0051 widens movement unit-cost storage from numeric(18,2) to numeric(38,18). Existing movement amounts retain their values; it does not repair or revalue historical posted stock or journals. Product average cost remains four decimals; journal and allocated money remain two decimals.

The private dispatch cost-source view is dropped and recreated within the migration transaction because PostgreSQL prevents altering a column used by a view. No CASCADE is used. If an unexpected custom dependency exists the migration fails safely for review; public/anonymous/authenticated access to this internal view remains revoked. Existing stock RLS is unchanged.

Partial-dispatch return ratios carry 18-decimal numerator precision before division, enough to preserve rounded cents across the supported 15-digit quantity range. For example, a PKR 0.05 return of 3 units retains approximately 0.016666666666666667 per unit; the extended amount rounds to 0.05. The source return allocation snapshot remains the authoritative money value. No manual price edit is needed for the former two-decimal precision blocker.

All inbound opening/purchase/adjustment/return stock, including zero-cost movements, participates in weighted average calculation. Transfers retain the existing company-wide average policy. Finite positive quantities and finite nonnegative costs are enforced by the stock application function.

Voiding a sales credit note subtracts its original returned money value from current rounded stock value and recalculates the remaining average cost, instead of retaining an unrelated blended cost after stock leaves. Zero remaining quantity resets average to zero only when no unexplained money remains. Insufficient value or a residual with zero quantity blocks the whole void transaction and requires a reviewed valuation adjustment; the system does not silently write off the difference.

Database regression uses real posting/reversal and stock functions, production enum/numeric movement types, and the real audit function. It covers the formerly blocked fractional return and void, zero-cost return averaging, cumulative/voided return allocations, legacy movement value preservation, large-quantity precision arithmetic, permission preservation, NaN rejection and later-consumption reversal rollback. It is an isolated PostgreSQL fixture, not a substitute for a full production acceptance run.
