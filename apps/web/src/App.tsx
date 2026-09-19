import { useEffect, useMemo, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import {
  BarChart3,
  Bell,
  Building2,
  ChevronDown,
  CircleDollarSign,
  FileText,
  LayoutDashboard,
  LogOut,
  Menu,
  Package,
  Plus,
  ReceiptText,
  Search,
  Settings,
  ShoppingCart,
  Users,
  WalletCards,
  X,
} from "lucide-react";
import { isSupabaseConfigured, supabase } from "./lib/supabase";
import AccountingView from "./AccountingView";
import SalesView from "./SalesView";
import InventoryView from "./InventoryView";

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
type ViewName =
  | "Overview"
  | "Accounting"
  | "Sales"
  | "Purchases"
  | "Inventory"
  | "Payroll"
  | "Reports"
  | "Settings";
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
  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!isSupabaseConfigured)
      return setMessage("Supabase environment variables are missing.");
    setBusy(true);
    const { error } = await supabase.auth.signInWithPassword({
      email,
      password,
    });
    setMessage(error?.message ?? "");
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
          <h2>Sign in to your account</h2>
          <p className="muted">Use your company email and password.</p>
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
            {busy ? "Signing in..." : "Sign in"}
          </button>
        </form>
        {message && <p className="form-message error">{message}</p>}
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
  <article className="metric">
    <div className={`metric-icon ${tone}`}>
      <CircleDollarSign size={21} />
    </div>
    <div>
      <p>{label}</p>
      <h3>{value}</h3>
      <span>{detail}</span>
    </div>
  </article>
);
function Overview({
  branches,
  accounts,
}: {
  branches: Branch[];
  accounts: Account[];
}) {
  const grouped = useMemo(
    () =>
      accounts.reduce<Record<string, number>>(
        (a, v) => ((a[v.type] = (a[v.type] ?? 0) + 1), a),
        {},
      ),
    [accounts],
  );
  return (
    <>
      <div className="metrics">
        <Metric
          label="Cash & bank"
          value={money.format(0)}
          detail="No posted transactions"
        />
        <Metric
          label="Receivables"
          value={money.format(0)}
          detail="No outstanding invoices"
          tone="green"
        />
        <Metric
          label="Payables"
          value={money.format(0)}
          detail="No outstanding bills"
          tone="orange"
        />
        <Metric
          label="Net profit"
          value={money.format(0)}
          detail="Current financial year"
          tone="purple"
        />
      </div>
      <div className="grid">
        <article className="panel chart-panel">
          <div className="panel-head">
            <div>
              <h3>Accounting setup</h3>
              <p>Live data from your active company</p>
            </div>
          </div>
          <div className="setup-grid">
            <div>
              <strong>{accounts.length}</strong>
              <span>Ledger accounts</span>
            </div>
            <div>
              <strong>{branches.length}</strong>
              <span>Active branches</span>
            </div>
            <div>
              <strong>{grouped.asset ?? 0}</strong>
              <span>Asset accounts</span>
            </div>
            <div>
              <strong>{grouped.expense ?? 0}</strong>
              <span>Expense accounts</span>
            </div>
          </div>
        </article>
        <article className="panel">
          <div className="panel-head">
            <div>
              <h3>Quick actions</h3>
              <p>Common daily tasks</p>
            </div>
          </div>
          <div className="actions">
            {[
              ["Create invoice", FileText],
              ["Record expense", ReceiptText],
              ["Receive payment", WalletCards],
              ["Add product", Package],
            ].map(([n, I]) => (
              <button key={n as string} disabled>
                {<I size={20} />}
                <span>{n as string}</span>
                <small>Coming next</small>
              </button>
            ))}
          </div>
        </article>
        <article className="panel wide empty-state">
          <FileText />
          <h3>No transactions yet</h3>
          <p>
            Your posted invoices, expenses and journal entries will appear here.
          </p>
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
  const [companies, setCompanies] = useState<Company[]>([]);
  const [companyId, setCompanyId] = useState("");
  const [branches, setBranches] = useState<Branch[]>([]);
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [loading, setLoading] = useState(!demo);
  const [error, setError] = useState("");
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
    const [b, a] = await Promise.all([
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
    ]);
    if (b.error || a.error)
      setError(
        b.error?.message || a.error?.message || "Unable to load company",
      );
    else {
      setBranches(b.data ?? []);
      setAccounts((a.data ?? []) as Account[]);
    }
  }
  useEffect(() => {
    loadCompanies();
  }, []);
  useEffect(() => {
    loadCompanyData();
  }, [companyId]);
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
          <strong>
            CloudLedger <span>PK</span>
          </strong>
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
        <nav>
          {nav.map(([name, Icon]) => (
            <button
              className={view === name ? "active" : ""}
              onClick={() => {
                setView(name);
                setMenu(false);
              }}
              key={name}
            >
              <Icon size={19} />
              {name}
            </button>
          ))}
        </nav>
        <div className="user">
          <div className="avatar">
            {(session?.user.email?.[0] ?? "D").toUpperCase()}
          </div>
          <div>
            <b>{session?.user.email ?? "Demo User"}</b>
            <small>{demo ? "Preview" : "Authenticated user"}</small>
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
          </div>
          <button className="icon-button">
            <Bell />
          </button>
          <button className="new-button" disabled>
            + New transaction
          </button>
        </header>
        <section className="page">
          <div className="page-title">
            <div>
              <p className="eyebrow">{company?.name?.toUpperCase()}</p>
              <h1>{view === "Overview" ? "Financial overview" : view}</h1>
              <p className="muted">
                {view === "Overview"
                  ? "Live company data and accounting status."
                  : "Manage " + view.toLowerCase() + " for the active company."}
              </p>
            </div>
            <select>
              <option>Current financial year</option>
            </select>
          </div>
          {error && <p className="alert">{error}</p>}
          {view === "Overview" && (
            <Overview branches={branches} accounts={accounts} />
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
            <SalesView companyId={companyId} branches={branches} />
          )}{" "}
          {view === "Inventory" && <InventoryView companyId={companyId} />}{" "}
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
            "Inventory",
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
