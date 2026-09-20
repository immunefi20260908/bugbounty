# JPYC と Foundry の読み方ガイド

このページは、`MockJPYC`、`VulnerableVault`、`ReentrancyAttacker`、Foundry テストの関係を読むための教材です。

## 1. 最初に登場人物を整理する

- `MockJPYC`: テスト用の ERC20 トークン。残高と送金を管理する。
- `VulnerableVault`: JPYC を預かる Vault。入金、出金、手数料、フラッシュローンを提供する。
- `ReentrancyAttacker`: 通常ユーザーにも攻撃者にもなるコントラクト。Vault の callback を受け取る。
- `VulnerableVaultTest`: 上の3つをデプロイして、結果を `require` で検証するテスト。

重要なのは、Vault が JPYC の内部実装を直接持たず、ERC20 のアドレスだけを受け取る点です。
そのため、`MockToken` から `MockJPYC` に変更しても、`transfer`、`transferFrom`、`balanceOf` があれば同じ処理を試せます。

## 2. テストを読む基本順序

各テストは次の順序で読みます。

1. `new` で必要なコントラクトをデプロイする。
2. `mint` で誰が何トークン持つかを準備する。
3. `configure` や `set...` でテスト条件を変更する。
4. `attack` や `attackFlashLoan` で調べたい処理を呼ぶ。
5. `require` で残高、状態、失敗結果を確認する。

たとえば次のコードでは、最初にユーザーへ JPYC を渡し、Vault の出金手数料を設定し、最後に手数料の受取額を確認しています。

```solidity
jpyc.mint(address(user), amount);
vault.setWithdrawalFee(100, address(this));
user.configure(amount, 0);
user.prepare();
user.attack();
require(jpyc.balanceOf(address(this)) == fee, "fee was not paid");
```

## 3. JPYC の単位

`MockJPYC` は OpenZeppelin の ERC20 を継承しています。`decimals()` はデフォルトで18です。

```text
1 JPYC       = 1 ether
10 JPYC      = 10 ether
1,000 JPYC   = 1_000 ether
```

ただし、`amount` の実体は最小単位の整数です。`1 ether` は Solidity の記法で、実際には `1 * 10^18` です。

## 4. 「錬金術」テストの意味

`testJPYCAlchemyIsPossibleInMock` では、誰でも呼べる次の関数を試しています。

```solidity
function mint(address to, uint256 amount) external {
    _mint(to, amount);
}
```

`external` だけでは呼び出し元の制限になりません。そのため、誰でも `mint` を呼び、保有量を増やせます。
これはこの教材で意図的に作った脆弱性です。

本番向けのトークンでは、例えば次のように発行者を制限します。

```solidity
function mint(address to, uint256 amount) external onlyOwner {
    _mint(to, amount);
}
```

ただし `onlyOwner` を追加するだけで十分とは限りません。管理者鍵の管理、発行上限、停止機能、発行イベント、権限変更の監視も確認します。

## 5. 出金と再入攻撃の読み方

`VulnerableVault.withdraw` の重要な順序は次の通りです。

```text
1. balances[msg.sender] を確認
2. msg.sender の callback を呼ぶ
3. トークンを送る
4. balances[msg.sender] を減らす
```

2番の callback 中に、攻撃者がもう一度 `withdraw` を呼べます。
4番の残高更新がまだなので、同じ残高をもう一度使おうとできます。

`testJPYCReentrancyAttemptReverts` は、この問題が JPYC でも同じように発生するかを確認しています。
トークンを交換するだけでは、Vault 自体の外部コール順序は安全になりません。

修正を考えるときは、次のどちらかを比較します。

- 残高更新を外部コールより前に行う Checks-Effects-Interactions
- OpenZeppelin の `ReentrancyGuard` と `nonReentrant`

## 6. フラッシュローンの読み方

フラッシュローンは、同じトランザクション内で返済される必要があります。

```text
Vault の残高を保存
  -> receiver へ amount を送る
  -> receiver.onFlashLoan(...) を呼ぶ
  -> Vault の残高が元本 + fee 以上か確認
  -> fee を feeRecipient へ送る
```

`testJPYCFlashLoanRepayment` では、receiver に返済手数料を先に持たせています。
この準備がないと callback の `amount + fee` 送金が失敗します。

## 7. テストの実行方法

プロジェクト直下で実行します。

```powershell
forge build
forge test -vv
forge test --match-test testJPYCAlchemyIsPossibleInMock -vvvv
```

- `forge build`: コンパイルだけ行う。
- `forge test -vv`: 全テストと通常の詳細を表示する。
- `--match-test`: テスト名を絞る。
- `-vvvv`: 外部呼び出しや残高変化を含む詳細トレースを表示する。

現在は、既存テスト2件と JPYC テスト7件の合計9件です。

追加した境界テストでは、`paused=true` のときに入金とフラッシュローンが拒否されること、
出金手数料1,000 bps超とフラッシュローン手数料500 bps超が拒否されることを確認します。
