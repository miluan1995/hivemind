# HIVEMIND Dashboard 需求

## 目标
一个纯前端静态网站，展示 $HIVEMIND 每轮 Agent 决策的公示面板。

## 技术栈
- 纯 HTML + CSS + JS（单文件 index.html）
- 用 ethers.js v6 CDN 直接读链上数据
- 不需要后端
- 暗色主题，科技感

## 合约信息
```
Treasury Proxy: 0x8f873d3CBD1ECA74222345765f5d58098d4Ae98E
Token: 0x13058e1d7428445b09e75550a036a9d84896ffff
Chain: BSC (56)
RPC: https://bsc-dataseed.binance.org
```

## ABI（需要的函数）
```solidity
function currentRoundId() view returns (uint256)
function rounds(uint256) view returns (uint256 roundId, uint256 startTime, uint256 signalDeadline, bool executed, uint256 totalSignals, uint8 finalDecision)
function getSignals(uint256 roundId) view returns (tuple(address agent, uint8 signal, bytes32 reasoningHash, uint256 weight, uint256 timestamp)[])
function signalRewardPool() view returns (uint256)
function holderDividendPool() view returns (uint256)
function executionPool() view returns (uint256)
function devPool() view returns (uint256)
function totalAgents() view returns (uint256)
function executionDone(uint256) view returns (bool)
function accuracyScore(address) view returns (uint256)
function roundStartPrice(uint256) view returns (uint256)
function roundEndPrice(uint256) view returns (uint256)
```

Token ABI:
```solidity
function balanceOf(address) view returns (uint256)
function totalSupply() view returns (uint256)
```

## 页面布局

### 顶部 Header
- $HIVEMIND 标题 + logo
- 总销毁数量（实时）
- 总供应量
- 注册 Agent 数
- Treasury 余额

### 当前轮次卡片（高亮）
- Round ID
- 状态：信号收集中 / 等待Oracle / 已执行
- 倒计时（距离窗口关闭）
- 已提交信号数
- 信号列表（agent地址缩写 + 信号类型 + 权重）

### 历史轮次列表
遍历 Round 1 到 currentRoundId，每轮显示：
- Round ID
- 开始时间（格式化）
- 参与 Agent 数
- 最终决策（EXPAND/CONTRACT/DISTRIBUTE/BUYBACK + 对应颜色）
- 执行状态（✅ 已执行 / ⏳ 待执行）
- 信号详情（展开/折叠）
  - 每个 agent 的地址、信号、权重、时间

### 资金池面板
四个池子的实时余额：
- 信号奖励池 (40%)
- 持币分红池 (30%)
- 执行池 (20%)
- 开发基金 (10%)
进度条可视化

### 时间线视图
每轮的完整时间线：
开启 → 信号提交 → 窗口关闭 → Oracle决策 → 执行 → 奖励发放

## 信号类型映射
- 0: EXPAND (绿色)
- 1: CONTRACT (红色)  
- 2: DISTRIBUTE (蓝色)
- 3: BUYBACK (橙色)
- 255: 未决策 (灰色)

## 自动刷新
每 30 秒自动刷新数据

## 输出
单文件 /Users/mac/.openclaw/workspace/hivemind/dashboard/index.html
