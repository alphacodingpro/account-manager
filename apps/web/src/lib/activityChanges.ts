export type ActivityFieldChange = {field:string;before:string;after:string;changed:boolean};
function flatten(value:Record<string,unknown>|null,prefix=""):Record<string,unknown>{
 const result:Record<string,unknown>={};
 for(const [key,item] of Object.entries(value??{})){
  const path=prefix?`${prefix}.${key}`:key;
  if(item!==null&&typeof item==="object"&&!Array.isArray(item)&&Object.keys(item).length)Object.assign(result,flatten(item as Record<string,unknown>,path));
  else result[path]=item;
 }
 return result;
}
export function activityChanges(before:Record<string,unknown>|null,after:Record<string,unknown>|null):ActivityFieldChange[]{
 const old=flatten(before),next=flatten(after),format=(v:unknown)=>v==null?"—":typeof v==="object"?JSON.stringify(v,null,2):typeof v==="boolean"?v?"Yes":"No":String(v);
 return [...new Set([...Object.keys(old),...Object.keys(next)])].map(field=>({field,before:format(old[field]),after:format(next[field]),changed:JSON.stringify(old[field])!==JSON.stringify(next[field])})).sort((a,b)=>Number(b.changed)-Number(a.changed)||a.field.localeCompare(b.field));
}
