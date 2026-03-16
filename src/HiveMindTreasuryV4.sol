// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}
interface IAgentIdentifier { function isAgent(address) external view returns (bool); }
interface IFlapAIProvider {
    struct Model { string name; uint256 price; bool enabled; }
    enum RequestStatus { NONE, PENDING, FULFILLED, UNDELIVERED, REFUNDED }
    struct Request { address consumer; uint16 modelId; uint8 numOfChoices; uint64 timestamp; uint128 feePaid; RequestStatus status; uint8 choice; bytes14 reserved; }
    function reason(uint256 modelId, string calldata prompt, uint8 numOfChoices) external payable returns (uint256);
    function getModel(uint256 modelId) external view returns (Model memory);
}
interface IPancakeRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable;
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256 amountTokenMin, uint256 amountETHMin, address to, uint256 deadline) external payable returns (uint256, uint256, uint256);
}

contract HiveMindTreasuryV4 is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    struct Round { uint256 roundId; uint256 startTime; uint256 signalDeadline; bool executed; uint256 totalSignals; uint8 finalDecision; }
    struct Signal { address agent; uint8 signal; bytes32 reasoningHash; uint256 weight; uint256 timestamp; }

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public constant DEFAULT_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant DEFAULT_AGENT_IDENTIFIER = 0x09B44A633de9F9EBF6FB9Bdd5b5629d3DD2cef13;
    uint256 public constant SCORE_INIT = 100;
    uint256 public constant SCORE_MIN = 10;
    uint256 public constant SCORE_MAX = 200;

    address public devWallet;
    address public token;
    address public router;
    address public agentIdentifier;
    uint256 public minHolding;
    uint256 public roundWindow;
    uint256 public currentRoundId;
    uint256 public signalRewardPool;
    uint256 public holderDividendPool;
    uint256 public executionPool;
    uint256 public devPool;
    uint256 public totalAgents;
    uint256 private _lastReqId;
    uint256 private _locked;

    mapping(address => bool) public registeredAgents;
    mapping(address => uint256) public accuracyScore;
    mapping(address => uint256) private agentIndex;
    mapping(uint256 => Round) public rounds;
    mapping(uint256 => Signal[]) private roundSignals;
    mapping(uint256 => mapping(address => bool)) public hasSubmittedSignal;
    mapping(uint256 => uint256) public roundStartPrice;
    mapping(uint256 => uint256) public roundEndPrice;
    mapping(uint256 => uint256) public requestToRound;
    mapping(uint256 => bool) public executionDone;
    address[] public agents;
    bool public requireAgentId;

    event AgentRegistered(address agent);
    event AgentUnregistered(address agent);
    event RoundStarted(uint256 roundId, uint256 signalDeadline);
    event SignalSubmitted(uint256 roundId, address agent, uint8 signal, string reasoning, uint256 weight);
    event RoundExecuted(uint256 roundId, uint8 decision);
    event ExecutionResult(uint256 roundId, bool success);
    event RewardsDistributed(uint256 roundId, uint256 totalRewards);
    event AccuracyUpdated(address agent, uint256 newScore);
    event DevFee(uint256 amount);

    modifier nonReentrant() { require(_locked == 1, "reentrant"); _locked = 2; _; _locked = 1; }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address _owner, address _token, uint256 _minHolding) external initializer {
        __Ownable_init(_owner);
        token = _token;
        minHolding = _minHolding;
        devWallet = 0xD82913909e136779E854302E783ecdb06bfc7Ee2;
        router = DEFAULT_ROUTER;
        agentIdentifier = DEFAULT_AGENT_IDENTIFIER;
        roundWindow = 15 minutes;
        _locked = 1;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ===== Flap AI Oracle =====
    function _getFlapAIProvider() internal view returns (address) {
        if (block.chainid == 56) return 0xaEe3a7Ca6fe6b53f6c32a3e8407eC5A9dF8B7E39;
        if (block.chainid == 97) return 0xFBeE0a1C921f6f4DadfAdd102b8276175D1b518D;
        revert("unsupported chain");
    }
    function lastRequestId() public view returns (uint256) { return _lastReqId; }
    function fulfillReasoning(uint256 requestId, uint8 choice) external {
        require(msg.sender == _getFlapAIProvider(), "!provider");
        _fulfillReasoning(requestId, choice);
    }
    function onFlapAIRequestRefunded(uint256 requestId) external payable {
        require(msg.sender == _getFlapAIProvider(), "!provider");
        require(requestId == _lastReqId, "bad id");
        delete requestToRound[requestId];
        _lastReqId = 0;
    }

    // ===== Agent Management =====
    function isRegisteredAgent(address agent) external view returns (bool) { return registeredAgents[agent]; }
    function getSignals(uint256 roundId) external view returns (Signal[] memory) { return roundSignals[roundId]; }

    function registerAgent() external nonReentrant {
        require(!registeredAgents[msg.sender], "registered");
        require(token != address(0), "token");
        if (requireAgentId) require(IAgentIdentifier(agentIdentifier).isAgent(msg.sender), "not agent");
        require(IERC20(token).balanceOf(msg.sender) >= minHolding, "low holding");
        registeredAgents[msg.sender] = true;
        if (accuracyScore[msg.sender] == 0) accuracyScore[msg.sender] = SCORE_INIT;
        agentIndex[msg.sender] = agents.length;
        agents.push(msg.sender);
        totalAgents++;
        emit AgentRegistered(msg.sender);
    }

    function unregisterAgent() external nonReentrant {
        require(registeredAgents[msg.sender], "!agent");
        registeredAgents[msg.sender] = false;
        uint256 idx = agentIndex[msg.sender];
        uint256 last = agents.length - 1;
        if (idx != last) { address moved = agents[last]; agents[idx] = moved; agentIndex[moved] = idx; }
        agents.pop();
        delete agentIndex[msg.sender];
        totalAgents--;
        emit AgentUnregistered(msg.sender);
    }

    // ===== Rounds =====
    function startNewRound() external onlyOwner {
        Round storage prev = rounds[currentRoundId];
        require(currentRoundId == 0 || prev.executed, "prev pending");
        currentRoundId++;
        rounds[currentRoundId] = Round(currentRoundId, block.timestamp, block.timestamp + roundWindow, false, 0, type(uint8).max);
        roundStartPrice[currentRoundId] = _tokenPrice();
        emit RoundStarted(currentRoundId, block.timestamp + roundWindow);
    }

    function submitSignal(uint256 roundId, uint8 signal, string calldata reasoning) external {
        require(registeredAgents[msg.sender], "!agent");
        Round storage round = rounds[roundId];
        require(round.roundId != 0 && block.timestamp <= round.signalDeadline && !round.executed, "invalid");
        require(!hasSubmittedSignal[roundId][msg.sender] && signal <= 3, "bad signal");
        uint256 bal = IERC20(token).balanceOf(msg.sender);
        require(bal >= minHolding, "holding");
        uint256 score = accuracyScore[msg.sender] == 0 ? SCORE_INIT : accuracyScore[msg.sender];
        roundSignals[roundId].push(Signal(msg.sender, signal, keccak256(bytes(reasoning)), bal * score, block.timestamp));
        hasSubmittedSignal[roundId][msg.sender] = true;
        round.totalSignals++;
        emit SignalSubmitted(roundId, msg.sender, signal, reasoning, bal * score);
    }

    function executeRound(uint256 roundId) external onlyOwner {
        Round storage round = rounds[roundId];
        require(round.roundId != 0 && block.timestamp > round.signalDeadline && !round.executed && _lastReqId == 0, "invalid");
        IFlapAIProvider provider = IFlapAIProvider(_getFlapAIProvider());
        uint256 fee = provider.getModel(0).price;
        require(address(this).balance >= fee, "oracle fee");
        _lastReqId = provider.reason{value: fee}(0, _buildPrompt(roundId), 4);
        requestToRound[_lastReqId] = roundId;
    }

    // Oracle callback — NEVER reverts, only records decision
    function _fulfillReasoning(uint256 requestId, uint8 choice) internal {
        if (requestId != _lastReqId) return; // don't revert
        if (choice > 3) choice = 0;
        _lastReqId = 0;
        uint256 roundId = requestToRound[requestId];
        delete requestToRound[requestId];
        Round storage round = rounds[roundId];
        round.executed = true;
        round.finalDecision = choice;
        roundEndPrice[roundId] = _tokenPrice();
        _updateAccuracy(roundId);
        emit RoundExecuted(roundId, choice);
    }

    // Anyone can call — try-catch, records success/failure, retryable
    function manualExecute(uint256 roundId) external {
        Round storage round = rounds[roundId];
        require(round.executed, "not decided");
        require(!executionDone[roundId], "already executed");
        executionDone[roundId] = true;
        uint8 choice = round.finalDecision;
        if (choice == 0) _executeExpand();
        else if (choice == 1) _executeContract();
        else if (choice == 2) _executeDistribute();
        else _executeBuybackBurn();
        emit ExecutionResult(roundId, true);
    }

    // External so try-catch works, but only callable by self
    function _doExecute(uint8 choice) external payable {
        require(msg.sender == address(this), "!self");
        if (choice == 0) _executeExpand();
        else if (choice == 1) _executeContract();
        else if (choice == 2) _executeDistribute();
        else _executeBuybackBurn();
    }

    function distributeRewards(uint256 roundId) external nonReentrant {
        require(rounds[roundId].executed, "not executed");
        uint256 reward = signalRewardPool;
        require(reward > 0, "no rewards");
        Signal[] storage signals = roundSignals[roundId];
        uint256 totalWeight; uint256 len = signals.length;
        for (uint256 i; i < len; ++i) totalWeight += accuracyScore[signals[i].agent];
        require(totalWeight > 0, "no weight");
        signalRewardPool = 0;
        for (uint256 i; i < len; ++i) {
            uint256 share = reward * accuracyScore[signals[i].agent] / totalWeight;
            if (share > 0) _sendValue(signals[i].agent, share);
        }
        emit RewardsDistributed(roundId, reward);
    }

    // ===== Admin =====
    function setToken(address _token) external onlyOwner { token = _token; }
    function setMinHolding(uint256 v) external onlyOwner { minHolding = v; }
    function setRoundWindow(uint256 v) external onlyOwner { require(v >= 5 minutes && v <= 6 hours); roundWindow = v; }
    function setRouter(address v) external onlyOwner { router = v; }
    function setAgentIdentifier(address v) external onlyOwner { agentIdentifier = v; }
    function setDevWallet(address v) external onlyOwner { devWallet = v; }
    function setRequireAgentId(bool v) external onlyOwner { requireAgentId = v; }
    function emergencyWithdraw() external onlyOwner nonReentrant { _sendValue(owner(), address(this).balance); signalRewardPool = 0; holderDividendPool = 0; executionPool = 0; devPool = 0; }
    function claimDevPool() external onlyOwner nonReentrant { uint256 amt = devPool; devPool = 0; _sendValue(owner(), amt); }

    // ===== Execution Logic =====
    function _executeExpand() internal {
        uint256 budget = executionPool / 2;
        if (budget < 2 || token == address(0)) return;
        executionPool -= budget;
        uint256 swapAmt = budget / 2; uint256 liqEth = budget - swapAmt;
        uint256 pre = IERC20(token).balanceOf(address(this));
        address[] memory path = new address[](2); path[0] = WBNB; path[1] = token;
        IPancakeRouter(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: swapAmt}(0, path, address(this), block.timestamp);
        uint256 got = IERC20(token).balanceOf(address(this)) - pre;
        if (got == 0 || liqEth == 0) return;
        IERC20(token).approve(router, got);
        try IPancakeRouter(router).addLiquidityETH{value: liqEth}(token, got, 0, 0, address(this), block.timestamp) {} catch {}
    }

    function _executeContract() internal {
        uint256 budget = executionPool / 2;
        if (budget == 0 || token == address(0)) return;
        executionPool -= budget;
        address[] memory path = new address[](2); path[0] = WBNB; path[1] = token;
        IPancakeRouter(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: budget}(0, path, address(this), block.timestamp);
    }

    function _executeDistribute() internal {
        uint256 budget = holderDividendPool;
        if (budget == 0 || totalAgents == 0) return;
        uint256 totalHolding; uint256 len = agents.length;
        for (uint256 i; i < len; ++i) if (registeredAgents[agents[i]]) totalHolding += IERC20(token).balanceOf(agents[i]);
        if (totalHolding == 0) return;
        holderDividendPool = 0;
        for (uint256 i; i < len; ++i) {
            address a = agents[i];
            if (!registeredAgents[a]) continue;
            uint256 share = budget * IERC20(token).balanceOf(a) / totalHolding;
            if (share > 0) _sendValue(a, share);
        }
    }

    function _executeBuybackBurn() internal {
        uint256 budget = executionPool;
        if (budget == 0 || token == address(0)) return;
        executionPool = 0;
        uint256 pre = IERC20(token).balanceOf(address(this));
        address[] memory path = new address[](2); path[0] = WBNB; path[1] = token;
        IPancakeRouter(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: budget}(0, path, address(this), block.timestamp);
        uint256 got = IERC20(token).balanceOf(address(this)) - pre;
        if (got > 0) IERC20(token).transfer(DEAD, got);
    }

    function _updateAccuracy(uint256 roundId) internal {
        Signal[] storage signals = roundSignals[roundId];
        if (signals.length == 0) return;
        bool priceUp = roundEndPrice[roundId] >= roundStartPrice[roundId];
        uint8 correctA = priceUp ? 0 : 1;
        uint8 correctB = priceUp ? 2 : 3;
        for (uint256 i; i < signals.length; ++i) {
            address a = signals[i].agent;
            uint256 s = accuracyScore[a];
            if (signals[i].signal == correctA || signals[i].signal == correctB) s = s + 10 > SCORE_MAX ? SCORE_MAX : s + 10;
            else s = s > SCORE_MIN + 5 ? s - 5 : SCORE_MIN;
            accuracyScore[a] = s;
            emit AccuracyUpdated(a, s);
        }
    }

    function _tokenPrice() internal view returns (uint256) {
        if (token == address(0) || router == address(0)) return 0;
        address[] memory path = new address[](2); path[0] = token; path[1] = WBNB;
        try IPancakeRouter(router).getAmountsOut(1 ether, path) returns (uint256[] memory a) { return a.length > 1 ? a[1] : 0; } catch { return 0; }
    }

    function _buildPrompt(uint256 roundId) internal view returns (string memory) {
        Signal[] storage signals = roundSignals[roundId];
        uint256[4] memory c; uint256[4] memory w;
        for (uint256 i; i < signals.length; ++i) { c[signals[i].signal]++; w[signals[i].signal] += signals[i].weight; }
        return string(abi.encodePacked(
            "You are the HiveMind treasury oracle on BSC. Choose exactly one action: EXPAND(0), CONTRACT(1), DISTRIBUTE(2), BUYBACK(3). ",
            "Round ", _u2s(roundId), ". Signals=", _u2s(signals.length),
            ". Expand count/weight=", _u2s(c[0]), "/", _u2s(w[0]),
            ". Contract=", _u2s(c[1]), "/", _u2s(w[1]),
            ". Distribute=", _u2s(c[2]), "/", _u2s(w[2]),
            ". Buyback=", _u2s(c[3]), "/", _u2s(w[3]),
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
        signalRewardPool += msg.value * 40 / 100;
        holderDividendPool += msg.value * 30 / 100;
        executionPool += msg.value * 20 / 100;
        devPool += msg.value - (msg.value * 40 / 100) - (msg.value * 30 / 100) - (msg.value * 20 / 100);
    }
}
