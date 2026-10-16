const prefixes: Record<string,string[]> = {quotation_number:["QT"],order_number:["SO","PO"],invoice_number:["INV"],bill_number:["BILL"],entry_number:["JV"],credit_number:["CN"],debit_number:["DN"],payment_number:["PAY"]};
export function matchesRecord(value: unknown, query: string): boolean {
 const flatten=(v:unknown,key=""):string=>v==null?"":typeof v==="object"?Object.entries(v).map(([k,item])=>flatten(item,k)).join(" "):typeof v==="boolean"?v?"yes active true":"no inactive false":typeof v==="number"?`${v} ${v.toLocaleString("en-PK")} ${v.toLocaleString("en-PK",{minimumFractionDigits:2})} ${(prefixes[key]??[]).map(p=>`${p}-${String(v).padStart(p==="JV"?5:6,"0")}`).join(" ")}`:String(v);
 const text=flatten(value).toLocaleLowerCase();
 return query.toLocaleLowerCase().trim().split(/\s+/).filter(Boolean).every(term=>text.includes(term));
}
