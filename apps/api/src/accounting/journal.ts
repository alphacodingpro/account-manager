export type JournalLine = { accountId: string; debit: number; credit: number };

const money = (value: number) => Math.round((value + Number.EPSILON) * 100);

export function validateJournal(lines: JournalLine[]): void {
  if (lines.length < 2) throw new Error('A journal entry requires at least two lines.');
  let debit = 0;
  let credit = 0;
  for (const line of lines) {
    if (!line.accountId) throw new Error('Every journal line requires an account.');
    if (line.debit < 0 || line.credit < 0) throw new Error('Debit and credit cannot be negative.');
    if ((line.debit > 0) === (line.credit > 0)) throw new Error('A line must contain either a debit or a credit.');
    debit += money(line.debit);
    credit += money(line.credit);
  }
  if (debit !== credit) throw new Error('Journal entry is not balanced.');
}

