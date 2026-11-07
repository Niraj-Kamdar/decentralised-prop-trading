export function Bars({
  rows,
  max,
}: {
  rows: { label: string; value: number; text: string }[];
  max?: number;
}) {
  const maxVal = max ?? Math.max(...rows.map((r) => r.value), 0.0001);

  return (
    <div className="space-y-2.5 text-xs">
      {rows.map((r, i) => {
        const widthPct = Math.min(100, Math.max(0, (r.value / maxVal) * 100));
        return (
          <div
            key={i}
            className="flex items-center gap-3"
            title={`${r.label}: ${r.text}`}
          >
            <span className="w-24 shrink-0 truncate text-right text-muted">
              {r.label}
            </span>
            <div className="relative h-6 flex-1 overflow-hidden rounded bg-panel2">
              <div
                className="h-full rounded bg-accent/80 transition-all duration-300"
                style={{ width: `${widthPct}%` }}
              />
              <span className="absolute inset-y-0 right-2.5 flex items-center font-mono text-[11px] font-medium text-fg">
                {r.text}
              </span>
            </div>
          </div>
        );
      })}
    </div>
  );
}
