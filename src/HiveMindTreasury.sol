// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IAgentIdentifier { function isAgent(address) external view returns (bool); }

interface IFlapAIProvider {
    struct Model { string name; uint256 price; bool enabled; }
    enum RequestStatus { NONE, PENDING, FULFILLED, UNDELIVERED, REFUNDED }
    struct Request {
        address consumer; uint16 modelId; uint8 numOfChoices; uint64 timestamp;
        uint128 feePaid; RequestStatus status; uint8 choice; bytes14 reserved;
    }
    function reason(uint256 modelId, string calldata prompt, uint8 numOfChoices) external payable returns (uint256);
    function getModel(uint256 modelId) external view returns (Model memory);
    function getRequest(uint256 requestId) external view returns (Request memory);
}

interface IPancakeRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external payable;
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function addLiquidityETH(
        address token, uint256 amountTokenDesired, uint256 amountTokenMin, uint256 amountETHMin, address to, uint256 deadline
    ) external payable returns (uint256, uint256, uint256);
}

abstract contract FlapAIConsumerBase {
    error FlapAIConsumerOnlyProvider();
    error FlapAIConsumerUnsupportedChain(uint256 chainId);
    function lastRequestId() public view virtual returns (uint256);
    function _fulfillReasoning(uint256 requestId, uint8 choice) internal virtual;
    function _onFlapAIRequestRefunded(uint256 requestId) internal virtual;
    function _getFlapAIProvider() internal view virtual returns (address) {
        if (block.chainid == 56) return 0xaEe3a7Ca6fe6b53f6c32a3e8407eC5A9dF8B7E39;
        if (block.chainid == 97) return 0xFBeE0a1C921f6f4DadfAdd102b8276175D1b518D;
        revert FlapAIConsumerUnsupportedChain(block.chainid);
    }
    function fulfillReasoning(uint256 requestId, uint8 choice) external {
        if (msg.sender != _getFlapAIProvider()) revert FlapAIConsumerOnlyProvider();
        _fulfillReasoning(requestId, choice);
    }
    function onFlapAIRequestRefunded(uint256 requestId) external payable {
        if (msg.sender != _getFlapAIProvider()) revert FlapAIConsumerOnlyProvider();
        _onFlapAIRequestRefunded(requestId);
    }
}

abstract contract VaultBase {
    error UnsupportedChain(uint256 chainId);
    function _getPortal() internal view returns (address) {
        if (block.chainid == 56) return 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
        if (block.chainid == 97) return 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9;
        revert UnsupportedChain(block.chainid);
    }
    function _getGuardian() internal view returns (address) {
        if (block.chainid == 56) return 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
        if (block.chainid == 97) return 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
        revert UnsupportedChain(block.chainid);
    }
    function description() public view virtual returns (string memory);
}

