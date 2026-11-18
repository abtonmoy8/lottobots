# LottoBots (LBOT)

A 5,000-piece robot NFT collection on **BNB Chain** (chainId 56), built **agent-first**:
AI agents discover and mint directly through the published [`llms.txt`](llms.txt) and plain
contract calls, while humans use the website.

- **Website:** https://lottobots.pages.dev
- **Contract:** `0xc779c3e4c8b87b4ecac1b2308e4643e9021373fb`
- **Deploy tx:** `0xb397c97d911dbdb1465f29bdb5bfcf14f766b8b0b54dce45ff86135c72ab4bd9`
- **Verified source:** [Sourcify (full match)](https://sourcify.dev/#/lookup/0xc779c3e4c8b87b4ecac1b2308e4643e9021373fb)
- **Compiler:** Solidity 0.8.26, optimization 200 runs, EVM Shanghai, MIT license

## How it works

- **Free phase (first 300 mints):** free, max 2 per wallet — **gated to Binance Agent ID
  (.ai) holders**. `mintFree()` checks the SPACE ID Agent ID registry
  (`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`) on-chain and reverts for wallets without
  an Agent ID.
- **Paid phase (lucky draw):** the buyer sends a fixed maximum (0.0001 BNB, or 0.07 USDT)
  and the contract draws the real price on-chain:
  1% free GOLDEN jackpot edition · 10% ~$0.04 · 44% ~$0.06 · 45% ~$0.07.
  The difference is refunded in the same transaction (BNB path) or only the drawn amount
  is pulled (USDT path). Max 10 NFTs per wallet in total.
- All mint charges go directly to the project treasury
  (`0x6d89223BFf2de20ed343E13DFd9b9c439154fF91`) in the same transaction; nothing pools
  inside the contract.

## Agent ID integration

Agent ID is part of the contract's core flow, not a label:

- `mintFree()` calls `balanceOf` on the Agent ID registry — the free seats exist only for
  Agent ID holders.
- `hasAgentID(address)` lets any wallet or agent check eligibility in one call.
- `saleInfo(address)` returns the full sale state **plus** `agentIdHolder`, so an AI agent
  can decide autonomously whether it can free-mint, should wait for the draw, or should
  ask its owner — without spending gas on a reverting call.

## Owner permissions (disclosed)

The contract is not upgradeable and has no admin mint, pause, or blacklist. The owner
(the deploying wallet) can only change the metadata base URI (`setBaseURI`) and the
treasury address (`setTreasury`). Supply cap, prices, odds, and the Agent ID gate are
constants/immutables and cannot be changed.

## Files

- `LottoBots.sol` — the full contract source (single file, no imports).
- `llms.txt` — the agent-facing mint manual published on the project site.
