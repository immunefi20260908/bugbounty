// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../contracts/MockToken.sol";
import "../contracts/MockJPYC.sol";
import "../contracts/ReentrancyAttacker.sol";
import "../contracts/VulnerableVault.sol";

/*
    このファイルの読み方:

    1. MockJPYC を作る       = お金の種類を用意する
    2. VulnerableVault を作る = お金を預ける場所を用意する
    3. mint / prepare         = 初期残高と approve を用意する
    4. attack / flashLoan     = 調べたい処理を実行する
    5. require                = 実行後の正しい状態を確認する

    正常な入出金の状態変化（手数料0の場合）:
    - 実行前: user=1,000 JPYC、Vault=0 JPYC、内部残高=0
    - deposit後: user=0 JPYC、Vault=1,000 JPYC、内部残高=1,000
    - withdraw後: user=1,000 JPYC、Vault=0 JPYC、内部残高=0

    出金手数料1%の状態変化:
    - user が1,000 JPYCを出金
    - user は990 JPYC、feeRecipient は10 JPYCを受け取る
    - Vault の内部残高は1,000減少する

    再入攻撃の状態変化:
    - withdraw が残高を減らす前に callback を呼ぶ
    - callback からもう一度 withdraw を呼ぶ
    - 同じ内部残高を二重に使おうとするため、最終的に算術エラーで revert する
*/
contract VulnerableVaultTest {
    // 読み方: forge は名前が test で始まる external/public 関数を自動実行する。
    // 各テストは別々の状態で実行されるため、最初にトークンと Vault を毎回作る。
    // new はコントラクトをブロックチェーン上にデプロイし、返り値は新しいアドレスになる。
    // テストの基本形は「準備する -> 関数を呼ぶ -> 結果を require で検証する」。
    // require の条件が false になると、そのテストは失敗する。

    // 目的: withdraw 中の再入呼び出しが最終的に revert することを確認する。
    // 成功条件: attack() の low-level call が false を返すこと。
    function testReentrancyAttackReverts() external {
        // 1. テスト用トークンをデプロイする。
        MockToken token = new MockToken("TestToken", "TST");
        // 2. トークンアドレスを渡して Vault をデプロイする。
        VulnerableVault vault = new VulnerableVault(address(token));
        // 3. 攻撃者コントラクトを Vault とトークンに接続する。
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(vault), address(token));

        // ether は Solidity の数量単位。ERC20 の decimals が18なので、10 ether = 10トークン。
        uint256 amount = 10 ether;
        // attacker と vault に初期トークンを配る。MockToken の mint はテスト用に誰でも呼べる。
        // 4. 攻撃者へ入金用のトークンを配る。
        token.mint(address(attacker), amount * 3);
        // 5. Vault に流動性を配る。
        token.mint(address(vault), amount * 3);
        // attacker が Vault から transferFrom されることを許可する。
        // 6. 攻撃者から Vault への使用許可を設定する。
        attacker.prepare();

        // attack は deposit -> withdraw -> onVaultWithdraw -> withdraw の順で再入する。
        // Solidity の call は失敗しても false を返せるため、success を確認して失敗を期待する。
        // 7. 再入攻撃を実行する。
        (bool success, ) = address(attacker).call(abi.encodeWithSignature("attack()"));
        // 8. 攻撃が失敗したことを確認する。
        require(!success, "reentrancy attack should revert");
    }

    // 目的: flash loan の元本が戻り、設定した手数料が owner に支払われることを確認する。
    // 成功条件: Vault 残高は元のまま、テストコントラクトの残高は fee 分だけ増えること。
    function testFlashLoanSettlesAndPaysFee() external {
        // 1. テスト用トークンをデプロイする。
        MockToken token = new MockToken("TestToken", "TST");
        // 2. Vault をデプロイする。
        VulnerableVault vault = new VulnerableVault(address(token));
        // 3. 返済 callback を持つ receiver をデプロイする。
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(vault), address(token));

        uint256 amount = 10 ether;
        // 100 bps / 10,000 = 1%。この値は Vault の owner だけが設定できる。
        uint256 fee = amount / 100;
        // 4. フラッシュローン手数料を1%に設定する。
        vault.setFlashLoanFee(100);
        // Vault は元本、attacker は返済手数料を持つ状態にする。
        // 5. Vault に貸出用の流動性を配る。
        token.mint(address(vault), amount * 3);
        // 6. receiver に手数料を返す資金を配る。
        token.mint(address(attacker), fee);

        // attacker が loan を受け、callback 内で amount + fee を返済する。
        // 7. フラッシュローンを開始する。
        attacker.attackFlashLoan("");

        // Vault の元本が減っておらず、feeRecipient が手数料を受け取ったことを検証する。
        // 8. Vault の元本が戻っていることを確認する。
        require(token.balanceOf(address(vault)) == amount * 3, "loan was not settled");
        // 9. 手数料が owner に届いたことを確認する。
        require(token.balanceOf(address(this)) == fee, "fee was not paid to owner");
    }

    // ここから下が今回 JPYC で追加して実行するテスト。
    // JPYC は MockJPYC なので、実際の JPYC のコントラクトアドレスや発行ルールとは異なる。
    // ただし ERC20 の transfer、approve、balanceOf、decimals の学習には使える。

    // 目的: 発行制限のない MockJPYC で「錬金術」が可能なことを意図的に再現する。
    // 成功条件: mint 前後の残高差が、指定した 1,000,000 JPYC と一致すること。
    // このテストが成功することは本番で安全という意味ではなく、モックの危険性を示す。
    function testJPYCAlchemyIsPossibleInMock() external {
        // 1. テスト専用の JPYC をデプロイする。デプロイ直後の全アドレスの残高は0。
        MockJPYC jpyc = new MockJPYC();
        // address(this) は現在実行中の VulnerableVaultTest 自身のアドレス。
        // つまり、テストコントラクトが JPYC を受け取る人になる。
        // 2. mint 前の残高を保存する。後で「どれだけ増えたか」を比較するため。
        uint256 beforeBalance = jpyc.balanceOf(address(this));

        // 「錬金術」の実験: MockJPYC の mint は誰でも呼べるため、残高を勝手に増やせる。
        // 本物の JPYC で同じことができる、という意味ではない。
        // ここで mint が revert せず、残高が増えること自体が MockJPYC の意図的な脆弱性。
        // 3. 誰でも呼べる mint を実行する。ここではテストコントラクト自身が呼び出し元。
        jpyc.mint(address(this), 1_000_000 ether);

        // 4. mint した数量と実際の残高増加量が一致するか検証する。
        require(
            jpyc.balanceOf(address(this)) == beforeBalance + 1_000_000 ether,
            "mock JPYC mint did not increase balance"
        );
    }

    // 目的: JPYC が Vault の入出金に使える ERC20 であることを確認する。
    // 成功条件: 入金した 1,000 JPYC を出金した後、内部残高と totalDeposits が 0 になること。
    function testJPYCDepositAndWithdraw() external {
        // 1. Vault は token アドレスだけを知り、JPYC の実装そのものには依存しない。
        MockJPYC jpyc = new MockJPYC();
        VulnerableVault vault = new VulnerableVault(address(jpyc));
        // 2. user は Vault を利用する別コントラクト。EOA の代わりに callback も担当する。
        ReentrancyAttacker user = new ReentrancyAttacker(address(vault), address(jpyc));

        uint256 amount = 1_000 ether;
        // user に JPYC を渡し、deposit に必要な allowance を後で設定する。
        // 3. user に JPYC を渡す。Vault にはまだ預けていない。
        jpyc.mint(address(user), amount);
        // maxReentries = 0 にすることで、今回は攻撃ではなく正常な出金を行う。
        // 4. 出金額を設定し、再入回数を0にして正常系にする。
        user.configure(amount, 0);
        // 5. Vault が user の JPYC を transferFrom できるようにする。
        user.prepare();
        // 6. deposit -> withdraw を連続して実行する便利なテスト用関数。
        user.attack();

        // 7. 入金と出金が終わり、JPYC の内部残高もゼロに戻っていることを確認する。
        require(vault.balances(address(user)) == 0, "user vault balance should be zero");
        require(vault.totalDeposits() == 0, "total deposits should be zero");
    }

    // 目的: JPYC の出金額から 1% の手数料が分離されることを確認する。
    // 成功条件: feeRecipient の残高だけが 10 JPYC 増えること。
    function testJPYCWithdrawalFee() external {
        // 1. JPYC、Vault、利用者をデプロイする。
        MockJPYC jpyc = new MockJPYC();
        VulnerableVault vault = new VulnerableVault(address(jpyc));
        ReentrancyAttacker user = new ReentrancyAttacker(address(vault), address(jpyc));

        uint256 amount = 1_000 ether;
        // 100 bps = 100 / 10,000 = 1% なので、手数料は 10 JPYC。
        uint256 fee = amount / 100;
        // 第2引数が手数料の受取人。address(this) はこのテストコントラクトを意味する。
        // 2. feeBps=100 は 1%。手数料の送付先をこのテストコントラクトにする。
        vault.setWithdrawalFee(100, address(this));
        // 3. user が amount を出金できるよう、先に残高と allowance を準備する。
        jpyc.mint(address(user), amount);
        user.configure(amount, 0);
        user.prepare();

        // 実行前の残高を保存すると、今回増えた手数料だけを正確に比較できる。
        uint256 ownerBalanceBefore = jpyc.balanceOf(address(this));
        // 4. 出金を実行する。user は amount-fee、feeRecipient は fee を受け取る。
        user.attack();

        // 100 bps = 1%。手数料がこのテストコントラクトへ送られたことを確認する。
        require(
            jpyc.balanceOf(address(this)) == ownerBalanceBefore + fee,
            "withdrawal fee was not paid"
        );
    }

    // 目的: JPYC の flash loan でも元本と手数料を同じトランザクションで返済することを確認する。
    // 成功条件: Vault は元本を維持し、owner は 0.5 JPYC を受け取ること。
    function testJPYCFlashLoanRepayment() external {
        // 1. ローンを出す Vault と、callback で返済する receiver を作る。
        MockJPYC jpyc = new MockJPYC();
        VulnerableVault vault = new VulnerableVault(address(jpyc));
        ReentrancyAttacker receiver = new ReentrancyAttacker(address(vault), address(jpyc));

        uint256 amount = 100 ether;
        // 50 bps = 0.5%。amount / 200 と同じ値になる。
        uint256 fee = amount / 200;
        // 2. Vault に元本、receiver に手数料を用意する。
        vault.setFlashLoanFee(50);
        jpyc.mint(address(vault), amount * 2);
        jpyc.mint(address(receiver), fee);
        // ReentrancyAttacker の初期借入額は10 etherなので、テストのamountに合わせて変更する。
        receiver.configure(amount, 0);

        // flashLoan は同一トランザクション内で借入、callback、元本+手数料の返済を行う。
        // 3. receiver が借入を開始する。返済は receiver.onFlashLoan 内で行われる。
        receiver.attackFlashLoan("");

        // 借りた JPYC と手数料が返済され、手数料だけ owner に移動していることを確認する。
        require(jpyc.balanceOf(address(vault)) == amount * 2, "JPYC loan was not repaid");
        require(jpyc.balanceOf(address(this)) == fee, "JPYC fee was not received");
    }

    // 目的: トークンを JPYC に交換しても、Vault の再入脆弱性の影響が変わらないことを確認する。
    // 成功条件: 再入攻撃が成功せず、call が false を返すこと。
    function testJPYCReentrancyAttemptReverts() external {
        // 1. 攻撃者と Vault に、複数回の出金に使える JPYC を用意する。
        MockJPYC jpyc = new MockJPYC();
        VulnerableVault vault = new VulnerableVault(address(jpyc));
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(vault), address(jpyc));

        uint256 amount = 10 ether;
        jpyc.mint(address(attacker), amount * 3);
        jpyc.mint(address(vault), amount * 3);
        // 2. deposit のための allowance を設定する。
        attacker.prepare();

        // トークンを JPYC に変えても、withdraw の外部コールが先にある再入リスクは変わらない。
        // 期待結果は「成功」ではなく「revert」。脆弱性が検出されることを確認するテスト。
        // 3. 攻撃を実行する。失敗してもテスト全体を巻き戻さないよう low-level call を使う。
        (bool success, ) = address(attacker).call(abi.encodeWithSignature("attack()"));
        // 4. false なら、攻撃は revert したという意味。
        require(!success, "JPYC reentrancy attack should revert");
    }

    // 目的: owner が Vault を停止したとき、JPYC の入金とフラッシュローンが止まることを確認する。
    // 成功条件: paused=true の後に呼んだ2つの処理が、どちらも false を返すこと。
    function testJPYCPauseBlocksDepositAndFlashLoan() external {
        // 1. 通常の JPYC 入金に必要なコントラクトを準備する。
        MockJPYC jpyc = new MockJPYC();
        VulnerableVault vault = new VulnerableVault(address(jpyc));
        ReentrancyAttacker user = new ReentrancyAttacker(address(vault), address(jpyc));
        uint256 amount = 10 ether;

        // 2. paused のチェックより先に進める準備だけ行う。
        jpyc.mint(address(user), amount);
        user.configure(amount, 0);
        user.prepare();

        // 3. owner であるこのテストコントラクトが緊急停止を有効にする。
        vault.setPaused(true);

        // 5. 停止中の user.attack() を実行し、内部の deposit が拒否されることを確認する。
        (bool depositSuccess, ) = address(user).call(abi.encodeWithSignature("attack()"));
        // 6. 入金が失敗したことを確認する。
        require(!depositSuccess, "deposit should be blocked while paused");

        // flashLoan も同じ modifier で拒否される。停止確認が先なので流動性は不要。
        // 7. 停止中のフラッシュローンを試す。
        (bool loanSuccess, ) = address(vault).call(
            abi.encodeWithSignature("flashLoan(address,uint256,bytes)", address(user), amount, "")
        );
        // 8. フラッシュローンが失敗したことを確認する。
        require(!loanSuccess, "flash loan should be blocked while paused");
    }

    // 目的: feeBps の上限チェックが、出金手数料とローン手数料の両方に働くことを確認する。
    // 成功条件: 上限を1 bpsでも超える設定が revert すること。
    function testJPYCFeeLimitsRejectTooHighValues() external {
        // 1. JPYC をデプロイする。
        MockJPYC jpyc = new MockJPYC();
        // 2. JPYC を扱う Vault をデプロイする。
        VulnerableVault vault = new VulnerableVault(address(jpyc));

        // withdrawalFeeBps の上限は1,000。1,001は10.01%なので拒否される。
        // 3. 上限を超える出金手数料を設定する。
        (bool withdrawalFeeSuccess, ) = address(vault).call(
            abi.encodeWithSignature("setWithdrawalFee(uint256,address)", 1_001, address(this))
        );
        // 4. 設定が失敗したことを確認する。
        require(!withdrawalFeeSuccess, "withdrawal fee above limit should revert");

        // flashLoanFeeBps の上限は500。501は5.01%なので拒否される。
        // 5. 上限を超えるフラッシュローン手数料を設定する。
        (bool flashLoanFeeSuccess, ) = address(vault).call(
            abi.encodeWithSignature("setFlashLoanFee(uint256)", 501)
        );
        // 6. 設定が失敗したことを確認する。
        require(!flashLoanFeeSuccess, "flash loan fee above limit should revert");
    }
}
