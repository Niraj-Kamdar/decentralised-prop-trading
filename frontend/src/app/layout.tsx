import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import { Providers } from "@/components/Providers";
import { APP_NAME } from "@/lib/config";
import "./globals.css";

export const metadata: Metadata = {
  title: `${APP_NAME}: trade crypto with up to 10x buying power`,
  description:
    "Put up $10, trade up to $100 of BTC or ETH on Uniswap. Your loss is capped at your margin. Liquidity providers fund the trades and share the profits.",
};

export const viewport: Viewport = { themeColor: "#090b10", width: "device-width", initialScale: 1 };

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen">
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
