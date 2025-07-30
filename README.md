# DecentralizedEscrow 🛡️

A gas-optimized, self-contained decentralized **Escrow Smart Contract** with built-in **dispute resolution**, written from scratch without using OpenZeppelin or external libraries.

---

## 🚀 Features

- ✅ **Trustless Buyer-Seller Escrow** system.
- ⚖️ **Dispute Mechanism**: Parties can raise disputes with a stake.
- 🧑‍⚖️ **Arbitrator Resolution**: Third-party arbitrator resolves conflicts.
- ⏳ **Timeout-Based Fallback**: Disputes are resolved if arbitrator fails to act.
- 💸 **Platform Fees** in basis points (BPS) to earn revenue.
- 🔐 **No OpenZeppelin** — everything implemented manually for gas optimization.

---

## 📜 Constructor

```solidity
constructor(
    address _arbitrator,
    uint64 _platformFeeBps,
    uint256 _initialDisputeStake
)
_arbitrator: Address of arbitrator.

_platformFeeBps: Fee percentage in BPS (1% = 100).

_initialDisputeStake: Minimum stake to raise a dispute.
```

##🧠 Functionality Overview
1. 📦 Escrow Lifecycle
createTransaction(address seller, uint64 timeout, uint64 disputeWindow) payable

Buyer creates an escrow transaction by sending funds.

Must specify timeout and disputeWindow.

releaseFunds(uint256 txId)

Buyer releases the funds to seller.

2. ⚔️ Dispute Handling
raiseDispute(uint256 txId) payable

Buyer or seller raises a dispute by depositing the stake.

resolveDispute(uint256 txId, bool releaseToSeller)

Arbitrator resolves dispute, releasing funds accordingly.

timeoutResolve(uint256 txId)

Automatically resolves the dispute if arbitrator is inactive post dispute window.

##💰 Platform Revenue
claimPlatformFees(address to)

Owner can withdraw accumulated platform fee earnings.

##🔎 Testing Tips
Use Remix to test:

✅ Standard release flow.

🚨 Dispute flow with arbitrator.

⏰ Timeout fallback resolution.

🔁 Multiple transaction cycles.

💸 Platform fee accumulation and withdrawal.

##🏗 Example Flow
1. Buyer creates transaction, pays into escrow.

2. Seller completes task.

3. Buyer releases payment or raises a dispute.

4. Arbitrator resolves dispute OR fallback kicks in after disputeWindow.

⚙️ Gas Optimization Techniques
Packed storage structs.

No dynamic arrays.

Minimal external calls.

Explicit require() conditions.

📁 Project Structure
Copy
Edit
decentralized-escrow/
├── contracts/
│   └── DecentralizedEscrow.sol
├── README.md
├── LICENSE
├── .gitignore
📜 License
MIT © 2025 Arya Singh
