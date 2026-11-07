import { ImageResponse } from "next/og";
import { APP_NAME } from "@/lib/config";

export const alt = `${APP_NAME}: Capital for traders. Returns for investors. Decentralised prop trading.`;
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default function OgImage() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          padding: 80,
          backgroundColor: "#ffffff",
          backgroundImage: "radial-gradient(60% 70% at 15% 30%, rgba(83,58,253,0.18), transparent 70%)",
          color: "#061B31",
          fontFamily: "sans-serif",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 20 }}>
          <svg width="64" height="64" viewBox="0 0 48 48" fill="none" strokeWidth="6.5" strokeLinecap="round">
            <rect width="48" height="48" rx="10" fill="#061B31" />
            <path d="M15 15v24M15 25.5h13" stroke="#FFFFFF" />
            <path d="M15 14 37 8" stroke="#A99BFF" />
          </svg>
          <div style={{ fontSize: 44 }}>{APP_NAME}</div>
        </div>
        <div style={{ display: "flex", flexDirection: "column", fontSize: 88, lineHeight: 1.05, letterSpacing: -2 }}>
          <div>Capital for traders.</div>
          <div style={{ color: "#533AFD" }}>Returns for investors.</div>
        </div>
        <div style={{ fontSize: 32, color: "#64748D" }}>Decentralised prop trading · Up to 10x on crypto · Settled in USDC</div>
      </div>
    ),
    size,
  );
}
