import Link from "next/link";
import { CrashTimeline, Endings, Flow, LeverBar, Levels } from "@/components/landing/Illustrations";
import { WaitlistForm } from "@/components/landing/WaitlistForm";
import { Logo } from "@/components/Logo";
import { APP_NAME } from "@/lib/config";

// Backtest run 5847faa, as published to Arkiv. Swap for getBacktest() once /backtest (feat/backtest-page) merges.
const PROOF = { apy: "12.46%", years: "6.8", trades: "6,967", crashes: 7, stressWorst: "0.49%" };

const TRADER_POINTS = [
  "Up to 10x on real ETH and BTC, not a synthetic perp",
  "No funding fees. First week of borrowing is free, then 8% a year",
  "Keep up to 91% of every win, paid the moment you close",
  "The most you can lose is your deposit",
];

const LENDER_POINTS = [
  "Earn 7–15% of every winning trade, plus borrowing fees",
  "Traders' deposits and an insurance fund take losses before you",
  `${PROOF.apy} a year in our ${PROOF.years}-year backtest`,
  "Withdraw any time, paid out within 30 days",
];

const FAQ = [
  {
    q: "Is this a perp?",
    a: "No. When you open a trade, the contract buys real ETH or BTC with your deposit plus the vault's loan, and holds it until you close. There's no funding rate.",
  },
  {
    q: "Can I lose more than I put in?",
    a: "No. Your deposit is the most you can lose. The contract closes your trade before losses pass it. In a very fast crash you can still lose all of it.",
  },
  {
    q: "Where does the loan come from?",
    a: "From lenders who deposit USDC into the vault. They're paid back first on every close, then take a share of the profit.",
  },
  {
    q: "What do lenders earn?",
    a: `7–15% of each winning trade, depending on the trader's level, plus 80% of borrowing fees. Our backtest averaged ${PROOF.apy} a year.`,
  },
  {
    q: "Can lenders lose money?",
    a: `Yes, if a crash is fast enough that a trader's deposit and the insurance fund can't cover it. In our backtest it never happened across ${PROOF.crashes} crashes. In our harshest stress test, with an empty insurance fund, the worst loss was ${PROOF.stressWorst}. All results are public on Arkiv.`,
  },
  {
    q: "How does Fulcrum make money?",
    a: "A cut of profitable trades: 1% to 2.5% depending on the trader's level. An equal amount goes to the insurance fund.",
  },
  {
    q: "Who decides if I get paid, or my level?",
    a: "Nobody. The contract pays you when you close and updates your level automatically.",
  },
];

