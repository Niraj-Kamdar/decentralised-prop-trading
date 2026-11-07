// Landing-page illustrations. Plain HTML/CSS so they stay crisp, responsive and readable by screen readers.
// Colour = role, used the same way in every picture: trader = accent, lenders = brand, insurance = teal.

const ROLE = {
  trader: "bg-accent",
  lenders: "bg-brand",
  insurance: "bg-[#0f8f80]",
  fulcrum: "bg-fg2/50",
  keeper: "bg-muted/40",
} as const;
type Role = keyof typeof ROLE;

const money = (v: number) => `$${v.toLocaleString("en-US", { minimumFractionDigits: Number.isInteger(v) ? 0 : 2 })}`;

/** Hero: $1,000 of ETH = one $100 block from you + nine from the vault. */
export function LeverBar() {
  return (
    <figure aria-label="Your $100 plus $900 borrowed from the vault buys $1,000 of ETH">
      <div className="grid grid-cols-10 gap-1 sm:gap-1.5" aria-hidden>
        {Array.from({ length: 10 }, (_, i) => (
          <div
            key={i}
            className={`block-in aspect-[3/4] rounded ${i === 0 ? ROLE.trader : ROLE.lenders}`}
            style={{ animationDelay: `${i * 60}ms` }}
          />
        ))}
      </div>
      <div className="mt-3 grid grid-cols-10 gap-1 text-sm sm:gap-1.5">
        <div className="col-span-1 text-accent">
          <div className="num text-base text-fg">$100</div>
          you
        </div>
        <div className="col-span-9 border-l border-line pl-3 text-muted">
          <div className="num text-base text-fg">$900</div>
          borrowed from the vault
        </div>
      </div>
      <figcaption className="mt-5 flex items-baseline justify-between border-t border-fg/80 pt-3">
        <span className="text-fg2">You hold</span>
        <span className="num text-2xl text-fg">$1,000 of ETH</span>
      </figcaption>
    </figure>
  );
}

/** How it works: lenders → vault → trade, and the order money comes back on close. */
export function Flow() {
  const nodes = [
    { t: "Lenders", d: "deposit USDC", c: ROLE.lenders },
    { t: "The vault", d: "lends up to 9x a trader's deposit", c: ROLE.lenders },
    { t: "Your trade", d: "holds real ETH or BTC", c: ROLE.trader },
  ];
  const back = ["Lenders get the loan back", "Profit is split", "You get the rest"];
  return (
    <div>
      <ol className="grid gap-3 md:grid-cols-[1fr_auto_1fr_auto_1fr] md:items-center">
        {nodes.map((n, i) => (
          <li key={n.t} className="contents">
            {i > 0 && <Chevron className="mx-auto rotate-90 md:rotate-0" />}
            <div className="card flex items-center gap-3 p-4">
              <span className={`h-8 w-2 shrink-0 rounded-sm ${n.c}`} aria-hidden />
              <div>
                <div className="text-lg text-fg">{n.t}</div>
                <div className="text-sm text-muted">{n.d}</div>
              </div>
            </div>
          </li>
        ))}
      </ol>
      <p className="mt-8 text-sm text-fg2">When the trade closes, money goes back in this order:</p>
      <ol className="mt-3 grid gap-2 sm:grid-cols-3">
        {back.map((b, i) => (
          <li key={b} className="flex items-center gap-3 rounded bg-panel2 px-4 py-3 text-fg2">
            <span className="num text-accent">{i + 1}</span>
            {b}
          </li>
        ))}
      </ol>
    </div>
  );
}

