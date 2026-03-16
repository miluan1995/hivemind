#!/usr/bin/env node
// HIVEMIND Auto-Participate Agent
// Usage: PRIVATE_KEY=0x... node auto-participate.js

const { execSync } = require("child_process");

const T = "0x961648718af52dd2DA2F83a42385C0C333fB5484";
const RPC = "https://bsc-dataseed.binance.org";
const PK = process.env.PRIVATE_KEY;
if (!PK) { console.error("Set PRIVATE_KEY env"); process.exit(1); }

function cast(cmd) {
  try {
    return execSync(`ALL_PROXY= cast ${cmd} --rpc-url ${RPC}`, { encoding: "utf8", env: { ...process.env, ALL_PROXY: "" } }).trim();
  } catch (e) { return null; }
}

function castSend(fn, ...args) {
  const a = args.length ? " " + args.join(" ") : "";
  return cast(`send ${T} "${fn}"${a} --private-key ${PK}`);
}

function getRound(id) {
  const r = cast(`call ${T} "rounds(uint256)(uint256,uint256,uint256,bool,uint256,uint8)" ${id}`);
  if (!r) return null;
  const lines = r.split("\n").map(l => l.trim());
  return {
    id: parseInt(lines[0]), start: parseInt(lines[1]),
    deadline: parseInt(lines[2]), executed: lines[3] === "true",
    signals: parseInt(lines[4]), decision: parseInt(lines[5])
  };
}

function decideSignal() {
  // Simple strategy: alternate BUYBACK/EXPAND based on round parity
  // Replace with your AI logic
  const hour = new Date().getHours();
  if (hour < 8 || hour > 22) return 1; // HOLD at night
  return Math.random() > 0.5 ? 2 : 3;  // EXPAND or BUYBACK
}

async function tick() {
  const roundId = parseInt(cast(`call ${T} "currentRoundId()(uint256)"`) || "0");
  if (!roundId) { console.log("No active round"); return; }

  const round = getRound(roundId);
  if (!round) return;

  const now = Math.floor(Date.now() / 1000);

  if (!round.executed && now < round.deadline) {
    const signal = decideSignal();
    const labels = { 1: "HOLD", 2: "EXPAND", 3: "BUYBACK" };
    console.log(`Round ${roundId}: submitting ${labels[signal]}`);
    castSend("submitSignal(uint256,uint8,string)", roundId, signal, `"Auto signal: ${labels[signal]}"`);
  } else if (!round.executed && now >= round.deadline) {
    console.log(`Round ${roundId}: executing...`);
    castSend("executeRound(uint256)", roundId);
  } else if (round.executed) {
    console.log(`Round ${roundId}: done, decision=${round.decision}`);
    castSend("manualExecute(uint256)", roundId);
    castSend("distributeRewards(uint256)", roundId);
  }
}

console.log("HIVEMIND Agent started. Checking every 5 min...");
tick();
setInterval(tick, 5 * 60 * 1000);
