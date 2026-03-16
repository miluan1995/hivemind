#!/bin/bash
# 自动从旧 Treasury 转 BNB 到新 Treasury（全额）
OLD=0x6A55554c53b5d23931057f88EfCDE846Dc2968ac
NEW=0x8f873d3CBD1ECA74222345765f5d58098d4Ae98E
RPC=https://bsc-dataseed.binance.org
PK=$(grep '^PRIVATE_KEY=' /Users/mac/.openclaw/workspace/.env | cut -d= -f2)

BAL=$(ALL_PROXY= cast balance $OLD --rpc-url $RPC --ether 2>/dev/null)
if [ "$(echo "$BAL > 0.01" | bc -l 2>/dev/null)" = "1" ]; then
  ALL_PROXY= cast send $OLD "emergencyWithdraw()" --private-key $PK --rpc-url $RPC >/dev/null 2>&1
  sleep 3
  SEND=$(echo "$BAL - 0.005" | bc -l 2>/dev/null | head -c 10)
  if [ "$(echo "$SEND > 0" | bc -l 2>/dev/null)" = "1" ]; then
    ALL_PROXY= cast send $NEW --value "${SEND}ether" --private-key $PK --rpc-url $RPC >/dev/null 2>&1
    echo "Transferred ${SEND} BNB to Treasury"
  fi
else
  echo "Balance too low: ${BAL} BNB"
fi
