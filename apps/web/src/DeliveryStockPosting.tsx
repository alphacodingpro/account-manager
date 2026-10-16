import {useState} from "react";
import {supabase} from "./lib/supabase";
import type {ReceiptPosting} from "./ReceiptStockPosting";
export function DeliveryStockPosting({deliveryId,posting,linked,onChanged}:{deliveryId:string;posting?:ReceiptPosting;linked:boolean;onChanged:()=>Promise<void>}){
 const [busy,setBusy]=useState(false),[message,setMessage]=useState("");
 async function act(action:"post"|"reverse"|"reopen"){
  let reason="";
  if(action==="post"&&!confirm("Dispatch these goods now at current inventory average cost? Stock will leave the selected warehouse. Review quantities first."))return;
  if(action==="reverse"){const value=prompt("Reason for reversing this dispatch (minimum 3 characters). Delete its invoice draft or void its posted invoice first. Later stock activity requires a valuation review.");if(value===null)return;reason=value.trim();if(reason.length<3){setMessage("Enter a reversal reason.");return;}}
  if(action==="reopen"&&!confirm("Prepare a replacement for the voided invoice? The old invoice stays in history."))return;
  setBusy(true);setMessage("");
  try{const result=await supabase.rpc(action==="post"?"post_goods_delivery":action==="reverse"?"reverse_goods_delivery":"reopen_goods_delivery_invoicing",{target_delivery:deliveryId,...(action==="reverse"?{reason}:{})});if(result.error)throw result.error;await onChanged();setMessage(action==="post"?"Goods dispatched. Create the invoice with full original quantities; posting it will not issue stock again.":action==="reverse"?"Dispatch reversed. Stock and ledger restored; source history preserved.":"Use Create invoice to prepare a replacement. The old voided invoice is preserved.");}
  catch(error){setMessage((error as {message?:string}).message||"Unable to process dispatch.");}finally{setBusy(false);}
 }
 return <section className="panel"><h3>Dispatch stock before invoicing</h3><p>Requires sales, inventory and accounting access. Posting issues stock at current average cost and records it in Goods Dispatched Not Invoiced (1210). The invoice later transfers this cost to COGS and records revenue/GST.</p>{message&&<p className="alert" role="status">{message}</p>}{posting?<><p>Status: <strong>{posting.status==="posted"?"Stock dispatched":"Reversed"}</strong> · Dispatch value: PKR {Number(posting.total).toFixed(2)}</p>{posting.status==="posted"&&<div className="form-actions">{linked&&<button type="button" className="outline" disabled={busy} onClick={()=>void act("reopen")}>Replace voided invoice</button>}<button type="button" className="outline" disabled={busy} onClick={()=>void act("reverse")}>Reverse stock dispatch</button></div>}</>:<button type="button" className="primary small-button" disabled={busy} onClick={()=>void act("post")}>Post stock dispatch</button>}<p>Full original quantities must match the invoice. Invoice voiding preserves dispatched stock. A dispatch reversal is blocked after later stock activity; positive inventory cost and sufficient warehouse stock are required.</p></section>;
}
