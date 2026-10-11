import { useEffect, useMemo, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import {
  BarChart3,
  Bell,
  Building2,
  ChevronDown,
  CircleDollarSign,
  FileText,
  Landmark,
  LayoutDashboard,
  LogOut,
  Menu,
  Package,
  Plus,
  ReceiptText,
  Search,
  Settings,
  ShieldCheck,
  ShoppingCart,
  Sparkles,
  TrendingUp,
  Users,
  WalletCards,
  X,
} from "lucide-react";
import { isSupabaseConfigured, supabase } from "./lib/supabase";
import AccountingView from "./AccountingView";
import SalesView from "./SalesView";
import InventoryView from "./InventoryView";
import PurchasesView from "./PurchasesView";
import PayrollView from "./PayrollView";
import ReportsView from "./ReportsView";
import BankingView from "./BankingView";
import TeamAccessView from "./TeamAccessView";

type Company = {
  id: string;
  name: string;
  legal_name: string | null;
  currency_code: string;
  ntn: string | null;
  strn: string | null;
  gst_registered: boolean;
};
type Branch = {
  id: string;
  code: string;
  name: string;
  city: string | null;
  active: boolean;
};
type Account = {
  id: string;
  code: string;
  name: string;
  type: "asset" | "liability" | "equity" | "income" | "expense";
  active: boolean;
  system_account: boolean;
};
type DashboardSummary = {
  cash_balance: number;
  receivables: number;
  payables: number;
  income: number;
  expenses: number;
  net_profit: number;
  invoice_count: number;
  overdue_count: number;
  sales_total: number;
  recent_transactions: Array<{
    id: string;
    entry_date: string;
    reference: string | null;
    description: string | null;
    status: string;
    amount: number;
  }>;
  monthly_trend: Array<{
    month_start: string;
    label: string;
    income: number;
    expenses: number;
  }>;
};
const emptySummary: DashboardSummary = {
  cash_balance: 0,
  receivables: 0,
  payables: 0,
  income: 0,
  expenses: 0,
  net_profit: 0,
  invoice_count: 0,
  overdue_count: 0,
  sales_total: 0,
  recent_transactions: [],
  monthly_trend: [],
};
type ViewName =
  | "Overview"
  | "Accounting"
  | "Sales"
  | "Purchases"
  | "Banking"
  | "Inventory"
  | "Payroll"
  | "Reports"
  | "Settings";
type AccessRole = "owner" | "admin" | "accountant" | "sales" | "purchases" | "inventory" | "payroll" | "viewer" | "custom";
const money = new Intl.NumberFormat("en-PK", {
  style: "currency",
  currency: "PKR",
  maximumFractionDigits: 0,
});
const nav: [ViewName, typeof LayoutDashboard][] = [
  ["Overview", LayoutDashboard],
  ["Accounting", WalletCards],
  ["Sales", ReceiptText],
  ["Purchases", ShoppingCart],
  ["Banking", Landmark],
  ["Inventory", Package],
  ["Payroll", Users],
  ["Reports", BarChart3],
  ["Settings", Settings],
];

function Login({ onDemo }: { onDemo: () => void }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const [createAccount, setCreateAccount] = useState(false);
  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!isSupabaseConfigured)
      return setMessage("Supabase environment variables are missing.");
    setBusy(true);
    const result = createAccount
      ? await supabase.auth.signUp({ email, password })
      : await supabase.auth.signInWithPassword({ email, password });
    setMessage(result.error?.message ?? (createAccount && !result.data.session ? "Check your email to confirm your account, then sign in." : ""));
    setBusy(false);
  }
  return (
    <main className="login-page">
      <section className="login-brand">
        <div className="logo">CL</div>
        <h1>
          CloudLedger <span>PK</span>
        </h1>
        <p>Professional accounting built for growing Pakistani businesses.</p>
        <ul>
          <li>Multi-company and multi-branch</li>
          <li>Secure double-entry accounting</li>
          <li>GST, inventory and payroll ready</li>
        </ul>
      </section>
      <section className="login-card">
        <div>
          <p className="eyebrow">WELCOME BACK</p>
          <h2>{createAccount ? "Create your account" : "Sign in to your account"}</h2>
          <p className="muted">{createAccount ? "Use the same email where your company invitation was sent." : "Use your company email and password."}</p>
        </div>
        <form onSubmit={submit}>
          <label>
            Email address
            <input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="name@company.com"
              required
            />
          </label>
          <label>
            Password
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="••••••••"
              required
            />
          </label>
          <button className="primary" disabled={busy}>
            {busy ? "Please wait..." : createAccount ? "Create account" : "Sign in"}
          </button>
        </form>
        {message && <p className="form-message error">{message}</p>}
        <button className="demo" onClick={() => { setCreateAccount((value) => !value); setMessage(""); }}>
          {createAccount ? "Already registered? Sign in" : "New invited user? Create account"}
        </button>
        <button className="demo" onClick={onDemo}>
          Preview dashboard
        </button>
        <p className="legal">
          Your financial data is isolated by company and protected by row-level
          security.
        </p>
      </section>
    </main>
  );
}

