import { useEffect, useRef, useState } from "react";
import PdfButton from "./PdfButton";
import { pdfDate, pdfMoney, type PdfSpec } from "./lib/pdfExport";
import { journalEntryPdf, paymentVoucherPdf, purchaseBillPdf, purchaseDebitNotePdf, purchaseOrderPdf, salesCreditNotePdf, salesInvoicePdf, salesOrderPdf, salesQuotationPdf } from "./lib/documentPdf";
import { supabase } from "./lib/supabase";
import "./RecordTools.css";

import { matchesRecord } from "./lib/searchRecords";
export { matchesRecord };
export function ListSearch({ value, onChange, records }: { value: string; onChange: (value: string) => void; records?: unknown[] }) {
 const count=records?.filter(row=>matchesRecord(row,value)).length;
  return <div className="record-search"><label>Search this list<input type="search" value={value} onChange={e => onChange(e.target.value)} placeholder="Name, reference, date or amount…" /></label>{value && <button type="button" className="outline" onClick={() => onChange("")}>Clear</button>}{records&&<small role="status">{count} of {records.length} records{value&&count===0?" · No matching records":""}</small>}</div>;
}
const children: Record<string, [string,string]> = {
 employees:["employee_salary_components","employee_id"],sales_invoices:["sales_invoice_lines","invoice_id"],purchase_bills:["purchase_bill_lines","bill_id"],quotations:["quotation_lines","quotation_id"],sales_orders:["sales_order_lines","sales_order_id"],purchase_orders:["purchase_order_lines","purchase_order_id"],sales_credit_notes:["sales_credit_note_lines","credit_note_id"],purchase_debit_notes:["purchase_debit_note_lines","debit_note_id"],journal_entries:["journal_lines","entry_id"],payroll_runs:["payroll_items","payroll_run_id"]
};
const allowed = new Set([...Object.keys(children),"contacts","products","accounts","bank_accounts","employees","attendance","leave_requests","branches","stock_movements"]);
const hidden = new Set(["id","company_id","created_by","approved_by","updated_by"]);
const label = (s: string) => ({gst_rate:"GST %",gst_total:"GST total",ntn:"NTN",strn:"STRN",iban:"IBAN",quotations:"Quotation",sales_orders:"Sales order",purchase_orders:"Purchase order",sales_credit_notes:"Sales credit note",purchase_debit_notes:"Purchase debit note",journal_entries:"Journal entry",payroll_runs:"Payroll run",bank_accounts:"Bank account",employees:"Employee",branches:"Branch",attendance:"Attendance",leave_requests:"Leave request"} as Record<string,string>)[s]??s.replaceAll("_"," ").replace(/^./, c => c.toUpperCase());
function Details({ row, names }: { row: Record<string,unknown>; names: Record<string,string> }) {
 return <dl className="record-fields">{Object.entries(row).filter(([key])=>!hidden.has(key)).map(([key,value])=><div key={key}><dt>{label(key)}</dt><dd>{value == null ? "—" : typeof value === "boolean" ? value ? "Yes" : "No" : names[String(value)]??String(value)}</dd></div>)}</dl>;
}
const documentHeaders: Record<string,string[]> = {payroll_runs:["period_start","period_end"],quotations:["quotation_date","valid_until","notes"],sales_orders:["order_date","promised_date","customer_reference","notes"],purchase_orders:["order_date","expected_date","supplier_reference","notes"],sales_credit_notes:["credit_date","reason"],purchase_debit_notes:["debit_date","reason"],journal_entries:["entry_date","reference","description"]};
const documentLines: Record<string,string[]> = {quotations:["description","quantity","unit_price","gst_rate"],sales_orders:["description","quantity","unit_price","gst_rate"],purchase_orders:["description","quantity","unit_price","gst_rate"],sales_credit_notes:["quantity"],purchase_debit_notes:["quantity"],journal_entries:["description","debit","credit"]};
const project=(row:Record<string,unknown>,keys:string[])=>Object.fromEntries(keys.map(k=>[k,row[k]??null]));
const editable: Record<string, string[]> = {
 employees:["full_name","designation","department","phone","email","address","base_salary","monthly_income_tax","monthly_eobi","monthly_sessi","tax_enabled","eobi_enabled","sessi_enabled","active"],
 attendance:["status","check_in","check_out","overtime_hours","notes"],
 leave_requests:["leave_type","start_date","end_date","paid","reason"],
 bank_accounts:["name","bank_name","account_number","iban","active"],
 branches:["name","city","active"]
};
const pdfBuilders: Record<string, (id: string) => Promise<PdfSpec>> = {
  sales_invoices: salesInvoicePdf, purchase_bills: purchaseBillPdf, sales_credit_notes: salesCreditNotePdf, purchase_debit_notes: purchaseDebitNotePdf,
  sales_orders: salesOrderPdf, purchase_orders: purchaseOrderPdf, quotations: salesQuotationPdf, payments: paymentVoucherPdf, journal_entries: journalEntryPdf,
};
const hiddenFields = new Set(["id", "company_id", "created_by", "posted_by", "journal_entry_id", "reversal_of"]);

