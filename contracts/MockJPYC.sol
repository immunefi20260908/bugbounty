// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice テスト専用の JPYC 風 ERC20。実際の JPYC の発行権限は再現しない。
contract MockJPYC is ERC20 {
    // ERC20 の名前とシンボルを決める。
    // 変更例: "JPY Coin Mock" を "My Test JPYC" に変えると表示名だけ変わる。
    // ERC20 はデフォルトで decimals() = 18 を返すため、1 JPYC は 1 ether と書ける。
    constructor() ERC20("JPY Coin Mock", "JPYC") {}

    // mint はゼロから新しいトークンを作る処理。
    // to は受取人、amount は作成する最小単位の数量を表す。
    // 学習用に誰でも mint できるため、ここが「錬金術」できる危険な部分。
    // 例: 外部の誰でも mint(address, 1_000_000 ether) を呼べてしまう。
    // 本番トークンでは onlyOwner や AccessControl で発行者を限定する。
    function mint(address to, uint256 amount) external {
        // 1. 指定された受取人へ新しい JPYC を発行する。
        _mint(to, amount);
    }
}
