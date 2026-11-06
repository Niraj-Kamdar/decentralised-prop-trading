import type { Metadata } from "next";
import Link from "next/link";
import { Calculator } from "@/components/landing/Calculator";
import { WaitlistForm } from "@/components/landing/WaitlistForm";
import { Logo } from "@/components/Logo";
import { APP_NAME, SITE_DESCRIPTION, SITE_URL, TAGLINE } from "@/lib/config";

export const metadata: Metadata = { alternates: { canonical: "/" } };

const STEPS = [
  { n: "1", t: "Investors fund the vault", d: "Anyone can deposit USDC. That pool is what traders borrow from." },
  { n: "2", t: "Traders borrow up to 10x", d: "Put in $10, trade with up to $100. Your deposit covers the first losses." },
  { n: "3", t: "Close and get paid", d: "The contract splits the profit on the spot. Most of it goes to the trader." },
];

const TRADER_POINTS = ["Trade with 5x or 10x your deposit", "Keep up to 90% of the profit", "Paid out the moment you close", "First week of borrowing is free"];

const INVESTOR_POINTS = [
  "Earn 8–12% of every winning trade",
  "Traders' deposits take losses first",
  "Withdraw any time, paid out within 30 days",
];

const FAQ = [
  {
    q: "What is decentralised prop trading?",
    a: "A prop firm gives traders capital and splits the profits. Here a smart contract does that job: investors fund an on-chain vault, traders borrow from it with up to 10x leverage, and profits are split automatically when a trade closes. No challenges, no evaluation fees, no payout reviews.",
  },
  {
    q: "Is this like copy trading?",
    a: "Close. Instead of copying one trader's moves, investors deposit USDC into a vault that funds every trader and earn a share of each winning trade. Traders' own deposits absorb losses first.",
  },
  {
    q: "Can I lose more than I put in?",
    a: "No. The most you can lose is your deposit. Trades close automatically as losses approach it, but if the price drops suddenly you can still lose all of it.",
  },
  {
    q: "What happens if I keep losing?",
    a: "Nothing yet. Later, repeated losses will lower an account's leverage and can get it blocked. To stop people dodging that with fresh wallets, we plan to add sybil resistance using on-chain zk-KYC or World ID.",
  },
  {
    q: "Who decides if I get paid?",
    a: "Nobody. The smart contract pays you when you close. There is no review and no approval.",
  },
  {
    q: "What does the vault earn?",
    a: "8% of trader profit at 5x, 12% at 10x, plus borrowing fees after a trader's first free week.",
  },
  {
    q: "Can vault deposits lose money?",
    a: "Yes, if trades go badly enough. Trader deposits and an insurance reserve absorb losses first, but returns aren't guaranteed.",
  },
];

