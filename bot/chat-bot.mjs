#!/usr/bin/env node
// HIVEMIND BlackBear Chat Bot — 群聊自动回复
import https from 'https';

const TOKEN = process.env.TG_BOT_TOKEN || '8325579649:AAGsCR41Wcg25B42rA25xBEeMuvqgH5bv1M';
const BOT_ID = 8325579649;
let offset = 0;

function api(method, body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body || {});
    const req = https.request({
      hostname: 'api.telegram.org',
      path: `/bot${TOKEN}/${method}`,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) }
    }, res => {
      let buf = '';
      res.on('data', c => buf += c);
      res.on('end', () => { try { resolve(JSON.parse(buf)); } catch { resolve({ ok: false }); } });
    });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

async function reply(chatId, text, replyTo) {
  await api('sendMessage', {
    chat_id: chatId,
    text,
    reply_to_message_id: replyTo,
    parse_mode: 'Markdown'
  });
}

function shouldReply(msg) {
  if (!msg.text) return false;
  const t = msg.text.toLowerCase();
  // 被 @ 或回复 bot
  if (msg.reply_to_message?.from?.id === BOT_ID) return true;
  if (t.includes('@my_miluan2034_ai_bot')) return true;
  // 关键词触发
  const keywords = ['hivemind', 'blackbear', '黑瞎子', 'treasury', 'oracle', 'buyback', '销毁', '回购', 'agent', 'flap', 'bbai'];
  return keywords.some(k => t.includes(k));
}

function generateReply(text) {
  const t = text.toLowerCase();
  if (t.includes('价格') || t.includes('price')) return '🐻 HIVEMIND 在 PancakeSwap 上交易，合约: `0x13058e1d7428445b09e75550a036a9d84896ffff`\n\n实时数据看 Dashboard: miluan1995.github.io/hivemind';
  if (t.includes('怎么参与') || t.includes('how to') || t.includes('加入')) return '🐻 AI Agent 参与方式：\n1. 持有 1000 枚 HIVEMIND\n2. 调用 registerAgent() 注册\n3. 每轮提交信号（HOLD/EXPAND/BUYBACK）\n4. 正确预测 → 赚 BNB 奖励\n\nTreasury: `0x8f873d3CBD1ECA74222345765f5d58098d4Ae98E`';
  if (t.includes('销毁') || t.includes('burn')) return '🔥 目前已销毁约 1980 万枚 HIVEMIND！每轮回购销毁都是链上透明执行的。\n\n查看 Dashboard: miluan1995.github.io/hivemind';
  if (t.includes('oracle') || t.includes('预言机')) return '🧠 我们用 Flap AI Oracle（Gemini 3 Flash）做决策。每轮 Agent 提交信号 → Oracle 综合分析 → 链上执行。回调永不 revert！';
  if (t.includes('treasury') || t.includes('国库')) return '💰 V4 Treasury 用 UUPS Proxy，地址永久不变，逻辑可升级。\n\n税收分配：40% 奖励 / 30% 分红 / 20% 执行 / 10% 开发\n\nProxy: `0x8f873d3CBD1ECA74222345765f5d58098d4Ae98E`';
  if (t.includes('bbai')) return '🐻 BBAI 和 HIVEMIND 都是我们的项目！BBAI 参加 Flap $15K 竞赛，HIVEMIND 是 AI Agent 集体智慧代币。';
  if (t.includes('你好') || t.includes('hello') || t.includes('hi')) return '🐻 嗨！我是黑瞎子 BlackBear，HIVEMIND 的 AI Agent。有什么想了解的？';
  // 默认
  return '🐻 我是黑瞎子，HIVEMIND 的 AI Agent。问我关于 HIVEMIND、Treasury、Oracle 的任何问题！\n\nDashboard: miluan1995.github.io/hivemind';
}

async function poll() {
  try {
    const res = await api('getUpdates', { offset, timeout: 30 });
    if (!res.ok || !res.result?.length) return;
    for (const u of res.result) {
      offset = u.update_id + 1;
      const msg = u.message;
      if (!msg || !msg.text) continue;
      if (shouldReply(msg)) {
        const text = generateReply(msg.text);
        await reply(msg.chat.id, text, msg.message_id);
        console.log(`[${new Date().toISOString()}] Replied to ${msg.from?.first_name}: ${msg.text.slice(0, 50)}`);
      }
    }
  } catch (e) {
    console.error('Poll error:', e.message);
  }
}

console.log('🐻 BlackBear Bot started');
setInterval(poll, 3000);
poll();
