import {useState} from "react";
import {activityChanges} from "./lib/activityChanges";
import "./ActivityDetails.css";
export default function ActivityDetails({before,after}:{before:Record<string,unknown>|null;after:Record<string,unknown>|null}){
 const [changedOnly,setChangedOnly]=useState(true);
 const all=activityChanges(before,after),rows=all.filter(row=>!changedOnly||row.changed);
 return <div className="activity-detail"><label className="activity-detail-filter"><input type="checkbox" checked={changedOnly} onChange={e=>setChangedOnly(e.target.checked)}/>Show changed fields only</label><div className="activity-detail-scroll"><table><thead><tr><th>Field</th><th>Before</th><th>After</th></tr></thead><tbody>{rows.map(row=><tr key={row.field} className={row.changed?"activity-field-changed":""}><th>{row.field.replaceAll("_"," ").replaceAll("."," › ")}</th><td>{row.before}</td><td>{row.after}</td></tr>)}</tbody></table></div>{!rows.length&&<p>No changed fields recorded. Clear the filter to review all saved fields.</p>}</div>;
}
