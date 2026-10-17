import { RecordView } from "./RecordTools";
import { useEffect, useState } from "react";
import { supabase } from "./lib/supabase";
import Modal, { statusClass, msgClass } from "./Modal";

type Contact = { id:string; name:string; email:string|null; phone:string|null; address:string|null; ntn:string|null; strn:string|null; active:boolean; kind:string };
const empty = {name:"",email:"",phone:"",address:"",ntn:"",strn:""};
export function ContactsView({companyId,kind}:{companyId:string;kind:"customer"|"supplier"}) {
  const [rows,setRows]=useState<Contact[]>([]), [query,setQuery]=useState(""), [message,setMessage]=useState("");
  const [form,setForm]=useState(empty), [editing,setEditing]=useState(""), [open,setOpen]=useState(false), [busy,setBusy]=useState(false), [loading,setLoading]=useState(true);
  const title=kind==="customer" ? "Customers" : "Suppliers";
  async function load(){
    setLoading(true);
    const all:Contact[]=[];
    for(let offset=0;;offset+=500){
      const r=await supabase.from("contacts").select("id,name,email,phone,address,ntn,strn,active,kind").eq("company_id",companyId).in("kind",[kind,"both"]).order("name").order("id").range(offset,offset+499);
      if(r.error){setMessage(r.error.message);setLoading(false);return;}
      all.push(...(r.data??[])); if((r.data??[]).length<500)break;
    }
    setRows(all);setLoading(false);
  }
  useEffect(()=>{void load();},[companyId,kind]);
  async function save(e:React.FormEvent){
    e.preventDefault();if(!form.name.trim())return setMessage("Name is required.");setBusy(true);setMessage("");
    try{
      const values={name:form.name.trim(),email:form.email.trim()||null,phone:form.phone.trim()||null,address:form.address.trim()||null,ntn:form.ntn.trim()||null,strn:form.strn.trim()||null};
      const r=editing ? await supabase.from("contacts").update(values).eq("company_id",companyId).eq("id",editing).select("id").single() : await supabase.from("contacts").insert({...values,company_id:companyId,kind}).select("id").single();
      if(r.error)throw r.error;setOpen(false);setEditing("");setForm(empty);await load();setMessage("Contact saved.");
    }catch(e){setMessage(e instanceof Error?e.message:(e as {message?:string}).message||"Unable to save contact.");}finally{setBusy(false);}
  }
  async function toggle(row:Contact){
    if(!confirm(`${row.active?"Deactivate":"Reactivate"} ${row.name}? Existing documents will be retained.${row.kind==="both"?" This affects both customer and supplier selections.":""}`))return;
    setBusy(true);const r=await supabase.from("contacts").update({active:!row.active}).eq("company_id",companyId).eq("id",row.id).select("id").single();
    if(r.error)setMessage(r.error.message);else{await load();setMessage(row.active?"Contact deactivated. Existing documents retained.":"Contact reactivated.");}setBusy(false);
  }
  const terms=query.toLowerCase().trim().split(/\s+/).filter(Boolean);
  const filtered=rows.filter(r=>terms.every(t=>[r.name,r.email,r.phone,r.address,r.ntn,r.strn,r.active?"active":"inactive"].join(" ").toLowerCase().includes(t)));
  return <article className="panel data-panel"><div className="panel-head"><div><h3>{title}</h3><p>Contact details and Pakistan tax registration</p></div><button className="primary small-button" onClick={()=>{setEditing("");setForm(empty);setOpen(true);setMessage("");}}>New {kind}</button></div>
    {message&&<p className={msgClass(message)} role="status">{message}</p>}
    {open&&<Modal onClose={()=>setOpen(false)} title={editing?`Edit ${kind}`:`New ${kind}`} size="md" subtitle={"Contact details and Pakistan tax registration (NTN / STRN)"} message={message}><form className="customer-form" onSubmit={save}>{Object.entries(form).map(([key,value])=><label key={key} className={key==="address"?"wide":undefined}>{({name:"Name",email:"Email",phone:"Phone",address:"Address",ntn:"NTN",strn:"STRN"} as Record<string,string>)[key]}<input value={value} type={key==="email"?"email":"text"} required={key==="name"} onChange={e=>setForm({...form,[key]:e.target.value})}/></label>)}<div className="form-actions wide"><button type="button" className="outline" onClick={()=>setOpen(false)}>Cancel</button><button className="primary" disabled={busy}>{busy?"Saving…":"Save"}</button></div></form></Modal>}
    <div className="invoice-list-toolbar"><label className="invoice-list-search"><input type="search" aria-label={`Search ${title}`} placeholder={`Search ${title.toLowerCase()}…`} value={query} onChange={e=>setQuery(e.target.value)}/></label><small>{filtered.length} of {rows.length}</small></div>
    {loading?<p>Loading contacts…</p>:<div className="account-table"><table className="contacts-table contacts-list"><thead><tr><th>Name</th><th>Phone / Email</th><th>Address</th><th>NTN / STRN</th><th>Status</th><th>Actions</th></tr></thead><tbody>{filtered.map(row=><tr key={row.id}><td>{row.name}</td><td>{row.phone||"—"}<br/>{row.email}</td><td>{row.address||"—"}</td><td>{row.ntn||"—"}<br/>{row.strn}</td><td><span className={statusClass(row.active?"Active":"Inactive")}>{row.active?"Active":"Inactive"}</span></td><td><RecordView companyId={companyId} table="contacts" id={row.id}/> <button className="outline" disabled={busy} onClick={()=>{setEditing(row.id);setForm({name:row.name,email:row.email||"",phone:row.phone||"",address:row.address||"",ntn:row.ntn||"",strn:row.strn||""});setOpen(true);}}>Edit</button> <button className={row.active?"outline danger-outline":"outline"} disabled={busy} onClick={()=>void toggle(row)}>{row.active?"Deactivate":"Reactivate"}</button></td></tr>)}</tbody></table>{!filtered.length&&<p className="mini-empty">No matching {title.toLowerCase()}.</p>}</div>}
  </article>;
}
