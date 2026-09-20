// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFlashLoanReceiver {
    // Vault が借り手へ返済を要求するための callback の形を定義する。
    // receiver 側にこの関数がない、または revert すると flashLoan 全体が失敗する。
    function onFlashLoan(address initiator, uint256 amount, uint256 fee, bytes calldata data)
        external;
}

contract VulnerableVault {
    // 読み方: まず状態変数を見ると、このコントラクトが何を記録するか分かる。
    // 変更例: token を別の ERC20 に変える場合は、デプロイ時の _token を変更する。
    IERC20 public immutable token; // Vault が預かる ERC20 のアドレス。
    address public immutable owner; // 管理操作を実行できるアドレス。
    address public feeRecipient; // 出金・ローン手数料の送付先。
    uint256 public withdrawalFeeBps; // 出金手数料。10,000 分の feeBps。
    uint256 public flashLoanFeeBps; // フラッシュローン手数料。10,000 分の feeBps。
    bool public paused; // true のとき whenNotPaused 付き処理を停止する。

    mapping(address => uint256) public balances; // ユーザーごとの Vault 内部残高。
    mapping(address => uint256) public depositedAt; // 最後に入金した block.timestamp。
    uint256 public totalDeposits; // 全ユーザーの balances の合計として記録する値。

    // イベントはチェーン上のログ。フロントエンドや監視ツールが処理結果を追跡するために使う。
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount, uint256 fee);
    event PauseStateChanged(bool paused);
    event WithdrawalFeeChanged(uint256 feeBps, address feeRecipient);
    event FlashLoan(address indexed receiver, uint256 amount, uint256 fee);

    constructor(address _token) {
        // デプロイ時に一度だけ設定される値。immutable は後から変更できない。
        // _token は ERC20 のアドレスで、ここでは MockJPYC も渡せる。
        // 1. Vault が扱うトークンのアドレスを保存する。
        token = IERC20(_token);
        // constructor 内の msg.sender が owner になる。
        // 2. デプロイしたアドレスを owner として保存する。
        owner = msg.sender;
        // 3. 初期状態では owner を手数料受取人にする。
        feeRecipient = msg.sender;
        // 5 basis points = 0.05%。変更例: 初期手数料を 10 にすると 0.10%。
        // 4. フラッシュローンの初期手数料を設定する。
        flashLoanFeeBps = 5;
    }

    // onlyOwner が付いた関数は owner だけ実行できる。
    // 変更例: 管理者を複数人にしたい場合は、この判定を AccessControl などに置き換える。
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // 一時停止中は入出金やフラッシュローンを止める。
    // 読み方: modifier は関数本体の前に実行される共通チェック。
    modifier whenNotPaused() {
        require(!paused, "vault paused");
        _;
    }

    function deposit(uint256 amount) external whenNotPaused {
        // deposit の流れ: 入力確認 -> トークン受取 -> 内部残高更新 -> イベント通知。
        // 変更例: 最小入金額を設けるなら amount >= 1 ether のチェックをここに追加する。
        // 1. 入金数量が0より大きいか確認する。
        require(amount > 0, "zero deposit");
        // 事前に approve が必要。msg.sender のトークンを Vault へ移動する。
        // 2. ユーザーのトークンを Vault へ移動する。
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        // ERC20 の実残高とは別に、Vault 内部の利用可能残高も増やす。
        // 3. ユーザーの内部残高を増やす。
        balances[msg.sender] += amount;
        // 4. Vault 全体の預かり残高を増やす。
        totalDeposits += amount;
        // 5. 最後の入金時刻を記録する。
        depositedAt[msg.sender] = block.timestamp;
        // 6. 入金イベントを記録する。
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external whenNotPaused {
        // withdraw の流れ: 残高確認 -> 手数料計算 -> 外部コール -> トークン送付 -> 残高更新。
        // 注意: 外部コールが残高更新より前にあるため、再入攻撃の学習用に脆弱な順序になっている。
        // 修正例: balances[msg.sender] と totalDeposits を外部コールより先に減らす
        //         (Checks-Effects-Interactions) または nonReentrant を使う。
        // 1. ユーザーの内部残高が十分か確認する。
        require(balances[msg.sender] >= amount, "insufficient balance");
        // 例: amount=1,000、feeBps=100 なら fee=10、利用者には990を送る。
        // 2. 出金手数料を計算する。
        uint256 fee = (amount * withdrawalFeeBps) / 10_000;

        // コントラクト利用者に通知する外部呼び出し。相手が悪意あるコントラクトの場合に再入できる。
        // 3. ユーザーの callback を呼ぶ。ここが再入可能な箇所。
        (bool ok, ) = msg.sender.call(
            abi.encodeWithSignature("onVaultWithdraw(address,uint256)", msg.sender, amount)
        );
        // 4. callback が失敗したら出金全体を取り消す。
        require(ok, "callback failed");

        // 外部 callback 後に、利用者へ手数料を除いたトークンを送る。
        // 5. 手数料を除いた数量をユーザーへ送る。
        require(token.transfer(msg.sender, amount - fee), "transfer failed");
        if (fee > 0) {
            // feeRecipient が owner でなくても、設定されたアドレスへ送る。
            // 6. 手数料があれば受取人へ送る。
            require(token.transfer(feeRecipient, fee), "fee transfer failed");
        }
        // 本来は外部コールの前に行うべき状態更新。この順番が再入リスクの原因。
        // 7. ユーザーの内部残高を減らす。
        balances[msg.sender] -= amount;
        // 8. Vault 全体の預かり残高を減らす。
        totalDeposits -= amount;

        // 9. 出金イベントを記録する。
        emit Withdraw(msg.sender, amount, fee);
    }

    function setPaused(bool nextPaused) external onlyOwner {
        // 変更例: 緊急停止を true、再開を false で呼び出す。
        // paused=true になると deposit、withdraw、flashLoan の先頭で revert する。
        // 1. 停止状態を更新する。
        paused = nextPaused;
        // 2. 停止状態の変更を記録する。
        emit PauseStateChanged(nextPaused);
    }

    function setWithdrawalFee(uint256 feeBps, address nextFeeRecipient) external onlyOwner {
        // feeBps は 1/10000 単位。100 bps = 1%、1000 bps = 10%。
        // 変更例: 上限を厳しくするなら feeBps <= 500 に変更する。
        // 1. 出金手数料の上限を確認する。
        require(feeBps <= 1_000, "fee too high");
        // 2. 手数料受取人がゼロアドレスでないか確認する。
        require(nextFeeRecipient != address(0), "invalid fee recipient");
        // ここから先は次回の withdraw に使われる設定値。
        // 3. 新しい出金手数料を保存する。
        withdrawalFeeBps = feeBps;
        // 4. 新しい手数料受取人を保存する。
        feeRecipient = nextFeeRecipient;
        // 5. 設定変更イベントを記録する。
        emit WithdrawalFeeChanged(feeBps, nextFeeRecipient);
    }

    function availableAssets() external view returns (uint256) {
        // view は状態を変更しない読み取り専用関数。デバッグや画面表示に使える。
        // totalDeposits と一致するとは限らないため、実際のトークン保有量を別に確認できる。
        return token.balanceOf(address(this));
    }

    function flashLoan(address receiver, uint256 amount, bytes calldata data)
        external
        whenNotPaused
    {
        // flashLoan の流れ: 残高確認 -> 貸出 -> receiver の処理 -> 同一トランザクション内で返済確認。
        // 変更例: 利用者を限定する場合は receiver の許可リストを確認する処理を追加する。
        // 1. 借り手アドレスが有効か確認する。
        require(receiver != address(0), "invalid receiver");
        // 2. 借入数量が0より大きいか確認する。
        require(amount > 0, "zero loan");

        // 3. 貸出前の Vault トークン残高を保存する。
        uint256 assetsBefore = token.balanceOf(address(this));
        // 4. Vault に十分な流動性があるか確認する。
        require(assetsBefore >= amount, "insufficient liquidity");
        // fee は借り手が返す追加分。50 bps なら amount の0.5%。
        // 5. フラッシュローン手数料を計算する。
        uint256 fee = (amount * flashLoanFeeBps) / 10_000;

        // ここで一時的に Vault の ERC20 残高が減る。
        // 6. 借り手へ元本を送る。
        require(token.transfer(receiver, amount), "loan transfer failed");
        // 借り手が callback 内で amount + fee を返すことを期待する。
        // 7. 借り手の返済 callback を呼ぶ。
        IFlashLoanReceiver(receiver).onFlashLoan(msg.sender, amount, fee, data);

        // 返済後の残高が、貸出前 + 手数料以上かを確認する。
        // 8. callback 後の Vault 残高を読み取る。
        uint256 assetsAfter = token.balanceOf(address(this));
        // 9. 元本と手数料が返済されたか確認する。
        require(assetsAfter >= assetsBefore + fee, "flash loan not repaid");
        if (fee > 0) {
            // 10. 手数料があれば受取人へ送る。
            require(token.transfer(feeRecipient, fee), "fee transfer failed");
        }

        // 11. フラッシュローンイベントを記録する。
        emit FlashLoan(receiver, amount, fee);
    }

    function setFlashLoanFee(uint256 feeBps) external onlyOwner {
        // 500 bps = 5%。管理者だけが変更でき、変更後の値は次回のローンから使われる。
        // 1. フラッシュローン手数料の上限を確認する。
        require(feeBps <= 500, "fee too high");
        // 変更イベントはないため、本番では監視しやすいイベント追加も検討できる。
        // 2. 新しいフラッシュローン手数料を保存する。
        flashLoanFeeBps = feeBps;
    }
}
