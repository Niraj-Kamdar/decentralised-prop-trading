# Arkiv feedback

What we hit building the publisher (`@arkiv-network/sdk` 1.0.1, Rabdi testnet, 2026-11-07), ordered by how much time it cost.

## 1. No Python SDK, but data and ML work lives in Python
- **Expected:** a maintained `pip install` client, since our simulator, notebook and Streamlit app are all Python.
- **What happened:** `arkiv-sdk` 0.2.2 on PyPI is yanked, and an older quickstart points to `golem_base_sdk`. We found no current Python package, so we write from a TypeScript script and will hand-roll JSON-RPC reads in Python.
- **Ask:** an official Python read client, even read-only, for analytics and data science users.

## 2. Docs and package are out of step
- The TypeScript API reference lists only `localhost` and `tiramisu` under chains, but the current testnet is Rabdi, and `rabdi` is what the SDK README uses.
- The API reference has names but no signatures or examples. We had to read `README.md` and the `.d.ts` files inside `node_modules/@arkiv-network/sdk` to learn `executeBatch`, `defineSchema` and the value helpers.
- `arkiv.dev.golem.network/docs` → `docs.arkiv.network/start-here/fundamentals` → `/start-here/introduction/`, a chain of redirects, one of them to a page that only says "Redirecting".
- **Repro:** open https://docs.arkiv.network/typescript-sdk/api-reference/ and look for `rabdi`.

## 3. Limits that aren't documented
The limits page gives 128 KiB per `bytes` value and per create, but not:
- maximum transaction size or entities per `executeBatch`;
- RPC rate limits, with or without an access key.

We guessed 96 KiB of blob bytes per transaction to stay clear of typical node tx-size limits. A documented number, or an SDK error that names the limit, would remove the guesswork.

## 4. Blobs over 128 KiB need hand-rolled chunking
Our trader dataset is 137 KiB gzipped. We split it into `part`/`parts` entities ourselves, and readers have to sort and concatenate them. A `writeBlob` / `readBlob` helper that chunks and reassembles would cover a common case (datasets, images, model artifacts).

## 5. No sort by creation time
`orderBy(desc("$createdAt"))` is rejected, so "give me the latest run" needs our own indexed `published` u64 attribute. Sorting on `$createdAt` (or `$updatedAt`) would make "latest version" queries work out of the box.

## 6. Faucet and access keys need a browser wallet
- **Expected:** to fund a key generated on the command line (or in CI), paste its address into the faucet, and get an access key with a signed message or a CLI.
- **What happened:** both pages require "Connect wallet" and a sign-in. A key created by `viem`'s `generatePrivateKey()` can't be funded without importing it into a browser wallet first. That blocked us mid-flow: we had a working publisher script and no headless way to fund it.
- **Ask:** an address-paste faucet (rate-limited per address and IP) and a programmatic way to issue access keys, for CI pipelines that publish data.

## 7. Small things
- **Results expire after at most ~182.5 days.** For long-lived public records (audits, reports) a "renew before expiry" helper or scheduled extension would help. We'll need a cron job.
- **The no-access-key warning only shows at runtime** (`Rabdi: no access key ... heavily rate limited`). Saying so on the network page next to the RPC URL would save a debugging round.
- **`ExpirationTime.fromDays(180)` worked first time; `defineSchema` + typed `select` was the best part of the SDK.** Writes and owner-filtered reads were straightforward once we had the right version.
