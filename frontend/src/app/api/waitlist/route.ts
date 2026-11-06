import { createHash } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { getStore, type Role } from "@/lib/waitlist-store";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const ROLES: Role[] = ["trader", "lp", "both"];

// Best-effort per-instance rate limit: 5 signups per IP per 10 minutes.
const WINDOW_MS = 10 * 60 * 1000;
const MAX_PER_WINDOW = 5;
const hits = new Map<string, number[]>();

function rateLimited(ip: string): boolean {
  const now = Date.now();
  const recent = (hits.get(ip) ?? []).filter((t) => now - t < WINDOW_MS);
  recent.push(now);
  hits.set(ip, recent);
  if (hits.size > 10_000) hits.clear();
  return recent.length > MAX_PER_WINDOW;
}

function clientIp(req: NextRequest): string {
  return req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || req.headers.get("x-real-ip") || "unknown";
}

export async function POST(req: NextRequest) {
  let body: { email?: unknown; role?: unknown; website?: unknown; source?: unknown };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid request" }, { status: 400 });
  }

  // Honeypot: real users never see or fill the "website" field.
  if (typeof body.website === "string" && body.website.length > 0) {
    return NextResponse.json({ ok: true, alreadyJoined: false });
  }

  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  if (!EMAIL_RE.test(email) || email.length > 254) {
    return NextResponse.json({ error: "Please enter a valid email address." }, { status: 400 });
  }
  const role: Role = ROLES.includes(body.role as Role) ? (body.role as Role) : "both";
  const source = typeof body.source === "string" ? body.source.slice(0, 64) : null;

  const ip = clientIp(req);
  if (rateLimited(ip)) {
    return NextResponse.json({ error: "Too many attempts. Please try again later." }, { status: 429 });
  }
  const ipHash = ip === "unknown" ? null : createHash("sha256").update(ip).digest("hex").slice(0, 32);

  try {
    const added = await getStore().add({ email, role, source, ipHash });
    return NextResponse.json({ ok: true, alreadyJoined: !added });
  } catch (e) {
    console.error("waitlist insert failed", e);
    return NextResponse.json({ error: "Could not save your signup. Please try again." }, { status: 500 });
  }
}

export async function GET() {
  try {
    const count = await getStore().count();
    return NextResponse.json({ count }, { headers: { "Cache-Control": "public, s-maxage=60, stale-while-revalidate=300" } });
  } catch (e) {
    console.error("waitlist count failed", e);
    return NextResponse.json({ count: null });
  }
}
