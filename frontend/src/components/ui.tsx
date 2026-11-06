import type { ReactNode } from "react";

export function Stat({
  label,
  value,
  sub,
  tone,
}: {
  label: ReactNode;
  value: ReactNode;
  sub?: ReactNode;
  tone?: "up" | "down" | "warn";
}) {
  const color = tone === "up" ? "text-up" : tone === "down" ? "text-down" : tone === "warn" ? "text-warn" : "";
  return (
    <div>
      <div className="label">{label}</div>
      <div className={`num mt-1 text-xl font-semibold ${color}`}>{value}</div>
      {sub && <div className="mt-0.5 text-xs text-muted">{sub}</div>}
    </div>
  );
}

export function Row({ label, value, tone }: { label: ReactNode; value: ReactNode; tone?: "up" | "down" | "warn" | "muted" }) {
  const color =
    tone === "up" ? "text-up" : tone === "down" ? "text-down" : tone === "warn" ? "text-warn" : tone === "muted" ? "text-muted" : "";
  return (
    <div className="flex items-center justify-between gap-4 py-1 text-sm">
      <span className="text-muted">{label}</span>
      <span className={`num text-right ${color}`}>{value}</span>
    </div>
  );
}

export function Segmented<T extends string | number>({
  options,
  value,
  onChange,
  render,
}: {
  options: readonly T[];
  value: T;
  onChange: (v: T) => void;
  render?: (v: T) => ReactNode;
}) {
  return (
    <div className="grid rounded-lg border border-line bg-panel2 p-1" style={{ gridTemplateColumns: `repeat(${options.length}, 1fr)` }}>
      {options.map((o) => (
        <button
          key={String(o)}
          type="button"
          onClick={() => onChange(o)}
          className={`rounded px-3 py-1.5 text-sm font-normal transition-colors duration-150 ${
            o === value ? "bg-panel text-fg shadow ring-1 ring-line" : "text-muted hover:text-fg"
          }`}
        >
          {render ? render(o) : String(o)}
        </button>
      ))}
    </div>
  );
}

export function Toggle({ checked, onChange, label }: { checked: boolean; onChange: (v: boolean) => void; label?: ReactNode }) {
  return (
    <label className="flex cursor-pointer items-center justify-between gap-3 text-sm">
      {label && <span className="text-muted">{label}</span>}
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        onClick={() => onChange(!checked)}
        className={`relative h-5 w-9 rounded-full transition ${checked ? "bg-accent" : "bg-line"}`}
      >
        <span className={`absolute top-0.5 h-4 w-4 rounded-full bg-white transition ${checked ? "left-[18px]" : "left-0.5"}`} />
      </button>
    </label>
  );
}

export function Notice({ tone = "info", children }: { tone?: "info" | "warn" | "down"; children: ReactNode }) {
  const cls =
    tone === "warn"
      ? "border-warn/40 bg-warn/10 text-warn"
      : tone === "down"
        ? "border-down/40 bg-down/10 text-down"
        : "border-accent/30 bg-accent/10 text-fg";
  return <div className={`rounded-lg border px-3 py-2 text-sm ${cls}`}>{children}</div>;
}

export function AmountInput({
  value,
  onChange,
  max,
  suffix = "USDC",
  placeholder = "0.00",
}: {
  value: string;
  onChange: (v: string) => void;
  max?: string;
  suffix?: string;
  placeholder?: string;
}) {
  return (
    <div className="flex items-center rounded border border-line bg-panel transition-colors focus-within:border-accent focus-within:shadow-[0_0_0_3px_rgb(var(--accent)/0.15)]">
      <input
        inputMode="decimal"
        value={value}
        placeholder={placeholder}
        onChange={(e) => {
          const v = e.target.value.replace(/,/g, ".");
          if (/^\d*\.?\d{0,6}$/.test(v)) onChange(v);
        }}
        className="num w-full bg-transparent px-3 py-2.5 text-lg outline-none placeholder:text-muted/50"
      />
      {max !== undefined && (
        <button type="button" onClick={() => onChange(max)} className="mr-1 rounded px-2 py-1 text-xs font-semibold text-accent hover:bg-accent/10">
          MAX
        </button>
      )}
      <span className="pr-3 text-sm text-muted">{suffix}</span>
    </div>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="px-4 py-10 text-center text-sm text-muted">{children}</div>;
}

export function Modal({ open, onClose, title, children }: { open: boolean; onClose: () => void; title: string; children: ReactNode }) {
  if (!open) return null;
  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-fg/40 p-4 backdrop-blur-sm" onClick={onClose}>
      <div className="card w-full max-w-md p-6 shadow-float" onClick={(e) => e.stopPropagation()}>
        <div className="mb-4 flex items-center justify-between">
          <h3 className="text-xl">{title}</h3>
          <button onClick={onClose} className="text-muted hover:text-fg" aria-label="Close">
            ×
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}
