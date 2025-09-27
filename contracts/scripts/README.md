# LiquidLock DAO — Boost’lu LP Kilitleme ve Ödül

Kullanıcılar LP token’larını belirli sürelerle **kilitler**, süreye göre **boost** kazanır ve **LLT** ödül akışından daha fazla pay alır.

## Özellikler
- Çok seviyeli kilit süreleri: 0/30/90/180 gün
- Boost multipliers: 1.00x / 1.25x / 1.50x / 2.00x (varsayılan)
- LLT ödül dağıtımı: `rewardRate` saniye başına
- Herkes `harvest()` ile ödül toplayabilir, `withdraw()` kilit bitince LP çeker
- `emergencyWithdraw()` kilide bakmadan LP’yi verir; ödüllerden feragat eder

## Hızlı Başlangıç (yerel)
```bash
npm install
npm run build
npm run node
# yeni terminal
npm run deploy:local
