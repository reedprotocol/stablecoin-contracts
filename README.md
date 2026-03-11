# reed

This repo contains the on-chain code for USDR, a Cardano-native stablecoin.

## About

This is an aiken project. For more about aiken see the
[Aiken's user manual](https://aiken-lang.org).

## Scripts

* **m.ak** - Main protocol logic
* **er_main.ak** - Mainnet price feeds consumption (Orcfax & Charli3)
* **erp.ak** - Oracle exchange rate pointer
* **rm.ak** - REE token minting
* **er_test.ak** - Testnet price feed consumption (Orcfax)
* **x.ak** - Helper functions

## Build

```bash
aiken install
aiken build
aiken test
```

---

**simply stable**
