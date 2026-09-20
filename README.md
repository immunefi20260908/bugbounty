# Blockchain Security Portfolio

This repository includes a smart contract security learning lab and a portfolio site designed for job-seeking in Web3 / blockchain engineering.

## Included

- Solidity security experiments in `contracts/`
- Hardhat project for testing smart contract behavior
- A portfolio website in `web/` for showcasing engineering and security skills

## Requirements

- Node.js 18+
- npm

## Install dependencies

```bash
npm install
```

## Run tests

```bash
npx hardhat test
```

## Run with Foundry

Foundry の設定は `foundry.toml` にあります。Solidity のテストは `test-foundry/` に置いています。

```bash
forge build
forge test -vv
```

現在の Foundry テストでは、`VulnerableVault` の再入攻撃とフラッシュローン返済を確認できます。

ポートフォリオの `Method` セクションでは、実装の順番を `Threat model -> State design -> Happy path -> Attack tests -> Fix and rerun` として紹介しています。

### テストコードの読み方

1. `new MockJPYC()` でテスト用トークンを作る。
2. `new VulnerableVault(address(jpyc))` で Vault に JPYC のアドレスを渡す。
3. `mint` で初期残高を用意し、`prepare` で `approve` を設定する。
4. `attack` または `attackFlashLoan` で実際の処理を呼び出す。
5. 最後の `require` で、期待した残高や revert 結果になったか確認する。

`testJPYCAlchemyIsPossibleInMock` は、誰でも `mint` できるモック固有の危険性を確認するテストです。
実際の JPYC を表すものではなく、発行権限を制限する必要性を学ぶための教材です。

`testJPYCReentrancyAttemptReverts` は、JPYC に交換しても Vault 側の再入リスクが消えないことを確認します。
トークンの種類を変えても、外部コールの前に残高を更新する設計問題は別途修正が必要です。

より詳しい読み方、数量計算、コール順序、再入攻撃の説明は [docs/JPYC_FOUNDRY_GUIDE.md](docs/JPYC_FOUNDRY_GUIDE.md) を参照してください。

## Preview the portfolio locally

From the project root:

```bash
python -m http.server 8000
```

Then open:

```text
http://localhost:8000/web/index.html
```

## Deploy the portfolio to GitHub Pages

`.github/workflows/deploy-pages.yml` が `main` ブランチへの push を検知し、`web/` を GitHub Pages へ自動デプロイします。

初回だけ GitHub リポジトリの Settings > Pages で、Source を `GitHub Actions` に設定してください。
デプロイ後の URL は通常 `https://<GitHubユーザー名>.github.io/<リポジトリ名>/` です。

```bash
git remote add origin https://github.com/<ユーザー名>/<リポジトリ名>.git
git push -u origin main
```

`.env`、`node_modules/`、Hardhat の生成物、Foundry の `out/` は `.gitignore` で公開対象から除外しています。

## Portfolio focus

This portfolio is tailored for a blockchain security engineer / Solidity developer with emphasis on:

- DeFi security
- Smart contract risk analysis
- Reentrancy and protocol logic review
- Practical project storytelling for recruitment
