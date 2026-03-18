#!/bin/bash
# HIVEMIND 全自动轮次管理
T=0x8f873d3CBD1ECA74222345765f5d58098d4Ae98E
PK=$(grep '^PRIVATE_KEY=' /Users/mac/.openclaw/workspace/.env | cut -d= -f2)

# RPC fallback
for rpc in https://bsc-dataseed1.binance.org https://bsc-dataseed2.binance.org https://bsc-dataseed3.binance.org https://bsc-dataseed4.binance.org; do
  ROUND=$(ALL_PROXY= cast call $T "currentRoundId()(uint256)" --rpc-url $rpc 2>/dev/null | head -1 | tr -d ' ')
  [ -n "$ROUND" ] && R=$rpc && break
done
[ -z "$ROUND" ] && echo "RPC failed" && exit 1
NOW=$(date +%s)

if [ "$ROUND" = "0" ]; then
  ALL_PROXY= cast send $T "startNewRound()" --private-key $PK --rpc-url $R >/dev/null 2>&1
  ROUND=1
  echo "Started round 1"
fi

INFO=$(ALL_PROXY= cast call $T "rounds(uint256)(uint256,uint256,uint256,bool,uint256,uint8)" $ROUND --rpc-url $R 2>/dev/null)
DEADLINE=$(echo "$INFO" | sed -n '3p' | grep -o '[0-9]*' | head -1)
EXECUTED=$(echo "$INFO" | sed -n '4p' | tr -d ' ')
SIGNALS=$(echo "$INFO" | sed -n '5p' | grep -o '[0-9]*' | head -1)
SUBMITTED=$(ALL_PROXY= cast call $T "hasSubmittedSignal(uint256,address)(bool)" $ROUND 0xD82913909e136779E854302E783ecdb06bfc7Ee2 --rpc-url $R 2>/dev/null | tr -d ' ')

if [ "$EXECUTED" = "false" ] && [ -n "$DEADLINE" ] && [ "$NOW" -lt "$DEADLINE" ] && [ "$SUBMITTED" = "false" ]; then
  ALL_PROXY= cast send $T "submitSignal(uint256,uint8,string)" $ROUND 3 "Auto: BUYBACK" --private-key $PK --rpc-url $R >/dev/null 2>&1
  echo "Round $ROUND: submitted BUYBACK"

elif [ "$EXECUTED" = "false" ] && [ -n "$DEADLINE" ] && [ "$NOW" -ge "$DEADLINE" ]; then
  ALL_PROXY= cast send $T "executeRound(uint256)" $ROUND --private-key $PK --rpc-url $R >/dev/null 2>&1
  echo "Round $ROUND: executeRound sent"

elif [ "$EXECUTED" = "true" ]; then
  ALL_PROXY= cast send $T "manualExecute(uint256)" $ROUND --private-key $PK --rpc-url $R >/dev/null 2>&1
  ALL_PROXY= cast send $T "distributeRewards(uint256)" $ROUND --private-key $PK --rpc-url $R >/dev/null 2>&1
  ALL_PROXY= cast send $T "claimDevPool()" --private-key $PK --rpc-url $R >/dev/null 2>&1 || true
  ALL_PROXY= cast send $T "startNewRound()" --private-key $PK --rpc-url $R >/dev/null 2>&1
  echo "Round $ROUND: rewards claimed, round $((ROUND+1)) started"

else
  echo "Round $ROUND: waiting (executed=$EXECUTED signals=$SIGNALS)"
fi
