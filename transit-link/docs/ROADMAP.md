# Roadmap: from MVP to a real pilot

## What the MVP proves

The rider, validator, ledger, operator and analytics layers fit together, work with an unreliable
connection, and never charge a tap twice.

## What it does not do

- Hold or move real money (payouts are simulated, balances are not in a licensed wallet).
- Verify passes offline or run on dedicated hardware.
- Support tap-out, distance fares, concessions, refunds, disputes or customer support tools.
- Defend against login guessing or run at city scale.

## Suggested stages

| Stage | Outcome | Main work |
| --- | --- | --- |
| 0. Validate | Real operator and rider needs confirmed | Interview commuters, matatu owners and crews; approach the rail operator |
| 1. Showcase | This MVP | Done |
| 2. Controlled trial | One station pair, small cohort | Licensed payment partner holds funds; real devices; support process |
| 3. Feeders | Matatu operators opt in | Crew incentives, transfer discounts, per-operator settlement |
| 4. National alignment | Plug into the government fare system | Adopt published standards, integrate with the clearinghouse when it exists |

## Engineering backlog

1. Alembic database migrations
2. Public-key signed passes (offline verification)
3. Tap-out and distance-based fares, fare capping and transfers
4. Rate limiting and audit logging
5. Real payouts through a licensed partner (for example M-Pesa B2C) with reconciliation
6. Admin screens for stations, fares and validators
7. React or Next.js front-ends, native wrapper for the validator
8. Model monitoring with real data, and a privacy impact assessment

## Regulation checklist (verify with a lawyer)

- Central Bank of Kenya authorisation for payment services and e-money, or work through a licensed partner.
- National Payment System Bill 2026: check its status and licence categories before you design the trial.
- Data Protection Act 2019: ODPC registration, privacy notice, data protection impact assessment.
- Operator agreements and the national fare-system requirements.
