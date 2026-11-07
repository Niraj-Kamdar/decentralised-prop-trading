import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import { Providers } from "@/components/Providers";
import { APP_NAME, SITE_DESCRIPTION, SITE_URL, TAGLINE } from "@/lib/config";
import "./globals.css";

const title = `${APP_NAME}: Decentralised Prop Trading for Crypto Traders & Investors`;

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: { default: title, template: `%s | ${APP_NAME}` },
  description: SITE_DESCRIPTION,
  applicationName: APP_NAME,
  keywords: [
    "prop trading",
    "decentralised prop trading",
    "decentralized prop trading",
    "crypto prop firm",
    "funded trader",
    "crypto trading",
    "leverage trading",
    "copy trading",
    "crypto investing",
    "DeFi yield",
    "USDC vault",
    "on-chain trading",
    "Uniswap",
    "Bitcoin",
    "Ethereum",
  ],
  category: "finance",
  openGraph: {
    type: "website",
    siteName: APP_NAME,
    title: `${APP_NAME}: ${TAGLINE}`,
    description: SITE_DESCRIPTION,
    locale: "en_US",
  },
  twitter: { card: "summary_large_image", title: `${APP_NAME}: ${TAGLINE}`, description: SITE_DESCRIPTION },
  robots: { index: true, follow: true, googleBot: { index: true, follow: true, "max-image-preview": "large", "max-snippet": -1 } },
};

export const viewport: Viewport = { themeColor: "#ffffff", width: "device-width", initialScale: 1 };

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen">
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
