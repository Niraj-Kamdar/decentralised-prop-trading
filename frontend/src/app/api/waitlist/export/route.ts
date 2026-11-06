import { timingSafeEqual } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { getStore } from "@/lib/waitlist-store";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorized(req: NextRequest): boolean {
  const expected = process.env.WAITLIST_ADMIN_TOKEN;
  if (!expected) return false;
  const given = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

const csvCell = (v: string) => (/[",\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v);

/** CSV export: curl -H "Authorization: Bearer $WAITLIST_ADMIN_TOKEN" https://<host>/api/waitlist/export */
export async function GET(req: NextRequest) {
  if (!authorized(req)) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const rows = await getStore().all();
  const csv = [
    "email,role,source,created_at",
    ...rows.map((r) => [r.email, r.role, r.source ?? "", r.createdAt].map(csvCell).join(",")),
  ].join("\n");
  return new NextResponse(csv, {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="waitlist-${new Date().toISOString().slice(0, 10)}.csv"`,
    },
  });
}
