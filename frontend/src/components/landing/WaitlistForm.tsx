"use client";

import { useEffect, useState, type FormEvent } from "react";
import { Segmented } from "@/components/ui";

type Role = "trader" | "lp" | "both";
const ROLE_LABEL: Record<Role, string> = { trader: "I want to trade", lp: "I want to earn", both: "Both" };

export function WaitlistForm({ source = "landing" }: { source?: string }) {
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<Role>("trader");
  const [website, setWebsite] = useState("");
  const [state, setState] = useState<"idle" | "loading" | "done" | "error">("idle");
  const [message, setMessage] = useState("");
  const [count, setCount] = useState<number | null>(null);

  useEffect(() => {
    fetch("/api/waitlist")
      .then((r) => r.json())
      .then((j: { count: number | null }) => setCount(j.count))
      .catch(() => undefined);
  }, []);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setState("loading");
    try {
      const res = await fetch("/api/waitlist", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email, role, website, source }),
      });
      const j = (await res.json()) as { ok?: boolean; alreadyJoined?: boolean; error?: string };
      if (!res.ok || !j.ok) throw new Error(j.error || "Something went wrong");
      setState("done");
      setMessage(j.alreadyJoined ? "You're already on the list. We'll be in touch." : "You're on the list! We'll email you at launch.");
      if (!j.alreadyJoined) setCount((c) => (c === null ? c : c + 1));
    } catch (err) {
      setState("error");
      setMessage(err instanceof Error ? err.message : "Something went wrong");
    }
  }

  if (state === "done") {
    return (
      <div role="status" className="rounded border border-up/30 bg-up/5 p-5 text-center">
        <p className="text-up">{message}</p>
      </div>
    );
  }

  return (
    <form onSubmit={submit} className="space-y-3">
      <Segmented options={["trader", "lp", "both"] as const} value={role} onChange={setRole} render={(r) => ROLE_LABEL[r]} />
      <div className="flex flex-col gap-2 sm:flex-row">
        <input
          type="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="you@example.com"
          className="input flex-1 py-3"
          aria-label="Email address"
        />
        {/* Honeypot: hidden from people, filled by bots. */}
        <input
          type="text"
          tabIndex={-1}
          autoComplete="off"
          value={website}
          onChange={(e) => setWebsite(e.target.value)}
          className="hidden"
          aria-hidden
          name="website"
        />
        <button type="submit" disabled={state === "loading"} className="btn-primary px-6 py-3">
          {state === "loading" ? "Joining…" : "Join the waitlist"}
        </button>
      </div>
      {state === "error" && <p className="text-sm text-down">{message}</p>}
      <p className="text-xs text-muted">
        {count !== null && count > 0 ? `${count.toLocaleString()} ${count === 1 ? "person" : "people"} already waiting. ` : ""}One email at full launch. No spam.
      </p>
    </form>
  );
}
