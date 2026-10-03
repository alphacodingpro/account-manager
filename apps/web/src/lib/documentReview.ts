export type ReviewLine = { description: string; quantity: string; unitPrice: string; gstRate: string; accountId: string };
export function reviewDocumentLines(lines: ReviewLine[], printed: { subtotal: string; gst: string; total: string }, eligibleAccountIds: string[]) {
  const round = (value: number) => Math.round(value * 100) / 100;
  const totals = { subtotal: 0, gst: 0, total: 0 };
  let error = "";
  if (!lines.length) error = "Add at least one invoice item line.";
  for (const [index, line] of lines.entries()) {
    const qty = Number(line.quantity), price = Number(line.unitPrice), rate = Number(line.gstRate);
    if (!line.description.trim() || ![line.quantity, line.unitPrice, line.gstRate].every((value) => value.trim()) || ![qty, price, rate].every(Number.isFinite) || qty <= 0 || price < 0 || rate < 0 || rate > 100 || !eligibleAccountIds.includes(line.accountId)) {
      error ||= `Line ${index + 1}: enter description, quantity, price, GST rate and an active expense account.`;
      continue;
    }
    totals.subtotal += round(qty * price);
    totals.gst += round(qty * price * rate / 100);
    totals.total += round(qty * price * (1 + rate / 100));
  }
  if (!Object.values(totals).every(Number.isFinite)) error ||= "Line amounts are too large. Correct quantities or prices.";
  const values = [printed.subtotal, printed.gst, printed.total];
  const [sub, tax, grand] = values.map(Number);
  if (!values.every((value) => value.trim()) || ![sub, tax, grand].every(Number.isFinite) || sub <= 0 || tax < 0 || grand <= 0) error ||= "Enter a positive printed subtotal and total, and non-negative GST.";
  else if (Math.abs(sub + tax - grand) > .02000001) error ||= "Printed subtotal + GST must equal printed total.";
  const differences = { subtotal: round(totals.subtotal - sub), gst: round(totals.gst - tax), total: round(totals.total - grand) };
  if (Object.values(differences).some((value) => Math.abs(value) > .02)) error ||= "Bill lines do not match the printed amounts. Correct missing items or tax rates before applying.";
  return { totals, differences, error };
}
