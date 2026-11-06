import Link from "next/link";
import { APP_NAME } from "@/lib/config";

/** "Lever F": an F whose top bar tilts up like a lever. */
export function Logo({ href = "/", tone = "dark" }: { href?: string; tone?: "dark" | "light" }) {
  const ink = tone === "light" ? "text-white" : "text-fg";
  const lever = tone === "light" ? "#A99BFF" : "rgb(var(--accent))";
  return (
    <Link href={href} className={`flex items-center gap-2 text-[17px] font-normal tracking-heading ${ink}`}>
      <svg width="24" height="24" viewBox="0 0 48 48" fill="none" strokeWidth="6.5" strokeLinecap="round" aria-hidden>
        <path d="M15 15v24M15 25.5h13" stroke="currentColor" />
        <path d="M15 14 37 8" stroke={lever} />
      </svg>
      <span>{APP_NAME}</span>
    </Link>
  );
}