function CompanyOnboarding({ onCreated }: { onCreated: (id: string) => void }) {
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function create(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    const { data, error } = await supabase.rpc("create_company", {
      company_name: name,
    });
    if (error) setError(error.message);
    else onCreated(data as string);
    setBusy(false);
  }
  return (
    <main className="onboarding">
      <section>
        <div className="logo">CL</div>
        <p className="eyebrow">FIRST-TIME SETUP</p>
        <h1>Create your first company</h1>
        <p className="muted">
          We will create a Head Office branch and Pakistan-ready Chart of
          Accounts.
        </p>
        <form onSubmit={create}>
          <label>
            Company name
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="e.g. UltraNet Security"
              minLength={2}
              required
            />
          </label>
          <button className="primary" disabled={busy}>
            {busy ? "Creating company..." : "Create company"}
          </button>
        </form>
        {error && <p className="form-message error">{error}</p>}
      </section>
    </main>
  );
}

const Metric = ({
  label,
  value,
  detail,
  tone = "blue",
}: {
  label: string;
  value: string;
  detail: string;
  tone?: string;
}) => (
  <article className={`metric metric-${tone}`}>
    <div className={`metric-icon ${tone}`}>
      <CircleDollarSign size={21} />
    </div>
    <div>
      <p>{label}</p>
      <h3>{value}</h3>
      <span><TrendingUp size={13} /> {detail}</span>
    </div>
    <div className="metric-glow" />
  </article>
);
function Overview({
  branches,
  accounts,
  summary,
}: {
  branches: Branch[];
  accounts: Account[];
  summary: DashboardSummary;
}) {
  const maxTrend = Math.max(
    1,
    ...summary.monthly_trend.flatMap((m) => [
      Number(m.income),
      Number(m.expenses),
    ]),
  );
  return (
    <>
      <div className="metrics">
        <Metric
          label="Cash & bank"
          value={money.format(summary.cash_balance)}
          detail={`${branches.length} active branch${branches.length === 1 ? "" : "es"}`}
        />
        <Metric
          label="Receivables"
          value={money.format(summary.receivables)}
          detail={`${summary.overdue_count} overdue invoice${summary.overdue_count === 1 ? "" : "s"}`}
          tone="green"
        />
        <Metric
          label="Payables"
          value={money.format(summary.payables)}
          detail="Posted supplier balance"
          tone="orange"
        />
        <Metric
          label="Net profit"
          value={money.format(summary.net_profit)}
          detail={`${money.format(summary.income)} income`}
          tone="purple"
        />
      </div>
      <div className="grid">
        <article className="panel chart-panel">
          <div className="panel-head">
            <div>
              <h3>Income vs expenses</h3>
              <p>Last six months · posted entries</p>
            </div>
            <span className="legend">
              <i />
              Income <i className="expense" />
              Expenses
            </span>
          </div>
          <div className="live-chart">
            {summary.monthly_trend.map((m) => (
              <div className="live-bars" key={m.month_start}>
                <div>
                  <span
                    className="income-bar"
                    style={{
                      height: `${Math.max(2, (Number(m.income) / maxTrend) * 100)}%`,
                    }}
                  />
                  <span
                    className="expense-bar"
                    style={{
                      height: `${Math.max(2, (Number(m.expenses) / maxTrend) * 100)}%`,
                    }}
                  />
                </div>
                <small>{m.label}</small>
              </div>
            ))}
          </div>
        </article>
        <article className="panel">
          <div className="panel-head">
            <div>
              <h3>Business snapshot</h3>
              <p>Live company totals</p>
            </div>
          </div>
          <div className="snapshot">
            <div>
              <span>Total sales</span>
              <b>{money.format(summary.sales_total)}</b>
            </div>
            <div>
              <span>Posted invoices</span>
              <b>{summary.invoice_count}</b>
            </div>
            <div>
              <span>Expenses</span>
              <b>{money.format(summary.expenses)}</b>
            </div>
            <div>
              <span>Ledger accounts</span>
              <b>{accounts.length}</b>
            </div>
          </div>
        </article>
        <article className="panel wide">
          <div className="panel-head">
            <div>
              <h3>Recent transactions</h3>
              <p>Latest posted journal activity</p>
            </div>
          </div>
          {summary.recent_transactions.length === 0 ? (
            <div className="mini-empty">
              <FileText />
              <p>No posted transactions yet.</p>
            </div>
          ) : (
            <div className="dashboard-transactions">
              <div className="dashboard-row data-heading">
                <span>Date</span>
                <span>Reference</span>
                <span>Description</span>
                <span>Amount</span>
                <span>Status</span>
              </div>
              {summary.recent_transactions.map((t) => (
                <div className="dashboard-row" key={t.id}>
                  <span>{t.entry_date}</span>
                  <span className="code">{t.reference || "—"}</span>
                  <span>{t.description || "Journal entry"}</span>
                  <b>{money.format(Number(t.amount))}</b>
                  <span className="status">{t.status}</span>
                </div>
              ))}
            </div>
          )}
        </article>
      </div>
    </>
  );
}

