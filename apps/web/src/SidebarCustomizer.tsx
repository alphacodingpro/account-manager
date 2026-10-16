import { useEffect, useRef, useState } from "react";
import { saveSidebarPreferences, type SidebarGroup } from "./lib/sidebarPreferences";
import "./SidebarCustomizer.css";
function GroupCheckbox({checked,partial,onChange,label}:{checked:boolean;partial:boolean;onChange:()=>void;label:string}){
 const ref=useRef<HTMLInputElement>(null);useEffect(()=>{if(ref.current)ref.current.indeterminate=partial;},[partial]);
 return <label className="sidebar-customize-group"><input ref={ref} type="checkbox" checked={checked} onChange={onChange}/><strong>{label}</strong></label>;
}
export default function SidebarCustomizer({storageKey,groups,hidden,onSaved,onCancel}:{storageKey:string;groups:SidebarGroup[];hidden:string[];onSaved:(hidden:string[])=>void;onCancel:()=>void}){
 const [draft,setDraft]=useState(hidden),[message,setMessage]=useState("");
 const visible=(id:string)=>!draft.includes(id);
 function toggle(ids:string[],show:boolean){setDraft(old=>show?old.filter(id=>!ids.includes(id)):[...new Set([...old,...ids])]);setMessage("");}
 function save(){if(!saveSidebarPreferences(storageKey,draft)){setMessage("Unable to save in this browser. Allow browser storage and try again. Your sidebar has not changed.");return;}onSaved(draft);setMessage("Sidebar preferences saved.");}
 return <article className="panel sidebar-customizer"><div className="panel-head"><div><h3>Choose your sidebar</h3><p>Checked items appear in the sidebar. This changes navigation only, never access permissions or accounting data.</p></div></div><p className="muted">Saved separately for your user and active company in this browser. Customize sidebar always remains available below the menu.</p><div className="sidebar-customize-actions"><button type="button" className="outline small-button" onClick={()=>{setDraft([]);setMessage("");}}>Restore defaults</button><button type="button" className="outline small-button" onClick={()=>toggle(groups.flatMap(g=>[g.id,...g.items.map(i=>i.id)]),false)}>Hide all</button></div>
 <div className="sidebar-customize-grid">{groups.map(group=>{
  const selected=visible(group.id)?group.items.filter(i=>visible(i.id)).length:0;
  const checked=visible(group.id)&&(group.items.length===0||selected===group.items.length);
  return <fieldset key={group.id}><legend><GroupCheckbox label={group.label} checked={checked} partial={selected>0&&selected<group.items.length} onChange={()=>toggle([group.id,...group.items.map(i=>i.id)],!checked)}/></legend>{group.items.map(item=><label key={item.id} className="sidebar-customize-item"><input type="checkbox" checked={visible(group.id)&&visible(item.id)} onChange={e=>{if(e.target.checked)toggle([group.id,item.id],true);else toggle([item.id],false);}}/>{item.label}</label>)}</fieldset>;
 })}</div>{message&&<p role="status" className={message.startsWith("Unable")?"alert":"notice"}>{message}</p>}<div className="sidebar-customize-actions"><button type="button" className="primary small-button" onClick={save}>Save sidebar</button><button type="button" className="outline small-button" onClick={onCancel}>Cancel</button></div></article>;
}
