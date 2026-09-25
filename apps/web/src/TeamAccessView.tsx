import { useEffect, useState } from "react";
import { ShieldCheck, UserPlus, UserRoundCheck, X } from "lucide-react";
import { supabase } from "./lib/supabase";
import "./TeamAccessView.css";

type Role = "owner" | "admin" | "accountant" | "viewer";
type Member = { user_id: string; full_name: string; email: string; role: Role; active: boolean; joined_at: string };
type Invitation = { id: string; email: string; role: Exclude<Role, "owner">; expires_at: string; created_at: string };
const editableRoles: Role[] = ["owner", "admin", "accountant", "viewer"];
const inviteRoles: Exclude<Role, "owner">[] = ["admin", "accountant", "viewer"];
const roleLabel: Record<Role, string> = { owner: "Owner", admin: "Manager", accountant: "Accountant", viewer: "Read-only staff" };

export default function TeamAccessView({ companyId }: { companyId: string }) {
  const [isOwner, setIsOwner] = useState(false);
  const [members, setMembers] = useState<Member[]>([]);
  const [invitations, setInvitations] = useState<Invitation[]>([]);
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<Exclude<Role, "owner">>("accountant");
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);

  async function load() {
    const { data: owner } = await supabase.rpc("is_company_owner", { target_company: companyId });
    setIsOwner(Boolean(owner));
    if (!owner) return;
    const [memberResult, invitationResult] = await Promise.all([
      supabase.rpc("get_company_members", { target_company: companyId }),
      supabase.rpc("get_company_invitations", { target_company: companyId }),
    ]);
    if (memberResult.error || invitationResult.error) setMessage(memberResult.error?.message ?? invitationResult.error?.message ?? "Unable to load access settings.");
    else {
      setMembers((memberResult.data ?? []) as Member[]);
      setInvitations((invitationResult.data ?? []) as Invitation[]);
    }
  }

  useEffect(() => { load(); }, [companyId]);
  async function invite(e: React.FormEvent) {
    e.preventDefault(); setBusy(true); setMessage("");
    const { data, error } = await supabase.rpc("invite_company_member", { target_company: companyId, target_email: email, target_role: role });
    setMessage(error?.message ?? (data === "Member added" ? "Member access activated." : "Invitation saved. They must register or sign in with this email."));
    if (!error) { setEmail(""); await load(); }
    setBusy(false);
  }
  async function save(member: Member) {
    setBusy(true); setMessage("");
    const { error } = await supabase.rpc("update_company_member", { target_company: companyId, target_user: member.user_id, target_role: member.role, target_active: member.active });
    setMessage(error?.message ?? "Member access updated.");
    if (!error) await load();
    setBusy(false);
  }
  async function revoke(id: string) {
    setBusy(true); setMessage("");
    const { error } = await supabase.rpc("revoke_company_invitation", { target_invitation: id });
    setMessage(error?.message ?? "Invitation revoked.");
    if (!error) await load();
    setBusy(false);
  }
  function patchMember(userId: string, patch: Partial<Member>) {
    setMembers((current) => current.map((member) => member.user_id === userId ? { ...member, ...patch } : member));
  }

  if (!isOwner) return <article className="panel wide access-summary"><ShieldCheck/><div><h3>Company access</h3><p>Only a company owner can invite members or change access roles.</p></div></article>;
  return <article className="panel wide team-access">
    <div className="panel-head"><div><h3>Team access</h3><p>Invite users and control company-level permissions</p></div><ShieldCheck className="access-icon"/></div>
    <form className="member-invite" onSubmit={invite}>
      <label>Email address<input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="accountant@company.com" required/></label>
      <label>Access role<select value={role} onChange={(e) => setRole(e.target.value as Exclude<Role, "owner">)}>{inviteRoles.map((item) => <option key={item} value={item}>{roleLabel[item]}</option>)}</select></label>
      <button className="primary" disabled={busy}><UserPlus size={16}/>{busy ? "Saving…" : "Invite member"}</button>
    </form>
    <p className="access-help">Existing users receive access immediately. New users receive access automatically after registering with the same email.</p>
    {message && <p className="form-message">{message}</p>}
    <div className="member-list">
      <div className="member-row member-heading"><span>Team member</span><span>Role</span><span>Status</span><span>Action</span></div>
      {members.map((member) => <div className="member-row" key={member.user_id}>
        <span className="member-identity"><UserRoundCheck size={17}/><b>{member.full_name || member.email}</b><small>{member.full_name ? member.email : "CloudLedger user"}</small></span>
        <span><select value={member.role} onChange={(e) => patchMember(member.user_id, { role: e.target.value as Role })} disabled={busy}>{editableRoles.map((item) => <option key={item} value={item}>{roleLabel[item]}</option>)}</select></span>
        <span><label className="member-active"><input type="checkbox" checked={member.active} onChange={(e) => patchMember(member.user_id, { active: e.target.checked })} disabled={busy}/>{member.active ? "Active" : "Disabled"}</label></span>
        <span><button className="outline" onClick={() => save(member)} disabled={busy}>Save</button></span>
      </div>)}
    </div>
    {invitations.length>0 && <div className="pending-invites"><h4>Pending invitations</h4>{invitations.map((invitation) => <div key={invitation.id}><span><b>{invitation.email}</b><small>{roleLabel[invitation.role]} · expires {new Date(invitation.expires_at).toLocaleDateString("en-PK")}</small></span><button title="Revoke invitation" onClick={() => revoke(invitation.id)} disabled={busy}><X size={15}/></button></div>)}</div>}
  </article>;
}