function Accounting({ accounts }: { accounts: Account[] }) {
  return (
    <article className="panel data-panel">
      <div className="panel-head">
        <div>
          <h3>Chart of Accounts</h3>
          <p>Live accounts for the active company</p>
        </div>
        <button className="outline" disabled>
          <Plus size={16} /> Add account
        </button>
      </div>
      <div className="data-table account-table">
        <div className="data-row data-heading">
          <span>Code</span>
          <span>Account name</span>
          <span>Type</span>
          <span>Status</span>
        </div>
        {accounts.map((a) => (
          <div className="data-row" key={a.id}>
            <span className="code">{a.code}</span>
            <span>
              {a.name}
              {a.system_account && <small className="tag">System</small>}
            </span>
            <span className="capitalize">{a.type}</span>
            <span className="status">{a.active ? "Active" : "Inactive"}</span>
          </div>
        ))}
      </div>
    </article>
  );
}

function SettingsView({
  company,
  branches,
  onRefresh,
}: {
  company: Company;
  branches: Branch[];
  onRefresh: () => void;
}) {
  const [code, setCode] = useState("");
  const [name, setName] = useState("");
  const [city, setCity] = useState("");
  const [message, setMessage] = useState("");
  async function addBranch(e: React.FormEvent) {
    e.preventDefault();
    const { error } = await supabase.from("branches").insert({
      company_id: company.id,
      code: code.toUpperCase(),
      name,
      city: city || null,
    });
    if (error) setMessage(error.message);
    else {
      setCode("");
      setName("");
      setCity("");
      setMessage("Branch added.");
      onRefresh();
    }
  }
  return (
    <div className="settings-grid">
      <article className="panel">
        <div className="panel-head">
          <div>
            <h3>Company details</h3>
            <p>Legal and tax identity</p>
          </div>
        </div>
        <dl className="details">
          <div>
            <dt>Company</dt>
            <dd>{company.name}</dd>
          </div>
          <div>
            <dt>Currency</dt>
            <dd>{company.currency_code}</dd>
          </div>
          <div>
            <dt>NTN</dt>
            <dd>{company.ntn || "Not configured"}</dd>
          </div>
          <div>
            <dt>STRN</dt>
            <dd>{company.strn || "Not configured"}</dd>
          </div>
          <div>
            <dt>GST</dt>
            <dd>{company.gst_registered ? "Registered" : "Not registered"}</dd>
          </div>
        </dl>
      </article>
      <article className="panel">
        <div className="panel-head">
          <div>
            <h3>Add branch</h3>
            <p>Create a branch-specific accounting location</p>
          </div>
        </div>
        <form className="branch-form" onSubmit={addBranch}>
          <label>
            Branch code
            <input
              value={code}
              onChange={(e) => setCode(e.target.value)}
              placeholder="KHI"
              maxLength={10}
              required
            />
          </label>
          <label>
            Branch name
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Karachi Office"
              required
            />
          </label>
          <label>
            City
            <input
              value={city}
              onChange={(e) => setCity(e.target.value)}
              placeholder="Karachi"
            />
          </label>
          <button className="primary">Add branch</button>
        </form>
        {message && <p className="form-message">{message}</p>}
      </article>
      <article className="panel wide">
        <div className="panel-head">
          <div>
            <h3>Branches</h3>
            <p>{branches.length} locations in this company</p>
          </div>
        </div>
        <div className="branch-list">
          {branches.map((b) => (
            <div key={b.id}>
              <Building2 />
              <span>
                <b>{b.name}</b>
                <small>
                  {b.code} · {b.city || "City not set"}
                </small>
              </span>
              <em>{b.active ? "Active" : "Inactive"}</em>

            </div>
          ))}
        </div>
      </article>
      <TeamAccessView companyId={company.id} />
    </div>
  );
}
function Placeholder({ title }: { title: string }) {
  return (
    <article className="panel empty-state module-placeholder">
      <Package />
      <h2>{title}</h2>
      <p>
        The accounting foundation is ready. This module will be implemented in
        the next product milestone.
      </p>
    </article>
  );
}

