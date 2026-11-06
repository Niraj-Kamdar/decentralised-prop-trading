import type { Config } from "tailwindcss";

export default {
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        bg: "rgb(var(--bg) / <alpha-value>)",
        panel: "rgb(var(--panel) / <alpha-value>)",
        panel2: "rgb(var(--panel2) / <alpha-value>)",
        line: "rgb(var(--line) / <alpha-value>)",
        fg: "rgb(var(--fg) / <alpha-value>)",
        fg2: "rgb(var(--fg2) / <alpha-value>)",
        muted: "rgb(var(--muted) / <alpha-value>)",
        accent: "rgb(var(--accent) / <alpha-value>)",
        "accent-hover": "rgb(var(--accent-hover) / <alpha-value>)",
        brand: "rgb(var(--brand-dark) / <alpha-value>)",
        up: "rgb(var(--up) / <alpha-value>)",
        down: "rgb(var(--down) / <alpha-value>)",
        warn: "rgb(var(--warn) / <alpha-value>)",
      },
      fontFamily: {
        sans: ["var(--font-sans)"],
        mono: ["var(--font-mono)"],
      },
      // Stripe-style type: weight 300 for text, 400 for UI emphasis. Nothing heavier.
      fontWeight: {
        medium: "400",
        semibold: "400",
        bold: "400",
      },
      // Conservative rounding: 4 / 6 / 8px.
      borderRadius: {
        DEFAULT: "4px",
        md: "4px",
        lg: "6px",
        xl: "8px",
      },
      boxShadow: {
        raised: "var(--elev-raised)",
        float: "var(--elev-float)",
        xl: "var(--elev-float)",
        DEFAULT: "var(--elev-ambient)",
      },
      letterSpacing: {
        display: "-0.025em",
        heading: "-0.02em",
      },
    },
  },
  plugins: [],
} satisfies Config;
