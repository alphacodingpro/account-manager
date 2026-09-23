import { dayDistance, parseStatementCsv } from "../../../web/src/lib/bankCsv";

describe("bank statement CSV", () => {
  it("parses Pakistani day-first dates, quoted narration and debit/credit columns", () => {
    const rows = parseStatementCsv('Date,Description,Reference,Debit,Credit\n23/09/2026,"Bank fee, monthly",FEE-1,"1,250.50",\n24/09/2026,Customer transfer,TRX-2,,5000');
    expect(rows).toHaveLength(2);
    expect(rows[0]).toMatchObject({ transaction_date: "2026-09-23", description: "Bank fee, monthly", debit: 1250.5, credit: 0, source_row: 2 });
    expect(rows[1]).toMatchObject({ transaction_date: "2026-09-24", debit: 0, credit: 5000, source_row: 3 });
  });

  it("supports signed Amount statements and rejects ambiguous zero-value rows", () => {
    const rows = parseStatementCsv("Transaction Date,Narration,Amount\n2026-09-20,Supplier,-2500\n2026-09-21,Customer,4000");
    expect(rows.map(({ debit, credit }) => ({ debit, credit }))).toEqual([{ debit: 2500, credit: 0 }, { debit: 0, credit: 4000 }]);
    expect(() => parseStatementCsv("Date,Debit,Credit\n2026-09-20,0,0")).toThrow("exactly one debit or credit");
  });

  it("calculates absolute date distance for match ranking", () => {
    expect(dayDistance("2026-09-20", "2026-09-23")).toBe(3);
    expect(dayDistance("2026-09-25", "2026-09-23")).toBe(2);
  });
});