contract HiveMindTreasury is VaultBase, FlapAIConsumerBase {
    struct Round { uint256 roundId; uint256 startTime; uint256 signalDeadline; bool executed; uint256 totalSignals; uint8 finalDecision; }
    struct Signal { address agent; uint8 signal; bytes32 reasoningHash; uint256 weight; uint256 timestamp; }

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public constant DEFAULT_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant DEFAULT_AGENT_IDENTIFIER = 0x09B44A633de9F9EBF6FB9Bdd5b5629d3DD2cef13;
    uint256 public roundWindow = 15 minutes;
    uint256 public constant SCORE_INIT = 100;
    uint256 public constant SCORE_MIN = 10;
    uint256 public constant SCORE_MAX = 200;

    address public owner;
    address public devWallet;
    address public pendingOwner;
    address public token;
    address public router = DEFAULT_ROUTER;
    address public agentIdentifier = DEFAULT_AGENT_IDENTIFIER;
    uint256 public minHolding;
    uint256 public currentRoundId;
    uint256 public signalRewardPool;
    uint256 public holderDividendPool;
    uint256 public executionPool;
    uint256 public devPool;
    uint256 public totalAgents;
    uint256 private _lastReqId;
    uint256 private _locked = 1;

    mapping(address => bool) public registeredAgents;
    mapping(address => uint256) public accuracyScore;
    mapping(address => uint256) private agentIndex;
    mapping(uint256 => Round) public rounds;
    mapping(uint256 => Signal[]) private roundSignals;
    mapping(uint256 => mapping(address => bool)) public hasSubmittedSignal;
    mapping(uint256 => uint256) public roundStartPrice;
    mapping(uint256 => uint256) public roundEndPrice;
    mapping(uint256 => uint256) public requestToRound;
    address[] public agents;

    event AgentRegistered(address agent);
    event AgentUnregistered(address agent);
    event RoundStarted(uint256 roundId, uint256 signalDeadline);
    event SignalSubmitted(uint256 roundId, address agent, uint8 signal, string reasoning, uint256 weight);
    event RoundExecuted(uint256 roundId, uint8 decision);
    event RewardsDistributed(uint256 roundId, uint256 totalRewards);
    event AccuracyUpdated(address agent, uint256 newScore);
    event DevFee(uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() { require(msg.sender == owner, "!owner"); _; }
    modifier onlyRegisteredAgent() { require(registeredAgents[msg.sender], "!agent"); _; }
    modifier nonReentrant() { require(_locked == 1, "reentrant"); _locked = 2; _; _locked = 1; }

    constructor(address _owner, address _token, uint256 _minHolding) {
        owner = _owner == address(0) ? msg.sender : _owner;
        token = _token;
        minHolding = _minHolding;
        devWallet = 0xD82913909e136779E854302E783ecdb06bfc7Ee2;
    }

    function description() public pure override returns (string memory) { return "HiveMind Treasury -- agent-gated signal treasury"; }
    function lastRequestId() public view override returns (uint256) { return _lastReqId; }
    function isRegisteredAgent(address agent) external view returns (bool) { return registeredAgents[agent]; }
    function getSignals(uint256 roundId) external view returns (Signal[] memory) { return roundSignals[roundId]; }

    function registerAgent() external nonReentrant {
        require(!registeredAgents[msg.sender], "registered");
        require(token != address(0), "token");
        require(IAgentIdentifier(agentIdentifier).isAgent(msg.sender), "not agent");
        require(IERC20(token).balanceOf(msg.sender) >= minHolding, "low holding");
        registeredAgents[msg.sender] = true;
        if (accuracyScore[msg.sender] == 0) accuracyScore[msg.sender] = SCORE_INIT;
        agentIndex[msg.sender] = agents.length;
        agents.push(msg.sender);
        totalAgents++;
        emit AgentRegistered(msg.sender);
    }

    function unregisterAgent() external nonReentrant onlyRegisteredAgent {
        registeredAgents[msg.sender] = false;
        uint256 idx = agentIndex[msg.sender];
        uint256 last = agents.length - 1;
        if (idx != last) {
            address moved = agents[last];
            agents[idx] = moved;
            agentIndex[moved] = idx;
        }
        agents.pop();
        delete agentIndex[msg.sender];
        totalAgents--;
        emit AgentUnregistered(msg.sender);
    }

    function startNewRound() external onlyOwner {
        Round storage prev = rounds[currentRoundId];
        require(currentRoundId == 0 || prev.executed, "prev pending");
        currentRoundId++;
        rounds[currentRoundId] = Round({
            roundId: currentRoundId,
            startTime: block.timestamp,
            signalDeadline: block.timestamp + roundWindow,
            executed: false,
            totalSignals: 0,
            finalDecision: type(uint8).max
        });
        roundStartPrice[currentRoundId] = _tokenPrice();
        emit RoundStarted(currentRoundId, block.timestamp + roundWindow);
    }

    function submitSignal(uint256 roundId, uint8 signal, string calldata reasoning) external onlyRegisteredAgent {
        Round storage round = rounds[roundId];
        require(round.roundId != 0, "round");
        require(block.timestamp <= round.signalDeadline, "closed");
        require(!round.executed, "done");
        require(!hasSubmittedSignal[roundId][msg.sender], "submitted");
        require(signal <= 3, "signal");
        uint256 bal = IERC20(token).balanceOf(msg.sender);
        require(bal >= minHolding, "holding");
        uint256 score = accuracyScore[msg.sender] == 0 ? SCORE_INIT : accuracyScore[msg.sender];
        uint256 weight = bal * score;
        roundSignals[roundId].push(Signal({
            agent: msg.sender,
            signal: signal,
            reasoningHash: keccak256(bytes(reasoning)),
            weight: weight,
            timestamp: block.timestamp
        }));
        hasSubmittedSignal[roundId][msg.sender] = true;
        round.totalSignals++;
        emit SignalSubmitted(roundId, msg.sender, signal, reasoning, weight);
    }

    function executeRound(uint256 roundId) external onlyOwner {
        Round storage round = rounds[roundId];
        require(round.roundId != 0, "round");
        require(block.timestamp > round.signalDeadline, "window");
        require(!round.executed, "done");
        require(_lastReqId == 0, "pending oracle");
        IFlapAIProvider provider = IFlapAIProvider(_getFlapAIProvider());
        uint256 fee = provider.getModel(0).price;
        require(address(this).balance >= fee, "oracle fee");
        _lastReqId = provider.reason{value: fee}(0, _buildPrompt(roundId), 4);
        requestToRound[_lastReqId] = roundId;
    }

    function distributeRewards(uint256 roundId) external onlyOwner nonReentrant {
        require(rounds[roundId].executed, "not executed");
        uint256 reward = signalRewardPool;
        require(reward > 0, "no rewards");
        Signal[] storage signals = roundSignals[roundId];
        uint256 totalWeight;
        uint256 len = signals.length;
        for (uint256 i; i < len; ++i) totalWeight += accuracyScore[signals[i].agent];
        require(totalWeight > 0, "no weight");
        signalRewardPool = 0;
        for (uint256 i; i < len; ++i) {
            uint256 share = reward * accuracyScore[signals[i].agent] / totalWeight;
            if (share > 0) _sendValue(signals[i].agent, share);
        }
        emit RewardsDistributed(roundId, reward);
    }

    function setToken(address _token) external onlyOwner { token = _token; }
    function setMinHolding(uint256 _minHolding) external onlyOwner { minHolding = _minHolding; }
    function setRoundWindow(uint256 _window) external onlyOwner { require(_window >= 5 minutes && _window <= 6 hours, "5m-6h"); roundWindow = _window; }
    function setRouter(address _router) external onlyOwner { router = _router; }
    function setAgentIdentifier(address _agentIdentifier) external onlyOwner { agentIdentifier = _agentIdentifier; }
    function transferOwnership(address newOwner) external onlyOwner { pendingOwner = newOwner; emit OwnershipTransferStarted(owner, newOwner); }
    function acceptOwnership() external { require(msg.sender == pendingOwner, "!pending"); emit OwnershipTransferred(owner, pendingOwner); owner = pendingOwner; pendingOwner = address(0); }
    function emergencyWithdraw() external onlyOwner nonReentrant { _sendValue(owner, address(this).balance); signalRewardPool = 0; holderDividendPool = 0; executionPool = 0; devPool = 0; }
    function claimDevPool() external onlyOwner nonReentrant { uint256 amt = devPool; devPool = 0; _sendValue(owner, amt); }

    function _fulfillReasoning(uint256 requestId, uint8 choice) internal override {
        require(requestId == _lastReqId, "bad id");
        require(choice <= 3, "bad choice");
        _lastReqId = 0;
        uint256 roundId = requestToRound[requestId];
        delete requestToRound[requestId];
        Round storage round = rounds[roundId];
        round.executed = true;
        round.finalDecision = choice;
        roundEndPrice[roundId] = _tokenPrice();
        _updateAccuracy(roundId);
        if (choice == 0) _executeExpand();
        else if (choice == 1) _executeContract();
        else if (choice == 2) _executeDistribute();
        else _executeBuybackBurn();
        emit RoundExecuted(roundId, choice);
    }

    function _onFlapAIRequestRefunded(uint256 requestId) internal override { require(requestId == _lastReqId, "bad id"); delete requestToRound[requestId]; _lastReqId = 0; }

    function _executeExpand() internal nonReentrant {
        uint256 budget = executionPool / 2;
        if (budget < 2 || token == address(0)) return;
        executionPool -= budget;
        uint256 swapAmt = budget / 2;
        uint256 liqEth = budget - swapAmt;
        uint256 pre = IERC20(token).balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = WBNB; path[1] = token;
        IPancakeRouter(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: swapAmt}(0, path, address(this), block.timestamp);
        uint256 got = IERC20(token).balanceOf(address(this)) - pre;
        if (got == 0 || liqEth == 0) return;
        IERC20(token).approve(router, got);
        try IPancakeRouter(router).addLiquidityETH{value: liqEth}(token, got, 0, 0, address(this), block.timestamp) {} catch {}
    }

    function _executeContract() internal nonReentrant {
        uint256 budget = executionPool / 2;
        if (budget == 0 || token == address(0)) return;
        executionPool -= budget;
        address[] memory path = new address[](2);
        path[0] = WBNB; path[1] = token;
        IPancakeRouter(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: budget}(0, path, address(this), block.timestamp);
    }

    function _executeDistribute() internal nonReentrant {
        uint256 budget = holderDividendPool;
        if (budget == 0 || totalAgents == 0 || token == address(0)) return;
        uint256 totalHolding;
        uint256 len = agents.length;
        for (uint256 i; i < len; ++i) if (registeredAgents[agents[i]]) totalHolding += IERC20(token).balanceOf(agents[i]);
        if (totalHolding == 0) return;
        holderDividendPool = 0;
        for (uint256 i; i < len; ++i) {
            address agent = agents[i];
            if (!registeredAgents[agent]) continue;
            uint256 bal = IERC20(token).balanceOf(agent);
            uint256 share = budget * bal / totalHolding;
            if (share > 0) _sendValue(agent, share);
        }
    }

    function _executeBuybackBurn() internal nonReentrant {
        uint256 budget = executionPool;
        if (budget == 0 || token == address(0)) return;
        executionPool = 0;
        uint256 pre = IERC20(token).balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = WBNB; path[1] = token;
        IPancakeRouter(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: budget}(0, path, address(this), block.timestamp);
        uint256 got = IERC20(token).balanceOf(address(this)) - pre;
        if (got > 0) require(IERC20(token).transfer(DEAD, got), "burn transfer failed");
    }

    function _updateAccuracy(uint256 roundId) internal {
        Signal[] storage signals = roundSignals[roundId];
        if (signals.length == 0) return;
        bool priceUp = roundEndPrice[roundId] >= roundStartPrice[roundId];
        uint8 correctA = priceUp ? 0 : 1;
        uint8 correctB = priceUp ? 2 : 3;
        for (uint256 i; i < signals.length; ++i) {
            address agent = signals[i].agent;
            uint256 score = accuracyScore[agent];
            if (signals[i].signal == correctA || signals[i].signal == correctB) score = score + 10 > SCORE_MAX ? SCORE_MAX : score + 10;
            else score = score > SCORE_MIN + 5 ? score - 5 : SCORE_MIN;
            accuracyScore[agent] = score;
            emit AccuracyUpdated(agent, score);
        }
    }

    function _tokenPrice() internal view returns (uint256) {
        if (token == address(0) || router == address(0)) return 0;
        address[] memory path = new address[](2);
        path[0] = token; path[1] = WBNB;
        try IPancakeRouter(router).getAmountsOut(1 ether, path) returns (uint256[] memory amounts) {
            return amounts.length > 1 ? amounts[1] : 0;
        } catch { return 0; }
    }

    function _buildPrompt(uint256 roundId) internal view returns (string memory) {
        Signal[] storage signals = roundSignals[roundId];
        uint256[4] memory count;
        uint256[4] memory weight;
        for (uint256 i; i < signals.length; ++i) {
            count[signals[i].signal]++;
            weight[signals[i].signal] += signals[i].weight;
        }
        return string(abi.encodePacked(
            "You are the HiveMind treasury oracle on BSC. Choose exactly one action: EXPAND(0), CONTRACT(1), DISTRIBUTE(2), BUYBACK(3). ",
            "Round ", _u2s(roundId), ". Signals=", _u2s(signals.length),
            ". Expand count/weight=", _u2s(count[0]), "/", _u2s(weight[0]),
            ". Contract=", _u2s(count[1]), "/", _u2s(weight[1]),
            ". Distribute=", _u2s(count[2]), "/", _u2s(weight[2]),
            ". Buyback=", _u2s(count[3]), "/", _u2s(weight[3]),
            ". Pools reward/dividend/execution/dev=", _u2s(signalRewardPool), "/", _u2s(holderDividendPool), "/", _u2s(executionPool), "/", _u2s(devPool),
            ". Token price in WBNB per 1e18 token=", _u2s(_tokenPrice()), ". Choose the best treasury action."
        ));
    }

    function _sendValue(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "send failed");
    }

    function _u2s(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 t = v; uint256 d;
        while (t != 0) { d++; t /= 10; }
        bytes memory b = new bytes(d);
        while (v != 0) { b[--d] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }

    receive() external payable {
        if (msg.value == 0) return;
        // Dev 回流：总交易税 3% 中的 1% 归 dev（即入账的 33.33%）
        uint256 devCut = msg.value * 3333 / 10000;
        if (devCut > 0 && devWallet != address(0)) {
            (bool ok,) = devWallet.call{value: devCut}("");
            if (ok) emit DevFee(devCut);
        }
        // 剩余 66.67%（= 总交易量的 2%）按比例分配
        uint256 remaining = msg.value - devCut;
        signalRewardPool += remaining * 40 / 100;
        holderDividendPool += remaining * 30 / 100;
        executionPool += remaining * 20 / 100;
        devPool += remaining - (remaining * 40 / 100) - (remaining * 30 / 100) - (remaining * 20 / 100);
    }
}