function Chevron({ className = "" }: { className?: string }) {
  return (
    <svg className={`h-5 w-5 text-muted ${className}`} viewBox="0 0 20 20" fill="none" aria-hidden>
      <path d="M7 4l6 6-6 6" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

type Slice = { role: Role | "lost"; label: string; v: number };
const SCALE = 1100; // both bars share one dollar scale, so the win bar is visibly longer

/** One position, split by who gets paid. */
function SplitBar({ title, slices, note }: { title: string; slices: Slice[]; note: string }) {
  return (
    <figure className="card p-6">
      <figcaption className="text-xl text-fg">{title}</figcaption>
      <div className="mt-5 flex h-10 gap-[2px]" aria-hidden>
        {slices.map((s) => (
          <div
            key={s.label}
            title={`${s.label}: ${money(s.v)}`}
            className={`min-w-[3px] first:rounded-l last:rounded-r ${
              s.role === "lost" ? "border border-dashed border-down/60 bg-down/5" : ROLE[s.role]
            }`}
            style={{ width: `${(s.v / SCALE) * 100}%` }}
          />
        ))}
      </div>
      <table className="mt-5 w-full text-sm">
        <tbody>
          {slices.map((s) => (
            <tr key={s.label} className="border-t border-line first:border-0">
              <td className="py-2 text-fg2">
                <span
                  className={`mr-2 inline-block h-2.5 w-2.5 rounded-sm align-middle ${
                    s.role === "lost" ? "border border-dashed border-down/60" : ROLE[s.role]
                  }`}
                  aria-hidden
                />
                {s.label}
              </td>
              <td className="num py-2 text-right text-fg">{money(s.v)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="mt-4 text-sm text-muted">{note}</p>
    </figure>
  );
}

// Trader level, PR #10: LP 10%, treasury 3% split 50/50 insurance/Fulcrum; Base keeper bounty $0.50.
// Liquidation sells at -8% with 0.1% slippage: $919.08 out. Swap for Arkiv's `example` section once the sim re-runs.
export function Endings() {
  return (
    <div className="grid gap-5 md:grid-cols-2">
      <SplitBar
        title="ETH rises 10%. The position is worth $1,100."
        slices={[
          { role: "lenders", label: "Lenders: loan back + 10% of profit", v: 910 },
          { role: "insurance", label: "Insurance fund", v: 1.5 },
          { role: "fulcrum", label: "Fulcrum", v: 1.5 },
          { role: "trader", label: "You: $100 back + $87 profit", v: 187 },
        ]}
        note="With $100 alone, the same move makes $10. Here you keep $87."
      />
      <SplitBar
        title="ETH falls 8%. The contract closes it at $919."
        slices={[
          { role: "lenders", label: "Lenders: loan back in full", v: 900 },
          { role: "keeper", label: "Keeper, for closing on time", v: 0.5 },
          { role: "insurance", label: "Insurance fund", v: 18.58 },
          { role: "lost", label: "Lost in the price drop", v: 80.92 },
        ]}
        note="You lose your $100 and nothing more. Lenders are paid before anyone else."
      />
    </div>
  );
}

/** Levels as a staircase: each step unlocks more. */
export function Levels() {
  const steps = [
    { n: "Starter", lev: "5x", dep: "$50", keep: "80%", up: "5 trades, +$25 total", down: "Never" },
    { n: "Trader", lev: "10x", dep: "$250", keep: "87%", up: "10 trades, +$100 total", down: "At −$50" },
    { n: "Pro", lev: "10x", dep: "$1,000", keep: "91%", up: "Top level", down: "At −$200" },
  ];
  return (
    <ol className="grid items-end gap-3 md:grid-cols-3">
      {steps.map((s, i) => (
        <li key={s.n} className="card overflow-hidden">
          <div className="p-5">
            <div className="text-lg text-fg">{s.n}</div>
            <dl className="mt-3 grid grid-cols-2 gap-y-1 text-sm">
              <dt className="text-muted">Leverage</dt>
              <dd className="num text-right text-fg">up to {s.lev}</dd>
              <dt className="text-muted">Deposit</dt>
              <dd className="num text-right text-fg">up to {s.dep}</dd>
              <dt className="text-muted">You keep</dt>
              <dd className="num text-right text-fg">{s.keep} of each win</dd>
              <dt className="text-muted">Move up</dt>
              <dd className="text-right text-fg2">{s.up}</dd>
              <dt className="text-muted">Move down</dt>
              <dd className="text-right text-fg2">{s.down}</dd>
            </dl>
          </div>
          {/* Step riser: taller with each level, the staircase is the picture. */}
          <div className="bg-accent" style={{ height: `${(i + 1) * 12}px`, opacity: 0.35 + i * 0.3 }} aria-hidden />
        </li>
      ))}
    </ol>
  );
}

const CRASHES = [
  { n: "COVID", d: "2020-03-12" },
  { n: "May 2021", d: "2021-05-19" },
  { n: "LUNA", d: "2022-05-11" },
  { n: "FTX", d: "2022-11-08" },
  { n: "Yen carry", d: "2024-08-05" },
  { n: "Tariffs", d: "2025-02-03" },
  { n: "Oct 10", d: "2025-10-10" },
];
const T0 = Date.parse("2020-01-01");
const T1 = Date.parse("2026-11-01");

/** Proof: the seven crashes on a 2020–2026 timeline, each tagged with what lenders lost. */
export function CrashTimeline() {
  return (
    <figure>
      {/* Desktop: dated timeline. */}
      <div className="relative hidden h-28 md:block" aria-hidden>
        <div className="absolute inset-x-0 top-1/2 h-px bg-line" />
        {CRASHES.map((c, i) => {
          const x = ((Date.parse(c.d) - T0) / (T1 - T0)) * 100;
          const above = i % 2 === 0;
          return (
            <div key={c.n} className="absolute -translate-x-1/2 text-center" style={{ left: `${x}%`, top: above ? 0 : "56%" }}>
              {!above && <div className="mx-auto mb-1 h-2 w-2 rounded-full bg-brand" />}
              <div className="whitespace-nowrap text-sm text-fg2">{c.n}</div>
              <div className="num whitespace-nowrap text-sm text-up">$0 lost</div>
              {above && <div className="mx-auto mt-1 h-2 w-2 rounded-full bg-brand" />}
            </div>
          );
        })}
        <div className="absolute bottom-0 left-0 text-xs text-muted">2020</div>
        <div className="absolute bottom-0 right-0 text-xs text-muted">2026</div>
      </div>
      {/* Mobile, and the accessible version of the timeline. */}
      <ul className="grid grid-cols-2 gap-2 md:sr-only">
        {CRASHES.map((c) => (
          <li key={c.n} className="flex justify-between rounded bg-panel2 px-3 py-2 text-sm">
            <span className="text-fg2">
              {c.n} <span className="text-muted">{c.d.slice(0, 4)}</span>
            </span>
            <span className="num text-up">$0 lost</span>
          </li>
        ))}
      </ul>
    </figure>
  );
}
