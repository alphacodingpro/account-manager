export const sidebarSections = {
  Sales: [["invoices", "Sales invoices"], ["quotations", "Sales quotations"], ["orders", "Sales orders"], ["returns", "Returns & credit notes"], ["history", "Sales history"]],
  Purchases: [["bills", "Purchase bills"], ["orders", "Purchase orders"], ["returns", "Returns & supplier debit notes"]],
  Banking: [["accounts", "Bank accounts"], ["receipts", "Receipts"], ["payments", "Payments"], ["transactions", "All transactions"], ["reconciliation", "Bank reconciliation"]],
  Inventory: [["products","Products & services"],["stock","Warehouse stock"],["adjustments","Stock adjustments"],["transfers","Warehouse transfers"],["movements","Stock movements"]],
  Payroll: [["employees","Employees"],["attendance","Daily attendance"],["leave","Leave management"],["runs","Payroll runs"]],
  Settings: [["company","Company details"],["branches","Branches"],["team","Team & permissions"]],
} as const;

export type SidebarGroup = { id: string; label: string; items: { id: string; label: string }[] };
export const sidebarItemId = (group: string, item: string) => `${group}:${item}`;
export const sidebarPreferenceKey = (user: string, company: string) => `cloudledger.sidebar.v1:${encodeURIComponent(user)}:${encodeURIComponent(company)}`;
export function readSidebarPreferences(key: string): string[] {
 try { const value = JSON.parse(localStorage.getItem(key) ?? "null"); return value?.version === 1 && Array.isArray(value.hidden) ? [...new Set(value.hidden.filter((id: unknown): id is string => typeof id === "string" && id.length < 200))] as string[] : []; } catch { return []; }
}
export function saveSidebarPreferences(key: string, hidden: string[]): boolean {
 try { localStorage.setItem(key, JSON.stringify({ version: 1, hidden: [...new Set(hidden)] })); return true; } catch { return false; }
}
export function sidebarGroupVisible(hidden: string[], group: SidebarGroup): boolean {
 return !hidden.includes(group.id) && (group.items.length === 0 || group.items.some(item => !hidden.includes(item.id)));
}
