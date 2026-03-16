# HIVEMIND Treasury V4 — Flap 官方反馈 + 升级需求

## Flap 官方反馈（2026-03-16）

### 问题
1. **回调失败** — AI 请求返回时合约内部出错交易失败（V3 已修复，只记录决策不执行）
2. **合约未在 BSCScan 验证** — 需要 verify source code
3. **税收中心化** — owner 用 emergencyWithdraw 提取 BNB 手动转到另一个合约，太中心化

### 官方建议
1. **可升级代理合约** — 部署 Transparent Proxy 或 UUPS Proxy，这样有问题能在不改变税收接收地址的情况下修改逻辑
2. **内盘交易** — Four.meme 内盘阶段不能走 PancakeSwap。Flap 的 swapExactInput 函数同时支持内盘和外盘交易，查 Four 相关文档
3. **异常处理** — fulfillReasoning 里不要让交易失败，记录 AI 决策，try-catch 执行操作，失败后任何人可手动重试

## 当前合约地址
- Token: 0x13058e1d7428445b09e75550a036a9d84896ffff
- Treasury V3 (当前): 0x961648718af52dd2DA2F83a42385C0C333fB5484
- Treasury V1 (废弃，税收接收): 0x6A55554c53b5d23931057f88EfCDE846Dc2968ac
- DEX Pair: 0x94aE5B563001dB3E4bC96837c832000e947e809F
- PancakeRouter: 0x10ED43C718714eb63d5aA57B78B54704E256024E
- Flap AI Provider (BSC): 查 FlapAIConsumerBase 里的 _getFlapAIProvider()
- ERC-8004 Agent Identifier: 0x09B44A633de9F9EBF6FB9Bdd5b5629d3DD2cef13

## V4 需求

### 1. UUPS Proxy 模式
- 用 OpenZeppelin UUPS Proxy
- Implementation 合约继承 UUPSUpgradeable + Initializable
- 部署 ERC1967Proxy 指向 implementation
- Proxy 地址作为税收接收地址（永久不变）
- 逻辑可通过 upgradeTo() 升级

### 2. 修复内盘交易
- 查 Four.meme 的 swapExactInput 或类似函数
- 回购/加流动性操作要同时支持内盘和外盘
- 如果代币还在内盘，用 Four.meme 的交易函数
- 如果已毕业上 DEX，用 PancakeRouter
- 当前代币已毕业，但合约要兼容两种情况

### 3. 异常处理（V3 已部分实现）
- _fulfillReasoning 只记录决策，不执行操作 ✅
- manualExecute 用 try-catch 包裹执行操作
- 执行失败记录状态，任何人可重试
- 不要 revert

### 4. BSCScan Verify
- 部署后用 forge verify-contract 验证
- 需要 BSCScan API key

### 5. 去中心化税收
- 不再用 emergencyWithdraw + 手动转
- Proxy 地址直接作为 Four.meme 的 founder/recipient
- 税收直接进入可升级合约

## 现有合约源码
- /Users/mac/.openclaw/workspace/hivemind/src/HiveMindTreasury.sol
- /Users/mac/.openclaw/workspace/hivemind/src/VaultBase.sol (如果有)

## Foundry 配置
- /Users/mac/.openclaw/workspace/hivemind/foundry.toml
- Solidity 0.8.20
- forge build --skip script

## 部署信息
- Chain: BSC (56)
- RPC: https://bsc-dataseed.binance.org
- Private key: 从 /Users/mac/.openclaw/workspace/.env 的 PRIVATE_KEY 读取
- Owner/Dev: 0xD82913909e136779E854302E783ecdb06bfc7Ee2