function Dashboard({
  session,
  demo = false,
}: {
  session: Session | null;
  demo?: boolean;
}) {
  const [menu, setMenu] = useState(false);
  const [view, setView] = useState<ViewName>("Overview");
  const [payrollExpanded, setPayrollExpanded] = useState(false);
  const [payrollSection, setPayrollSection] = useState<"employees" | "attendance" | "leave" | "runs">("employees");
  const [inventoryExpanded, setInventoryExpanded] = useState(false);
  const [inventorySection, setInventorySection] = useState<"products" | "stock" | "adjustments" | "transfers" | "movements">("products");
  const [bankingExpanded, setBankingExpanded] = useState(false);
  const [bankingSection, setBankingSection] = useState<"accounts" | "transactions" | "reconciliation">("transactions");
  const [salesExpanded, setSalesExpanded] = useState(false);
  const [purchasesExpanded, setPurchasesExpanded] = useState(false);
  const [purchasesSection, setPurchasesSection] = useState<"bills" | "orders" | "returns">("bills");
  const [salesSection, setSalesSection] = useState<"invoices" | "quotations" | "orders" | "returns">("invoices");
  const [companies, setCompanies] = useState<Company[]>([]);
  const [companyId, setCompanyId] = useState("");
  const [branches, setBranches] = useState<Branch[]>([]);
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [summary, setSummary] = useState<DashboardSummary>(emptySummary);
  const [companyCreator, setCompanyCreator] = useState(false);
  const [newCompanyName, setNewCompanyName] = useState("");
  const [companyBusy, setCompanyBusy] = useState(false);
  const [loading, setLoading] = useState(!demo);
  const [error, setError] = useState("");
  const [accessRole, setAccessRole] = useState<AccessRole | null>(demo ? "owner" : null);
  const company = companies.find((c) => c.id === companyId);
  async function loadCompanies(preferred?: string) {
    if (demo) {
      setCompanies([
        {
          id: "demo",
          name: "Demo Trading Co.",
          legal_name: null,
          currency_code: "PKR",
          ntn: null,
          strn: null,
          gst_registered: false,
        },
      ]);
      setCompanyId("demo");
      setBranches([
        {
          id: "1",
          code: "HO",
          name: "Head Office",
          city: "Karachi",
          active: true,
        },
      ]);
      setAccounts([]);
      setLoading(false);
      return;
    }
    setLoading(true);
    await supabase.rpc("accept_my_company_invitations");
    const result = await supabase
      .from("companies")
      .select("id,name,legal_name,currency_code,ntn,strn,gst_registered")
      .order("created_at");
    if (result.error) setError(result.error.message);
    else {
      setCompanies(result.data ?? []);
      const next = preferred || companyId || result.data?.[0]?.id || "";
      setCompanyId(next);
    }
    setLoading(false);
  }
  async function loadCompanyData() {
    if (!companyId || demo) return;
    const [b, a, s, roleResult] = await Promise.all([
      supabase
        .from("branches")
        .select("id,code,name,city,active")
        .eq("company_id", companyId)
        .order("name"),
      supabase
        .from("accounts")
        .select("id,code,name,type,active,system_account")
        .eq("company_id", companyId)
        .order("code"),
      supabase.rpc("get_dashboard_summary", { target_company: companyId }),
      supabase.rpc("get_my_company_role", { target_company: companyId }),
    ]);
    if (b.error || a.error || s.error || roleResult.error)
      setError(
        b.error?.message ||
          a.error?.message ||
          s.error?.message ||
          roleResult.error?.message ||
          "Unable to load company",
      );
    else {
      setBranches(b.data ?? []);
      setAccounts((a.data ?? []) as Account[]);
      setSummary((s.data as DashboardSummary) ?? emptySummary);
      const nextRole = roleResult.data as AccessRole;
      setAccessRole(nextRole);
      if (nextRole === "sales" && !["Overview", "Sales", "Reports"].includes(view)) setView("Overview");
      if (nextRole === "purchases" && !["Overview", "Purchases", "Reports"].includes(view)) setView("Overview");
      if (nextRole === "inventory" && !["Overview", "Inventory", "Reports"].includes(view)) setView("Overview");
      if (nextRole === "payroll" && !["Overview", "Payroll", "Reports"].includes(view)) setView("Overview");
      if (nextRole === "viewer" && !["Overview", "Reports"].includes(view)) setView("Overview");
    }
  }
  async function createAdditionalCompany(e: React.FormEvent) {
    e.preventDefault();
    if (demo) return;
    setCompanyBusy(true);
    setError("");
    const result = await supabase.rpc("create_company", {
      company_name: newCompanyName.trim(),
    });
    if (result.error) setError(result.error.message);
    else {
      setNewCompanyName("");
      setCompanyCreator(false);
      await loadCompanies(result.data as string);
      setView("Overview");
      setMenu(false);
    }
    setCompanyBusy(false);
  }
  useEffect(() => {
    loadCompanies();
  }, []);
  useEffect(() => {
    loadCompanyData();
  }, [companyId]);
  useEffect(() => {
    if (view === "Overview") loadCompanyData();
  }, [view]);
  if (loading)
    return (
      <main className="loading">
        <div className="logo">CL</div>
        <p>Loading your ledger...</p>
      </main>
    );
  if (!demo && !companies.length)
    return <CompanyOnboarding onCreated={(id) => loadCompanies(id)} />;
  return (
    <div className="app-shell">
      <aside className={menu ? "open" : ""}>
        <div className="side-brand">
          <div className="logo small">CL</div>
          <div className="brand-copy"><strong>CloudLedger <span>PK</span></strong><small>Business finance</small></div>
          <button onClick={() => setMenu(false)}>
            <X />
          </button>
        </div>
        <label className="company-select">
          <Building2 />
          <span>
            <small>ACTIVE COMPANY</small>
            <select
              value={companyId}
              onChange={(e) => setCompanyId(e.target.value)}
            >
              {companies.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </select>
          </span>
          <ChevronDown />
        </label>
        {!demo && (
          <button className="add-company-button" onClick={() => setCompanyCreator((v) => !v)}>
            {companyCreator ? <X size={16} /> : <Plus size={16} />} {companyCreator ? "Cancel" : "New company"}
          </button>
        )}
        {companyCreator && (
          <form className="company-create-form" onSubmit={createAdditionalCompany}>
            <input value={newCompanyName} onChange={(e) => setNewCompanyName(e.target.value)} placeholder="Company name" minLength={2} required autoFocus />
            <button disabled={companyBusy}>{companyBusy ? "Creating..." : "Create company"}</button>
          </form>
        )}
        <nav>
          {nav.filter(([name]) => accessRole !== "sales" || ["Overview", "Sales", "Reports"].includes(name)).filter(([name]) => accessRole !== "purchases" || ["Overview", "Purchases", "Reports"].includes(name)).filter(([name]) => accessRole !== "inventory" || ["Overview", "Inventory", "Reports"].includes(name)).filter(([name]) => accessRole !== "payroll" || ["Overview", "Payroll", "Reports"].includes(name)).filter(([name]) => accessRole !== "viewer" || ["Overview", "Reports"].includes(name)).map(([name, Icon]) => (
            <div key={name}>
            <button
              className={view === name ? "active" : ""}
              aria-expanded={name === "Sales" ? salesExpanded : name === "Purchases" ? purchasesExpanded : name === "Banking" ? bankingExpanded : name === "Inventory" ? inventoryExpanded : name === "Payroll" ? payrollExpanded : undefined}
              aria-controls={name === "Sales" ? "sales-submenu" : name === "Purchases" ? "purchases-submenu" : name === "Banking" ? "banking-submenu" : name === "Inventory" ? "inventory-submenu" : name === "Payroll" ? "payroll-submenu" : undefined}
              onClick={() => {
                if (name === "Sales") { setSalesExpanded((open) => !open); return; }
                if (name === "Purchases") { setPurchasesExpanded((open) => !open); return; }
                if (name === "Banking") { setBankingExpanded((open) => !open); return; }
                if (name === "Inventory") { setInventoryExpanded((open) => !open); return; }
                if (name === "Payroll") { setPayrollExpanded((open) => !open); return; }
                setView(name);
                setMenu(false);
              }}
              key={name}
            >
              <Icon size={19} />
              {name}
              {name === "Payroll" && <ChevronDown size={15} style={{marginLeft:"auto",transform:payrollExpanded ? "rotate(180deg)" : undefined}}/>}
              {name === "Inventory" && <ChevronDown size={15} style={{marginLeft:"auto",transform:inventoryExpanded ? "rotate(180deg)" : undefined}}/>}
              {name === "Banking" && <ChevronDown size={15} style={{ marginLeft: "auto", transform: bankingExpanded ? "rotate(180deg)" : undefined }} />}
              {name === "Sales" && <ChevronDown size={15} style={{ marginLeft: "auto", transform: salesExpanded ? "rotate(180deg)" : undefined }} />}
              {name === "Purchases" && <ChevronDown size={15} style={{ marginLeft: "auto", transform: purchasesExpanded ? "rotate(180deg)" : undefined }} />}
            </button>
            {name === "Sales" && salesExpanded && <div id="sales-submenu" className="sales-submenu">
              {([["invoices", "Sales invoices"], ["quotations", "Sales quotations"], ["orders", "Sales orders"], ["returns", "Returns & credit notes"]] as const).map(([section, label]) => <button key={section} className={view === "Sales" && salesSection === section ? "active" : ""} aria-current={view === "Sales" && salesSection === section ? "page" : undefined} onClick={() => { setSalesSection(section); setView("Sales"); setMenu(false); }}>{label}</button>)}
            </div>}
            {name === "Purchases" && purchasesExpanded && <div id="purchases-submenu" className="sales-submenu">
              {([["bills", "Purchase bills"], ["orders", "Purchase orders"], ["returns", "Returns & supplier debit notes"]] as const).map(([section, label]) => <button key={section} className={view === "Purchases" && purchasesSection === section ? "active" : ""} aria-current={view === "Purchases" && purchasesSection === section ? "page" : undefined} onClick={() => { setPurchasesSection(section); setView("Purchases"); setMenu(false); }}>{label}</button>)}
            </div>}
            {name === "Banking" && bankingExpanded && <div id="banking-submenu" className="sales-submenu">
              {([["accounts", "Bank accounts"], ["transactions", "Receipts & payments"], ["reconciliation", "Bank reconciliation"]] as const).map(([section, label]) => <button key={section} className={view === "Banking" && bankingSection === section ? "active" : ""} aria-current={view === "Banking" && bankingSection === section ? "page" : undefined} onClick={() => { setBankingSection(section); setView("Banking"); setMenu(false); }}>{label}</button>)}
            </div>}
            {name === "Inventory" && inventoryExpanded && <div id="inventory-submenu" className="sales-submenu">
              {([["products","Products & services"],["stock","Warehouse stock"],["adjustments","Stock adjustments"],["transfers","Warehouse transfers"],["movements","Stock movements"]] as const).map(([section,label]) => <button key={section} className={view === "Inventory" && inventorySection === section ? "active" : ""} aria-current={view === "Inventory" && inventorySection === section ? "page" : undefined} onClick={() => {setInventorySection(section);setView("Inventory");setMenu(false);}}>{label}</button>)}
            </div>}
            {name === "Payroll" && payrollExpanded && <div id="payroll-submenu" className="sales-submenu">
              {([["employees","Employees"],["attendance","Daily attendance"],["leave","Leave management"],["runs","Payroll runs"]] as const).map(([section,label]) => <button key={section} className={view === "Payroll" && payrollSection === section ? "active" : ""} aria-current={view === "Payroll" && payrollSection === section ? "page" : undefined} onClick={() => {setPayrollSection(section);setView("Payroll");setMenu(false);}}>{label}</button>)}
            </div>}
            </div>
          ))}
        </nav>
        <div className="user">
          <div className="avatar">
            {(session?.user.email?.[0] ?? "D").toUpperCase()}
          </div>
          <div>
            <b>{session?.user.email ?? "Demo User"}</b>
            <small><ShieldCheck size={12} /> {demo ? "Preview mode" : "Secure session"}</small>
          </div>
          {!demo && (
            <button
              className="logout"
              title="Sign out"
              onClick={() => supabase.auth.signOut()}
            >
              <LogOut size={17} />
            </button>
          )}
        </div>
      </aside>
      <main className="content">
        <header>
          <button className="menu" onClick={() => setMenu(true)}>
            <Menu />
          </button>
          <div className="search">
            <Search />
            <input placeholder="Search transactions, accounts..." />
            <kbd>⌘ K</kbd>
          </div>
          <button className="icon-button notification-button" aria-label="Notifications">
            <Bell />
            <i />
          </button>
          {accessRole !== "viewer" && <button className="new-button" onClick={() => setView(accessRole === "sales" ? "Sales" : accessRole === "purchases" ? "Purchases" : accessRole === "inventory" ? "Inventory" : accessRole === "payroll" ? "Payroll" : "Accounting")}>
            <Sparkles size={16} /> Quick entry
          </button>}
        </header>
        <section className="page">
          <div className="page-title">
            <div>
              <p className="eyebrow"><span className="live-dot" /> {company?.name?.toUpperCase()}</p>
              <h1>{view === "Overview" ? "Financial overview" : view === "Sales" ? ({invoices:"Sales invoices",quotations:"Sales quotations",orders:"Sales orders",returns:"Returns & credit notes"})[salesSection] : view === "Purchases" ? ({bills:"Purchase bills",orders:"Purchase orders",returns:"Returns & supplier debit notes"})[purchasesSection] : view === "Banking" ? ({accounts:"Bank accounts",transactions:"Receipts & payments",reconciliation:"Bank reconciliation"})[bankingSection] : view === "Inventory" ? ({products:"Products & services",stock:"Warehouse stock",adjustments:"Stock adjustments",transfers:"Warehouse transfers",movements:"Stock movements"})[inventorySection] : view === "Payroll" ? ({employees:"Employees",attendance:"Daily attendance",leave:"Leave management",runs:"Payroll runs"})[payrollSection] : view}</h1>
              <p className="muted">
                {view === "Overview"
                  ? "Live company data and accounting status."
                  : "Manage " + view.toLowerCase() + " for the active company."}
              </p>
            </div>
            <select className="period-select">
              <option>Current financial year</option>
            </select>
          </div>
          {error && <p className="alert">{error}</p>}
          {view === "Overview" && (
            <Overview
              branches={branches}
              accounts={accounts}
              summary={summary}
            />
          )}{" "}
          {view === "Accounting" && (
            <AccountingView
              companyId={companyId}
              branches={branches}
              accounts={accounts}
              onAccountsChanged={loadCompanyData}
            />
          )}{" "}
          {view === "Sales" && (
            <SalesView key={`${companyId}:${salesSection}`} companyId={companyId} branches={branches} section={salesSection} />
          )}{" "}
          {view === "Purchases" && (
            <PurchasesView key={`${companyId}:${purchasesSection}`} companyId={companyId} branches={branches} accounts={accounts} onAccountsChanged={loadCompanyData} section={purchasesSection} />
          )}{" "}
          {view === "Banking" && (
            <BankingView key={`${companyId}:${bankingSection}`} companyId={companyId} branches={branches} accounts={accounts} section={bankingSection} />
          )}{" "}
          {view === "Inventory" && <InventoryView key={`${companyId}:${inventorySection}`} companyId={companyId} section={inventorySection} />}{" "}
          {view === "Payroll" && <PayrollView key={`${companyId}:${payrollSection}`} companyId={companyId} branches={branches} section={payrollSection} />}{" "}
          {view === "Reports" && <ReportsView companyId={companyId} />}{" "}
          {view === "Settings" && company && (
            <SettingsView
              company={company}
              branches={branches}
              onRefresh={loadCompanyData}
            />
          )}{" "}
          {![
            "Overview",
            "Accounting",
            "Sales",
            "Purchases",
            "Banking",
            "Inventory",
            "Payroll",
            "Reports",
            "Settings",
          ].includes(view) && <Placeholder title={view} />}
        </section>
      </main>
    </div>
  );
}

export default function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  const [demo, setDemo] = useState(false);
  useEffect(() => {
    if (!isSupabaseConfigured) {
      setReady(true);
      return;
    }
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setReady(true);
    });
    const { data } = supabase.auth.onAuthStateChange((_e, s) => {
      setSession(s);
      if (s) setDemo(false);
    });
    return () => data.subscription.unsubscribe();
  }, []);
  if (!ready)
    return (
      <main className="loading">
        <div className="logo">CL</div>
      </main>
    );
  return session || demo ? (
    <Dashboard session={session} demo={demo} />
  ) : (
    <Login onDemo={() => setDemo(true)} />
  );
}
