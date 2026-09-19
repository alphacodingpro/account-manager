import { validateJournal } from './journal';

describe('validateJournal', () => {
  it('accepts a balanced entry', () => expect(() => validateJournal([
    { accountId: 'cash', debit: 1000, credit: 0 },
    { accountId: 'capital', debit: 0, credit: 1000 },
  ])).not.toThrow());

  it('rejects an unbalanced entry', () => expect(() => validateJournal([
    { accountId: 'cash', debit: 1000, credit: 0 },
    { accountId: 'sales', debit: 0, credit: 900 },
  ])).toThrow('not balanced'));
});