function Arrow({ className = "" }: { className?: string }) {
  return (
    <svg className={`h-3.5 w-3.5 shrink-0 ${className}`} viewBox="0 0 16 16" fill="none" aria-hidden>
      <path d="M3 8h10M9 4l4 4-4 4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

export default function Landing() {
  return (
    <div className="overflow-x-clip">
      <header className="sticky top-0 z-30 border-b border-line/70 bg-bg/80 backdrop-blur-md">
        <div className="mx-auto flex h-16 max-w-[1080px] items-center justify-between gap-6 px-4 sm:px-8">
          <Logo />
          <nav className="hidden items-center gap-7 text-sm text-fg2 md:flex" aria-label="Sections">
            <a href="#how" className="transition-colors hover:text-accent">How it works</a>
            <a href="#example" className="transition-colors hover:text-accent">Example</a>
            <a href="#proof" className="transition-colors hover:text-accent">Backtest</a>
            <a href="#faq" className="transition-colors hover:text-accent">FAQ</a>
          </nav>
          <Link href="/app/trade" className="btn-primary">
            Open app
          </Link>
        </div>
      </header>

      <main>
        {/* Hook: what it is, in dollars */}
        <section className="mx-auto grid max-w-[1080px] items-center gap-14 px-4 pb-20 pt-14 sm:px-8 md:pt-24 lg:grid-cols-[1fr_1fr]">
          <div>
            <h1 className="text-[44px] leading-[1.04] tracking-display sm:text-[64px]">Buy $1,000 of ETH with $100.</h1>
            <p className="mt-6 max-w-[42ch] text-lg text-muted">
              Fulcrum lends you the other $900 from a vault of USDC lenders. Win, and you keep most of the profit. Lose, and you
              lose only your $100.
            </p>
            <div className="mt-8 flex flex-wrap gap-3">
              <Link href="/app/trade" className="btn-primary px-5 py-3 text-base">
                Start trading <Arrow />
              </Link>
              <Link href="/app/earn" className="btn-secondary px-5 py-3 text-base">
                Earn as a lender
              </Link>
            </div>
            <p className="mt-6 text-sm text-muted">USDC on Base. No sign-up, just a wallet.</p>
          </div>
          <LeverBar />
        </section>

        {/* Problem */}
        <section className="border-t border-line bg-panel2">
          <div className="mx-auto max-w-[1080px] px-4 py-20 sm:px-8">
            <h2 className="max-w-[24ch] text-[32px] leading-tight">Leverage today is rented, not owned.</h2>
            <div className="mt-10 grid gap-5 md:grid-cols-2">
              <div className="card p-6">
                <h3 className="text-xl">Traders pay to hold</h3>
                <p className="mt-2 text-muted">
                  Perps charge funding for as long as you stay in, and you never own the coin. The longer you hold, the more you pay.
                </p>
                <div className="mt-5 flex h-10 items-end gap-[3px]" aria-hidden>
                  {Array.from({ length: 30 }, (_, i) => (
                    <div key={i} className="flex-1 rounded-sm bg-down/70" style={{ height: `${12 + i * 3}%` }} />
                  ))}
                </div>
                <p className="mt-2 text-xs text-muted">Total funding paid, day by day</p>
              </div>
              <div className="card p-6">
                <h3 className="text-xl">Lenders earn little</h3>
                <p className="mt-2 text-muted">
                  USDC in lending markets earns single digits, mostly from other lenders borrowing against the same collateral.
                </p>
                <div className="mt-5 flex h-10 gap-[3px]" aria-hidden>
                  <div className="flex-1 rounded-sm bg-brand/15" />
                  <div className="w-[5%] rounded-sm bg-up/70" />
                </div>
                <p className="mt-2 text-xs text-muted">Your USDC, and what it earns</p>
              </div>
            </div>
            <p className="mt-8 text-lg text-fg2">One side has conviction and no capital. The other has capital and nothing to back.</p>
          </div>
        </section>

        {/* How it works */}
        <section id="how" className="scroll-mt-20 border-t border-line">
          <div className="mx-auto max-w-[1080px] px-4 py-20 sm:px-8">
            <h2 className="text-[32px] leading-tight">One vault connects them.</h2>
            <div className="mt-10">
              <Flow />
            </div>
            <p className="mt-8 text-lg text-fg2">Your deposit is the lever. The vault is the fulcrum.</p>
          </div>
        </section>

        {/* Two endings */}
        <section id="example" className="scroll-mt-20 border-t border-line bg-panel2">
          <div className="mx-auto max-w-[1080px] px-4 py-20 sm:px-8">
            <h2 className="text-[32px] leading-tight">One trade, two endings.</h2>
            <p className="mt-3 max-w-[60ch] text-muted">$100 deposit at 10x: $900 borrowed, $1,000 of ETH. Here is where every dollar goes.</p>
            <div className="mt-10">
              <Endings />
            </div>
            <p className="mt-6 text-sm text-muted">
              Example uses the Trader level. New wallets start at 5x with up to $50. If a crash moves too fast to close in time, the
              insurance fund covers the gap before lenders do.
            </p>
          </div>
        </section>

        {/* Levels */}
        <section className="border-t border-line">
          <div className="mx-auto max-w-[1080px] px-4 py-20 sm:px-8">
            <h2 className="text-[32px] leading-tight">Start small. Prove it. Unlock 10x.</h2>
            <p className="mt-3 max-w-[60ch] text-muted">
              Every wallet starts as a Starter. Winning moves you up and big losses move you down, automatically. Lenders take a bigger
              cut from new traders and a smaller one from proven ones.
            </p>
            <div className="mt-10">
              <Levels />
            </div>
          </div>
        </section>

        {/* Proof */}
        <section id="proof" className="scroll-mt-20 border-t border-line bg-brand text-white">
          <div className="mx-auto max-w-[1080px] px-4 py-20 sm:px-8">
            <h2 className="text-[32px] leading-tight text-white">We replayed the 7 worst crashes since 2020.</h2>
            <p className="mt-3 max-w-[62ch] text-white/75">
              Minute by minute, through {PROOF.years} years of Binance prices and {PROOF.trades} real Hyperliquid trades. Every result is
              published on Arkiv and signed by our wallet, so you can check it without trusting this page.
            </p>
            <dl className="mt-10 grid gap-6 sm:grid-cols-3">
              {[
                [PROOF.apy, "average lender APY"],
                ["$0", `lender losses across ${PROOF.crashes} crashes`],
                ["$0", "bad debt"],
              ].map(([v, l]) => (
                <div key={l}>
                  <dd className="num text-[40px] leading-none text-white">{v}</dd>
                  <dt className="mt-2 text-white/70">{l}</dt>
                </div>
              ))}
            </dl>
            <div className="mt-12 rounded-lg bg-white p-6 text-fg">
              <CrashTimeline />
            </div>
            <p className="mt-6 max-w-[70ch] text-sm text-white/70">
              In our harshest stress test (thin liquidity, every trader at 10x, keepers offline for 30 minutes and an empty insurance
              fund), lenders lost {PROOF.stressWorst} in the worst crash. We show that too.
            </p>
            <Link href="/backtest" className="btn mt-8 bg-white px-5 py-3 text-base text-brand hover:bg-white/90">
              See the full backtest <Arrow />
            </Link>
          </div>
        </section>

        {/* Pick a side */}
        <section id="start" className="scroll-mt-20 border-t border-line">
          <div className="mx-auto grid max-w-[1080px] gap-5 px-4 py-20 sm:px-8 md:grid-cols-2">
            {[
              { h: "Trade bigger than your wallet.", pts: TRADER_POINTS, href: "/app/trade", cta: "Start trading" },
              { h: "Earn from traders, without trading.", pts: LENDER_POINTS, href: "/app/earn", cta: "Deposit to the vault" },
            ].map((c) => (
              <article key={c.h} className="card flex flex-col p-7 sm:p-8">
                <h2 className="text-[28px] leading-tight">{c.h}</h2>
                <ul className="mt-6 space-y-2.5">
                  {c.pts.map((p) => (
                    <li key={p} className="flex gap-3 text-fg2">
                      <svg className="mt-1.5 h-3.5 w-3.5 shrink-0 text-accent" viewBox="0 0 16 16" fill="none" aria-hidden>
                        <path d="M3 8.5 6.5 12 13 4.5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
                      </svg>
                      {p}
                    </li>
                  ))}
                </ul>
                <Link href={c.href} className="btn-primary mt-8 self-start px-5 py-3 text-base">
                  {c.cta} <Arrow />
                </Link>
              </article>
            ))}
            <p className="text-xs text-muted md:col-span-2">Backtests aren&apos;t guarantees. Vault deposits can lose value.</p>
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
