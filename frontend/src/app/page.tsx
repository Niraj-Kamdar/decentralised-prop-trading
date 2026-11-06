import Link from "next/link";
import { Calculator } from "@/components/landing/Calculator";
import { LiveStats } from "@/components/landing/LiveStats";
import { WaitlistForm } from "@/components/landing/WaitlistForm";
import { Logo } from "@/components/Logo";
import { APP_NAME } from "@/lib/config";

const TRADER_STEPS = [
  { t: "Put in a little USDC", d: "Start with as little as $5. That's your margin, and the most you can ever lose." },
  { t: "Get 5x or 10x buying power", d: "LPs lend you the rest, so $10 buys $50 or $100 of real BTC or ETH on Uniswap." },
  { t: "Keep up to 90% of the profit", d: "Close whenever you like. You get your $10 back plus 85–90% of the gains. The first week is free." },
];

const LP_STEPS = [
  { t: "Deposit USDC", d: "Your USDC joins the vault that funds traders. You receive spUSDC, which tracks your share." },
  { t: "Earn from three sources", d: "8–12% of every winning trade, weekly fees on borrowed money, and lending yield on idle cash." },
  { t: "Protected first", d: "Losing trades close automatically before they eat into your money. Traders take losses first, then the insurance pool." },
];

const SAFETY = [
  { t: "Losses capped at margin", d: "A trade is closed automatically before it can lose more than the trader put in." },
  { t: "One wallet per trade", d: "Every position lives in its own isolated contract. It can only trade through the protocol's Uniswap v4 router." },
  { t: "Manipulation-resistant prices", d: "A 10-minute Uniswap v4 average price guards every entry, exit and liquidation, so a flash pump or dump cannot move it." },
  { t: "Insurance pool", d: "Liquidation penalties and part of every fee build a reserve that absorbs bad debt before LPs." },
  { t: "Orderly LP exits", d: "Withdrawals go through a 30-day queue, so a rush to the exit can't break open trades." },
  { t: "Non-custodial", d: "All logic runs in smart contracts on Arc, where gas is paid in USDC. No company holds your money." },
];

const FAQ = [
  {
    q: "What is the live demo?",
    a: "The full protocol runs on Arc mainnet with real USDC. To start, the founder has seeded the vault with $100, which is enough for traders to try positions of $5–$10. Join the waitlist to hear when we open with deeper liquidity.",
  },
  {
    q: "Can I lose more than I put in?",
    a: "No. If the price moves against you far enough, the position is closed automatically (liquidated). You lose your margin and nothing more. The money LPs lent you is repaid first.",
  },
  {
    q: "Why would LPs lend to me?",
    a: "They earn a cut of every profitable trade (8% at 5x, 12% at 10x), weekly rollover fees after the free first week, and lending yield on cash that isn't in use. Losses are absorbed by traders' margin and the insurance pool before LPs.",
  },
  {
    q: "Are there fees?",
    a: "No fees to open or close. The first 7 days are free. After that, if you keep the trade open, you pay 8% a year (about 0.15% a week) on the borrowed amount. When you win, a share of the profit goes to LPs and the protocol.",
  },
  {
    q: "Is this spot or perps?",
    a: "Spot. Your position actually buys the token on Uniswap and holds it in its own contract until you close. There are no funding rates and no synthetic exposure.",
  },
  {
    q: "How do LP withdrawals work?",
    a: "You request a withdrawal and it is paid after a 30-day queue. Requested shares stop earning but are still exposed to losses until they're paid. If the vault is very busy (80% or more lent out), exiting forfeits 25% of the yield you've earned, never your principal. That forfeited yield rewards LPs who add liquidity when it's needed most.",
  },
  {
    q: "Is it audited?",
    a: "Not yet. This is an early MVP with small amounts on purpose. Only use money you can afford to lose.",
  },
  {
    q: "What do I need to start?",
    a: "A browser wallet such as MetaMask or Rabby, and some USDC on Arc. USDC also pays for gas on Arc, so you don't need any other token.",
  },
];

