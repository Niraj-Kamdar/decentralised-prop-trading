"use client";

import { createContext, useCallback, useContext, useState, type ReactNode } from "react";
import { txUrl } from "@/lib/config";

type Toast = { id: number; kind: "info" | "success" | "error"; title: string; body?: string; hash?: string };
type Ctx = { push: (t: Omit<Toast, "id">) => number; update: (id: number, t: Partial<Toast>) => void };

const ToastCtx = createContext<Ctx | null>(null);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);

  const dismiss = useCallback((id: number) => setToasts((ts) => ts.filter((t) => t.id !== id)), []);

  const schedule = useCallback(
    (id: number, kind: Toast["kind"]) => {
      if (kind !== "info") setTimeout(() => dismiss(id), kind === "error" ? 12_000 : 6_000);
    },
    [dismiss],
  );

  const push = useCallback(
    (t: Omit<Toast, "id">) => {
      const id = Date.now() + Math.random();
      setToasts((ts) => [...ts.slice(-3), { ...t, id }]);
      schedule(id, t.kind);
      return id;
    },
    [schedule],
  );

  const update = useCallback(
    (id: number, patch: Partial<Toast>) => {
      setToasts((ts) => ts.map((t) => (t.id === id ? { ...t, ...patch } : t)));
      if (patch.kind) schedule(id, patch.kind);
    },
    [schedule],
  );

  return (
    <ToastCtx.Provider value={{ push, update }}>
      {children}
      <div className="pointer-events-none fixed bottom-4 right-4 z-50 flex w-[min(380px,calc(100vw-2rem))] flex-col gap-2">
        {toasts.map((t) => (
          <div
            key={t.id}
            role="status"
            className={`pointer-events-auto rounded-lg border bg-panel p-3 text-sm shadow-xl ${
              t.kind === "error" ? "border-down/60" : t.kind === "success" ? "border-up/60" : "border-line"
            }`}
          >
            <div className="flex items-start justify-between gap-3">
              <div className="flex items-center gap-2 font-medium">
                {t.kind === "info" && <span className="h-3 w-3 animate-spin rounded-full border-2 border-accent border-t-transparent" />}
                {t.kind === "success" && <span className="text-up">✓</span>}
                {t.kind === "error" && <span className="text-down">!</span>}
                {t.title}
              </div>
              <button onClick={() => dismiss(t.id)} className="text-muted hover:text-fg" aria-label="Dismiss">
                ×
              </button>
            </div>
            {t.body && <p className="mt-1 text-muted">{t.body}</p>}
            {t.hash && (
              <a href={txUrl(t.hash)} target="_blank" rel="noreferrer" className="mt-1 inline-block text-accent hover:underline">
                View transaction ↗
              </a>
            )}
          </div>
        ))}
      </div>
    </ToastCtx.Provider>
  );
}

export function useToast() {
  const ctx = useContext(ToastCtx);
  if (!ctx) throw new Error("useToast outside ToastProvider");
  return ctx;
}
