import Link from "next/link";
import { APP_NAME } from "@/lib/config";

export function Logo({ href = "/" }: { href?: string }) {
  return (
    <Link href={href} className="flex items-center gap-2 font-semibold tracking-tight">
      <svg width="26" height="26" viewBox="0 0 32 32" aria-hidden>
        <rect width="32" height="32" rx="8" fill="rgb(var(--accent))" />
        <path d="M8 21l5-6 4 3 7-9" stroke="white" strokeWidth="2.6" fill="none" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
      <span>{APP_NAME}</span>
    </Link>
  );
}