function Arrow({ className = "" }: { className?: string }) {
  return (
    <svg className={`h-3.5 w-3.5 shrink-0 ${className}`} viewBox="0 0 16 16" fill="none" aria-hidden>
      <path d="M3 8h10M9 4l4 4-4 4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function Points({ items }: { items: string[] }) {
  return (
    <ul className="space-y-2.5">
      {items.map((p) => (
        <li key={p} className="flex gap-3 text-fg2">
          <svg className="mt-1.5 h-3.5 w-3.5 shrink-0 text-accent" viewBox="0 0 16 16" fill="none" aria-hidden>
            <path d="M3 8.5 6.5 12 13 4.5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
          {p}
        </li>
      ))}
    </ul>
  );
}

const JSON_LD = {
  "@context": "https://schema.org",
  "@graph": [
    { "@type": "Organization", name: APP_NAME, url: SITE_URL, logo: `${SITE_URL}/icon.svg` },
    { "@type": "WebSite", name: APP_NAME, url: SITE_URL, description: SITE_DESCRIPTION },
    {
      "@type": "WebApplication",
      name: APP_NAME,
      url: SITE_URL,
      applicationCategory: "FinanceApplication",
      operatingSystem: "Web",
      description: `${TAGLINE} ${SITE_DESCRIPTION}`,
      offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    },
    {
      "@type": "FAQPage",
      mainEntity: FAQ.map((f) => ({ "@type": "Question", name: f.q, acceptedAnswer: { "@type": "Answer", text: f.a } })),
    },
  ],
};

export default function Landing() {
  return (
    <div className="overflow-x-clip">
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(JSON_LD).replace(/</g, "\\u003c") }} />
      <header className="sticky top-0 z-30 border-b border-line/70 bg-bg/80 backdrop-blur-md">
        <div className="mx-auto flex h-16 max-w-[1080px] items-center justify-between gap-6 px-4 sm:px-8">
          <Logo />
          <nav className="hidden items-center gap-7 text-sm text-fg2 md:flex" aria-label="Sections">
            <a href="#how" className="transition-colors hover:text-accent">How it works</a>
            <a href="#start" className="transition-colors hover:text-accent">Trade or earn</a>
            <a href="#faq" className="transition-colors hover:text-accent">FAQ</a>
          </nav>
          <Link href="/app/trade" className="btn-primary">
            Open app
          </Link>
        </div>
      </header>

      <main>
        {/* Hero: the pitch on the left, the product on the right */}
        <section className="relative">
          <div
            aria-hidden
            className="pointer-events-none absolute -top-40 left-1/2 h-[640px] w-[1200px] -translate-x-1/2 opacity-60 blur-3xl"
            style={{
              background:
                "radial-gradient(40% 45% at 25% 40%, rgb(var(--accent) / 0.22), transparent 70%), radial-gradient(30% 35% at 75% 25%, rgb(234 34 97 / 0.14), transparent 70%)",
            }}
          />
          <div className="relative mx-auto grid max-w-[1080px] items-center gap-12 px-4 pb-20 pt-14 sm:px-8 md:pt-20 lg:grid-cols-[1.1fr_1fr]">
            <div>
              <span className="eyebrow">Decentralised prop trading</span>
              <h1 className="mt-3 text-[44px] leading-[1.04] tracking-display sm:text-[60px]">
                Capital for traders.
                <br />
                <span className="text-accent">Returns for investors.</span>
              </h1>
              <p className="mt-6 max-w-[40ch] text-lg text-muted">
                Trade with up to 10x your money. Or fund the traders and earn from every win.
              </p>
              <div className="mt-8 flex flex-wrap gap-3">
                <Link href="/app/trade" className="btn-primary px-5 py-3 text-base">
                  Start trading <Arrow />
                </Link>
                <Link href="/app/earn" className="btn-secondary px-5 py-3 text-base">
                  Earn as an investor
                </Link>
              </div>
              <p className="mt-6 text-sm text-muted">Settled in USDC on Arc. No sign-up, just a wallet.</p>
            </div>
            <div className="lg:pl-4">
              <Calculator />
            </div>
          </div>
        </section>

        {/* How it works */}
        <section id="how" className="scroll-mt-20 border-t border-line bg-panel2">
          <div className="mx-auto max-w-[1080px] px-4 py-20 sm:px-8">
            <span className="eyebrow">How it works</span>
            <h2 className="mt-3 text-[32px] leading-tight">One vault, two sides.</h2>
            <ol className="mt-10 grid gap-8 md:grid-cols-3">
              {STEPS.map((s) => (
                <li key={s.n}>
                  <div className="num flex h-8 w-8 items-center justify-center rounded-full bg-accent/10 text-sm text-accent">{s.n}</div>
                  <h3 className="mt-4 text-xl">{s.t}</h3>
                  <p className="mt-2 text-muted">{s.d}</p>
                </li>
              ))}
            </ol>
          </div>
        </section>

        {/* Pick a side */}
        <section id="start" className="scroll-mt-20 border-t border-line">
          <div className="mx-auto grid max-w-[1080px] gap-5 px-4 py-20 sm:px-8 md:grid-cols-2">
            <article className="card flex flex-col p-7 sm:p-8">
              <span className="eyebrow">For traders</span>
              <h2 className="mt-3 text-[28px] leading-tight">Trade bigger than your wallet.</h2>
              <div className="mt-6">
                <Points items={TRADER_POINTS} />
              </div>
              <Link href="/app/trade" className="btn-primary mt-8 self-start px-5 py-3 text-base">
                Start trading <Arrow />
              </Link>
            </article>

            <article className="flex flex-col rounded-xl bg-brand p-7 text-white sm:p-8">
              <span className="eyebrow text-[#b9b9f9]">For investors</span>
              <h2 className="mt-3 text-[28px] leading-tight text-white">Earn from traders, without trading.</h2>
              <ul className="mt-6 space-y-2.5">
                {INVESTOR_POINTS.map((p) => (
                  <li key={p} className="flex gap-3 text-white/85">
                    <svg className="mt-1.5 h-3.5 w-3.5 shrink-0 text-[#b9b9f9]" viewBox="0 0 16 16" fill="none" aria-hidden>
                      <path d="M3 8.5 6.5 12 13 4.5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
                    </svg>
                    {p}
                  </li>
                ))}
              </ul>
              <Link href="/app/earn" className="btn mt-8 self-start bg-white px-5 py-3 text-base text-brand hover:bg-white/90">
                Deposit to the vault <Arrow />
              </Link>
              <p className="mt-auto pt-6 text-xs text-white/60">Deposits can lose value. Returns aren&apos;t guaranteed.</p>
            </article>
          </div>
        </section>

        {/* FAQ */}
        <section id="faq" className="scroll-mt-20 border-t border-line">
          <div className="mx-auto grid max-w-[1080px] gap-10 px-4 py-20 sm:px-8 md:grid-cols-[1fr_2fr]">
            <h2 className="text-[32px] leading-tight">Questions</h2>
            <div className="divide-y divide-line border-y border-line">
              {FAQ.map((f) => (
                <details key={f.q} className="group">
                  <summary className="flex cursor-pointer list-none items-center justify-between gap-4 py-5 text-lg text-fg transition-colors hover:text-accent [&::-webkit-details-marker]:hidden">
                    {f.q}
                    <svg className="h-4 w-4 shrink-0 text-muted transition-transform duration-200 group-open:rotate-45" viewBox="0 0 16 16" fill="none" aria-hidden>
                      <path d="M8 3v10M3 8h10" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
                    </svg>
                  </summary>
                  <p className="max-w-[65ch] pb-5 text-muted">{f.a}</p>
                </details>
              ))}
            </div>
          </div>
        </section>

        {/* Waitlist */}
        <section id="waitlist" className="scroll-mt-20 border-t border-line bg-panel2">
          <div className="mx-auto max-w-[1080px] px-4 py-20 text-center sm:px-8">
            <h2 className="text-[32px] leading-tight">Get early access</h2>
            <p className="mx-auto mt-3 max-w-md text-muted">We&apos;ll email you once when {APP_NAME} launches on mainnet.</p>
            <div className="mx-auto mt-8 max-w-xl text-left">
              <WaitlistForm />
            </div>
          </div>
        </section>
      </main>

      <footer className="border-t border-line">
        <div className="mx-auto flex max-w-[1080px] flex-col gap-6 px-4 py-10 text-sm text-muted sm:px-8 md:flex-row md:items-start md:justify-between">
          <Logo />
          <p className="max-w-2xl text-xs leading-relaxed">
            Experimental, unaudited software. Leveraged trading can lose your entire deposit quickly, and vault deposits can lose value.
            Nothing here is financial advice.
          </p>
        </div>
      </footer>
    </div>
  );
}