export default function Landing() {
  return (
    <div className="relative overflow-x-hidden">
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 h-[600px] bg-[radial-gradient(ellipse_at_top,rgba(99,140,255,0.18),transparent_60%)]"
      />

      <header className="relative mx-auto flex max-w-6xl items-center justify-between px-4 py-5 sm:px-6">
        <Logo />
        <nav className="hidden items-center gap-6 text-sm text-muted md:flex">
          <a href="#traders" className="hover:text-fg">For traders</a>
          <a href="#lps" className="hover:text-fg">For LPs</a>
          <a href="#calculator" className="hover:text-fg">Calculator</a>
          <a href="#faq" className="hover:text-fg">FAQ</a>
        </nav>
        <Link href="/app" className="btn-secondary">
          Open app
        </Link>
      </header>

      <main className="relative">
        {/* Hero */}
        <section className="mx-auto max-w-6xl px-4 pb-12 pt-10 text-center sm:px-6 md:pt-20">
          <span className="pill border border-up/30 bg-up/10 text-up">● MVP live on Arc mainnet</span>
          <h1 className="mx-auto mt-6 max-w-3xl text-4xl font-bold tracking-tight sm:text-6xl">
            Trade crypto with <span className="text-accent">10x buying power.</span> Risk only what you put in.
          </h1>
          <p className="mx-auto mt-5 max-w-2xl text-lg text-muted">
            Put in $10 and trade up to $100 of real BTC or ETH on Uniswap v4. Liquidity providers fund the rest and share in the
            profits. No fees to open or close.
          </p>
          <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <Link href="/app/trade" className="btn-primary px-6 py-3 text-base">
              Try the live demo →
            </Link>
            <a href="#waitlist" className="btn-secondary px-6 py-3 text-base">
              Join the waitlist
            </a>
          </div>
          <p className="mt-3 text-xs text-muted">The demo uses real USDC on Arc mainnet. Positions are $5–$10 while the vault is small.</p>
          <div className="mx-auto mt-12 max-w-4xl text-left">
            <LiveStats />
          </div>
        </section>

        {/* Two audiences */}
        <section className="mx-auto grid max-w-6xl gap-6 px-4 py-12 sm:px-6 md:grid-cols-2">
          <div id="traders" className="card scroll-mt-24 p-6 md:p-8">
            <span className="pill bg-accent/15 text-accent">For traders</span>
            <h2 className="mt-4 text-2xl font-semibold">Bigger positions, capped downside</h2>
            <ol className="mt-6 space-y-5">
              {TRADER_STEPS.map((s, i) => (
                <li key={s.t} className="flex gap-4">
                  <span className="num flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-panel2 text-sm font-semibold">{i + 1}</span>
                  <div>
                    <div className="font-medium">{s.t}</div>
                    <p className="mt-1 text-sm text-muted">{s.d}</p>
                  </div>
                </li>
              ))}
            </ol>
            <Link href="/app/trade" className="btn-primary mt-8 w-full">
              Start trading
            </Link>
          </div>
          <div id="lps" className="card scroll-mt-24 p-6 md:p-8">
            <span className="pill bg-up/15 text-up">For liquidity providers</span>
            <h2 className="mt-4 text-2xl font-semibold">Earn from traders' profits</h2>
            <ol className="mt-6 space-y-5">
              {LP_STEPS.map((s, i) => (
                <li key={s.t} className="flex gap-4">
                  <span className="num flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-panel2 text-sm font-semibold">{i + 1}</span>
                  <div>
                    <div className="font-medium">{s.t}</div>
                    <p className="mt-1 text-sm text-muted">{s.d}</p>
                  </div>
                </li>
              ))}
            </ol>
            <Link href="/app/earn" className="btn-secondary mt-8 w-full">
              Provide liquidity
            </Link>
          </div>
        </section>

        {/* Calculator */}
        <section id="calculator" className="mx-auto max-w-6xl scroll-mt-24 px-4 py-12 sm:px-6">
          <div className="mb-8 text-center">
            <h2 className="text-3xl font-semibold">See exactly what happens</h2>
            <p className="mt-2 text-muted">Pick an amount and drag the price. These numbers use the same rules as the contracts.</p>
          </div>
          <Calculator />
        </section>

        {/* How money flows */}
        <section className="mx-auto max-w-6xl px-4 py-12 sm:px-6">
          <div className="card p-6 md:p-8">
            <h2 className="text-2xl font-semibold">Where the money goes when a trade closes</h2>
            <div className="mt-6 grid gap-4 md:grid-cols-4">
              {[
                { n: "1", t: "LPs are repaid", d: "The borrowed amount goes back to the vault first, always." },
                { n: "2", t: "Weekly fees", d: "After the free first week: 80% to LPs, 20% to insurance." },
                { n: "3", t: "Your margin back", d: "You get your original stake back before any profit is split." },
                { n: "4", t: "Profit split", d: "You keep 90% (5x) or 85% (10x). The rest goes to LPs and the protocol." },
              ].map((s) => (
                <div key={s.n} className="rounded-lg bg-bg p-4">
                  <div className="num text-sm text-accent">Step {s.n}</div>
                  <div className="mt-1 font-medium">{s.t}</div>
                  <p className="mt-1 text-sm text-muted">{s.d}</p>
                </div>
              ))}
            </div>
          </div>
        </section>

        {/* Safety */}
        <section className="mx-auto max-w-6xl px-4 py-12 sm:px-6">
          <h2 className="mb-8 text-center text-3xl font-semibold">Built to protect both sides</h2>
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {SAFETY.map((s) => (
              <div key={s.t} className="card p-5">
                <div className="font-medium">{s.t}</div>
                <p className="mt-2 text-sm text-muted">{s.d}</p>
              </div>
            ))}
          </div>
        </section>

        {/* Waitlist */}
        <section id="waitlist" className="mx-auto max-w-3xl scroll-mt-24 px-4 py-16 sm:px-6">
          <div className="card p-6 text-center md:p-10">
            <h2 className="text-3xl font-semibold">Get in before full launch</h2>
            <p className="mx-auto mt-3 max-w-xl text-muted">
              The demo is live now with a small vault. Leave your email and we'll tell you when {APP_NAME} opens with deeper liquidity,
              bigger positions and more markets.
            </p>
            <div className="mx-auto mt-8 max-w-xl text-left">
              <WaitlistForm />
            </div>
          </div>
        </section>

        {/* FAQ */}
        <section id="faq" className="mx-auto max-w-3xl scroll-mt-24 px-4 py-12 sm:px-6">
          <h2 className="mb-6 text-3xl font-semibold">Questions</h2>
          <div className="divide-y divide-line rounded-xl border border-line bg-panel">
            {FAQ.map((f) => (
              <details key={f.q} className="group px-5 py-4">
                <summary className="flex cursor-pointer list-none items-center justify-between font-medium">
                  {f.q}
                  <span className="text-muted transition group-open:rotate-45">+</span>
                </summary>
                <p className="mt-3 text-sm leading-relaxed text-muted">{f.a}</p>
              </details>
            ))}
          </div>
        </section>
      </main>

      <footer className="border-t border-line">
        <div className="mx-auto flex max-w-6xl flex-col gap-4 px-4 py-8 text-xs text-muted sm:px-6 md:flex-row md:items-center md:justify-between">
          <Logo />
          <p className="max-w-2xl">
            Experimental, unaudited software running with real funds. Leveraged trading can lose your entire margin quickly, and
            LP deposits can lose value. Nothing here is financial advice. Check that crypto trading is legal where you live.
          </p>
        </div>
      </footer>
    </div>
  );
}