export function RecordView({ companyId, table, id, onSaved, draft = false }: { companyId: string; table: string; id: string; onSaved?: () => void | Promise<void>; draft?: boolean }) {
 const [names,setNames]=useState<Record<string,string>>({});
 const [lineForm,setLineForm]=useState<Record<string,unknown>[]>([]);
 const [editing,setEditing]=useState(false),[saving,setSaving]=useState(false),[form,setForm]=useState<Record<string,unknown>>({});
 const dialog=useRef<HTMLDialogElement>(null), request=useRef(0);
 const [row,setRow]=useState<Record<string,unknown>|null>(null),[lines,setLines]=useState<Record<string,unknown>[]>([]),[error,setError]=useState("");
 useEffect(()=>{request.current++;setRow(null);setLines([]);setNames({});dialog.current?.close();return()=>{request.current++;};},[companyId,id,table]);
 async function open(edit = false){
  setEditing(edit);
  const token=++request.current;setRow(null);setLines([]);setError("");dialog.current?.showModal();
  try{
   if(!allowed.has(table))throw new Error("Unsupported record type.");
   const result=await supabase.from(table).select("*").eq("company_id",companyId).eq("id",id).single();
   if(result.error)throw result.error;
   let details:Record<string,unknown>[]=[];
   if(children[table]){const [child,parent]=children[table];for(let offset=0;;offset+=500){const r=await supabase.from(child).select("*").eq(parent,id).order("id").range(offset,offset+499);if(r.error)throw r.error;details.push(...(r.data??[]));if((r.data??[]).length<500)break;}}
   const refs:Record<string,[string,string]>={customer_id:["contacts","name"],supplier_id:["contacts","name"],contact_id:["contacts","name"],product_id:["products","name"],account_id:["accounts","name"],expense_account_id:["accounts","name"],ledger_account_id:["accounts","name"],branch_id:["branches","name"],warehouse_id:["warehouses","name"],employee_id:["employees","full_name"],invoice_id:["sales_invoices","invoice_number"],bill_id:["purchase_bills","bill_number"]};
   const resolved:Record<string,string>={};
   await Promise.all(Object.entries(refs).map(async([key,[target,column]])=>{
    const ids=[...new Set([result.data,...details].map(r=>r[key]).filter(v=>typeof v==="string"))] as string[];
    for(let offset=0;offset<ids.length;offset+=100){const r=await supabase.from(target).select(`id,${column}`).eq("company_id",companyId).in("id",ids.slice(offset,offset+100));if(r.error)throw r.error;for(const item of r.data??[]){const value=item as unknown as Record<string,unknown>;resolved[String(value.id)]=column.endsWith("_number")?`${column==="invoice_number"?"INV":"BILL"}-${String(value[column]).padStart(6,"0")}`:String(value[column]);}}
   }));
   if(request.current===token){setNames(resolved);setRow(result.data);setForm(result.data);setLines(details);setLineForm(details);}
  }catch(e){if(request.current===token)setError((e as {message?:string}).message||"Unable to load record.");}
 }
 function recordPdf(): PdfSpec {
  const show = (key: string, value: unknown) => {
   if (value === null || value === undefined || value === "") return "-";
   if (typeof value === "boolean") return value ? "Yes" : "No";
   if (typeof value === "string" && names[value]) return names[value];
   if (typeof value === "string" && /^\d{4}-\d{2}-\d{2}/.test(value)) return /T/.test(value) ? pdfDate(value) : pdfDate(value);
   if (typeof value === "number" && /(amount|salary|price|total|balance|tax|eobi|sessi|cost|value)/i.test(key)) return pdfMoney(value);
   return String(value);
  };
  const entries = Object.entries(row ?? {}).filter(([key, value]) => !hiddenFields.has(key) && (!key.endsWith("_id") || (typeof value === "string" && names[value])) && typeof value !== "object");
  return { title: label(table), subtitle: "Record details", columns: [{ header: "Field", width: 60 }, { header: "Value" }], rows: entries.map(([key, value]) => [label(key), show(key, value)]), filename: `${table}-${String(id).slice(0, 8)}` };
 }
 const fields=editable[table]??documentHeaders[table]??[];
 const isDocument=Boolean(documentHeaders[table]);
 async function save(e: React.FormEvent){
  e.preventDefault();if(!row||!fields.length||saving)return;
  setSaving(true);setError("");
  try{
   if(table==="leave_requests"&&(row.status!=="pending"||String(form.end_date)<String(form.start_date)))throw new Error("Only pending leave with valid dates can be edited.");
   if(isDocument){
    if(table==="payroll_runs"){
     const r=await supabase.rpc("update_reviewed_payroll_period",{target_company:companyId,target_run:id,expected_start:row.period_start,expected_end:row.period_end,new_start:form.period_start,new_end:form.period_end});
     if(r.error)throw r.error;setEditing(false);await open();await onSaved?.();return;
    }
    if(row.status!=="draft")throw new Error("Only drafts can be edited. Reopen the record.");
    const columns=["id",...documentLines[table]];
    const r=await supabase.rpc("update_reviewed_draft",{target_company:companyId,record_kind:table,target_record:id,expected_header:project(row,fields),header:Object.fromEntries(fields.map(k=>[k,form[k]===""&&["valid_until","promised_date","expected_date"].includes(k)?null:form[k]??null])),expected_lines:lines.map(line=>project(line,columns)),items:lineForm.map(line=>project(line,columns))});
    if(r.error)throw r.error;setEditing(false);await open();await onSaved?.();return;
   }
   const values=Object.fromEntries(fields.map(k=>[k,form[k]===""?null:form[k]]));
   if((table==="employees"&&!String(form.full_name??"").trim())||(["bank_accounts","branches"].includes(table)&&!String(form.name??"").trim()))throw new Error("Name is required.");
   for(const key of ["base_salary","monthly_income_tax","monthly_eobi","monthly_sessi","overtime_hours"]){if(key in values){const n=Number(values[key]);if(!Number.isFinite(n)||n<0)throw new Error(`${label(key)} must be a non-negative number.`);values[key]=n;}}
   const result=await supabase.rpc("update_reviewed_master",{target_company:companyId,record_kind:table,target_record:id,expected_values:project(row,fields),new_values:values});
   if(result.error)throw result.error;
   setEditing(false);await open();await onSaved?.();
  }catch(e){setError((e as {message?:string}).message||"Unable to save record.");}finally{setSaving(false);}
 }
 return <><button type="button" className="outline small-button record-action" onClick={()=>void open()}>View</button>{fields.length>0&&(!isDocument||draft)&&<button type="button" className="outline small-button record-action" onClick={()=>void open(true)}>Edit</button>}<dialog className="record-dialog" ref={dialog} onCancel={e=>{if(saving)e.preventDefault();else request.current++;}} aria-label={`${label(table)} details`}><header><h3>{label(table)} details</h3><div className="record-head-actions">{row&&!editing&&<PdfButton className="outline" label="PDF" build={()=>pdfBuilders[table]?pdfBuilders[table](id):recordPdf()}/>}<button type="button" className="outline" disabled={saving} onClick={()=>{request.current++;dialog.current?.close();}}>Close</button></div></header>{error&&<p role="alert" className="alert">{error}</p>}{!row?!error&&<p role="status">Loading record…</p>:<>{editing&&fields.length>0&&(!isDocument||row.status==="draft")?<form onSubmit={e=>void save(e)}><p>{table==="payroll_runs"?"Changing the period recalculates draft payroll using current employee rules. Review all totals before posting.":isDocument?"Update draft details and existing lines together. Approved and posted records remain locked.":"Changes affect master data and future calculations. Posted accounting entries remain unchanged."}</p>{table==="leave_requests"&&row.status!=="pending"?<p>Reviewed leave is locked.</p>:<><div className="record-fields">{fields.map(key=><label key={key}>{label(key)}{typeof row[key]==="boolean"?<input type="checkbox" checked={Boolean(form[key])} onChange={e=>setForm({...form,[key]:e.target.checked})}/>:key==="status"&&table==="attendance"?<select value={String(form[key]??"")} onChange={e=>setForm({...form,[key]:e.target.value})}>{["present","absent","leave","holiday"].map(v=><option key={v}>{v}</option>)}</select>:<input type={key.endsWith("_date")||["valid_until","period_start","period_end"].includes(key)?"date":["check_in","check_out"].includes(key)?"time":["base_salary","monthly_income_tax","monthly_eobi","monthly_sessi","overtime_hours"].includes(key)?"number":key==="email"?"email":"text"} min="0" step="0.01" value={String(form[key]??"")} onChange={e=>setForm({...form,[key]:e.target.value})}/>}</label>)}</div>{isDocument&&documentLines[table]&&<div className="record-lines"><table><thead><tr><th>Line</th>{documentLines[table].map(k=><th key={k}>{label(k)}</th>)}</tr></thead><tbody>{lineForm.map((line,index)=><tr key={String(line.id)}><td>{index+1}</td>{documentLines[table].map(k=><td key={k}><input aria-label={`${label(k)} line ${index+1}`} type={k==="description"?"text":"number"} min={k==="quantity"?"0.001":"0"} max={k==="gst_rate"?"100":undefined} step={k==="quantity"?"0.001":"0.01"} required={k!=="description"||table!=="journal_entries"} value={String(line[k]??"")} onChange={e=>setLineForm(old=>old.map((v,i)=>i===index?{...v,[k]:k==="description"?e.target.value:e.target.value===""?"":Number(e.target.value)}:v))}/></td>)}</tr>)}</tbody></table><p>Existing item/account links are retained. Return prices follow the original invoice or bill.</p></div>}<button className="primary small-button" disabled={saving}>{saving?"Saving…":"Save changes"}</button></>} <button type="button" className="outline small-button" disabled={saving} onClick={()=>setEditing(false)}>Cancel</button></form>:<Details row={row.status==="draft"&&lines.length>0&&"total" in row?{...row,subtotal:lines.reduce((n,l)=>n+Number(l.subtotal??0),0),gst_total:lines.reduce((n,l)=>n+Number(l.gst_amount??0),0),total:lines.reduce((n,l)=>n+Number(l.total??0),0)}:row} names={names}/>}{children[table]&&(!editing||!documentLines[table])&&<section><h4>Lines ({lines.length})</h4>{lines.length?<div className="record-lines"><table><thead><tr>{Object.keys(lines[0]).filter(k=>!hidden.has(k)&&k!==children[table][1]).map(k=><th key={k}>{label(k)}</th>)}</tr></thead><tbody>{lines.map((line,i)=><tr key={String(line.id??i)}>{Object.entries(line).filter(([k])=>!hidden.has(k)&&k!==children[table][1]).map(([k,v])=><td key={k}>{v==null?"—":names[String(v)]??String(v)}</td>)}</tr>)}</tbody></table></div>:<p>No lines.</p>}</section>}</>}</dialog></>;
}
