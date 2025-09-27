// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LiquidLockGauge
 * @notice LP token kilitle, boost kazan, LLT ödüllerinden pay al.
 *
 * Tasarım notları:
 * - Tek havuz: LP token = sabit token (ör. Uniswap V2 LP).
 * - Kilit süresine göre boost multiplier.
 * - Ödüller "accRewardPerBoostedShare" muhasebesiyle dağıtılır.
 * - Owner: ödül fonlar, rewardRate ayarlar, boost tablolarını günceller.
 * - Üretim için ek güvenlikler, limitler, denetim önerilir.
 */
contract LiquidLockGauge is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Lock {
        uint256 amount;      // yatırılan LP miktarı
        uint64  unlockAt;    // bu lock için kilit bitiş tarihi
        uint16  tier;        // boost katmanı (0..N-1)
    }

    struct UserInfo {
        // Birden fazla lock pozisyonu tutulur (sade tutmak için dinamik dizi).
        Lock[]   locks;
        uint256  boostedBalance;     // toplam boost’lanmış bakiye
        uint256  rewardDebt;         // accRewardPerBoostedShare ile muhasebe
        uint256  pending;            // henüz çekilmemiş LLT ödülü
    }

    IERC20 public immutable lpToken;   // kilitlenecek LP
    IERC20 public immutable reward;    // LLT token

    // Boost katmanları
    // örn: [1.00x, 1.25x, 1.50x, 2.00x] scale=1e12
    uint256[] public boostMultipliers;   // 1e12 ölçeğinde
    uint256[] public lockDurations;      // saniye cinsinden, her tier'a karşılık

    // Ödül muhasebesi
    uint256 public accRewardPerBoostedShare; // 1e12 ölçeğinde
    uint256 public lastUpdate;
    uint256 public rewardRate;               // saniye başına LLT

    uint256 public totalBoosted;             // havuz toplam boosted LP

    mapping(address => UserInfo) public users;

    event Deposited(address indexed user, uint256 amount, uint16 tier, uint64 unlockAt);
    event Withdrawn(address indexed user, uint256 amount);
    event Harvested(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event Funded(uint256 amount, uint256 rewardRate, uint256 fundedForSeconds);
    event BoostTableUpdated();
    event RewardRateUpdated(uint256 newRate);

    constructor(IERC20 _lp, IERC20 _reward) {
        lpToken = _lp;
        reward = _reward;

        // Varsayılan boost tablosu
        // 0g = 1.00x, 30g = 1.25x, 90g = 1.50x, 180g = 2.00x
        boostMultipliers.push(1_000_000_000_000);  // 1e12
        boostMultipliers.push(1_250_000_000_000);  // 1.25e12
        boostMultipliers.push(1_500_000_000_000);  // 1.50e12
        boostMultipliers.push(2_000_000_000_000);  // 2.00e12

        lockDurations.push(0);             // 0 gün
        lockDurations.push(30 days);       // 30 gün
        lockDurations.push(90 days);       // 90 gün
        lockDurations.push(180 days);      // 180 gün

        lastUpdate = block.timestamp;
    }

    // ---------- Owner Fonksiyonları ----------

    function updateBoostTable(uint256[] calldata multipliers1e12, uint256[] calldata durations) external onlyOwner {
        require(multipliers1e12.length == durations.length && durations.length > 0, "bad input");
        _updatePool();

        delete boostMultipliers;
        delete lockDurations;
        for (uint256 i = 0; i < durations.length; i++) {
            require(multipliers1e12[i] >= 1_000_000_000_000, "min 1x");
            boostMultipliers.push(multipliers1e12[i]);
            lockDurations.push(durations[i]);
        }
        emit BoostTableUpdated();
    }

    /**
     * @notice Ödül fonla ve saniye başına dağıtım hızını ayarla.
     * rewardRate = amount / fundedForSeconds gibi set edersen lineer dağılır.
     */
    function fundRewards(uint256 amount, uint256 newRewardRate) external onlyOwner {
        _updatePool();
        reward.safeTransferFrom(msg.sender, address(this), amount);
        rewardRate = newRewardRate;
        emit Funded(amount, newRewardRate, amount / (newRewardRate == 0 ? 1 : newRewardRate));
    }

    function setRewardRate(uint256 newRate) external onlyOwner {
        _updatePool();
        rewardRate = newRate;
        emit RewardRateUpdated(newRate);
    }

    // ---------- Kullanıcı Fonksiyonları ----------

    /**
     * @notice LP yatır ve seçilen tier’a göre kilitle.
     * @param amount LP miktarı
     * @param tier 0..N-1 arası
     */
    function deposit(uint256 amount, uint16 tier) external nonReentrant {
        require(tier < boostMultipliers.length, "bad tier");
        require(amount > 0, "amount=0");
        _updatePool();
        UserInfo storage u = users[msg.sender];

        // Önce var olan ödülü güncelle
        if (u.boostedBalance > 0) {
            uint256 pending = (u.boostedBalance * accRewardPerBoostedShare / 1e12) - u.rewardDebt;
            if (pending > 0) {
                u.pending += pending;
            }
        }

        // Transfer LP
        lpToken.safeTransferFrom(msg.sender, address(this), amount);

        // Boost’u hesapla
        uint256 boosted = amount * boostMultipliers[tier] / 1e12;
        u.boostedBalance += boosted;
        totalBoosted += boosted;

        // Lock pozisyonu yarat
        uint64 unlockAt = uint64(block.timestamp + lockDurations[tier]);
        u.locks.push(Lock({
            amount: amount,
            unlockAt: unlockAt,
            tier: tier
        }));

        // Yeni rewardDebt
        u.rewardDebt = u.boostedBalance * accRewardPerBoostedShare / 1e12;

        emit Deposited(msg.sender, amount, tier, unlockAt);
    }

    /**
     * @notice Kilidi dolan pozisyonları çözüp LP çek. Hepsini/partially çekmek için index bazlı çalışırız.
     * @param lockIndex Kullanıcının locks dizisindeki index'i
     * @param amount Çözülecek miktar (pozisyon miktarından küçük/eşit olmalı)
     */
    function withdraw(uint256 lockIndex, uint256 amount) external nonReentrant {
        _updatePool();
        UserInfo storage u = users[msg.sender];
        require(lockIndex < u.locks.length, "bad index");
        Lock storage L = u.locks[lockIndex];

        require(amount > 0 && amount <= L.amount, "bad amount");
        require(block.timestamp >= L.unlockAt, "still locked");

        // Önce ödülleri güncelle
        if (u.boostedBalance > 0) {
            uint256 pending = (u.boostedBalance * accRewardPerBoostedShare / 1e12) - u.rewardDebt;
            if (pending > 0) u.pending += pending;
        }

        // Boost düşümü
        uint256 boostedDelta = amount * boostMultipliers[L.tier] / 1e12;
        u.boostedBalance -= boostedDelta;
        totalBoosted -= boostedDelta;

        // Pozisyon miktarını azalt
        L.amount -= amount;
        // Pozisyon sıfırlandıysa diziden çıkar (gaz için swap&pop)
        if (L.amount == 0) {
            uint256 last = u.locks.length - 1;
            if (lockIndex != last) {
                u.locks[lockIndex] = u.locks[last];
            }
            u.locks.pop();
        }

        // Yeni rewardDebt
        u.rewardDebt = u.boostedBalance * accRewardPerBoostedShare / 1e12;

        // LP transfer
        lpToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @notice Ödülleri çek (LLT).
     */
    function harvest() external nonReentrant {
        _updatePool();
        UserInfo storage u = users[msg.sender];
        uint256 pending = 0;
        if (u.boostedBalance > 0) {
            pending = (u.boostedBalance * accRewardPerBoostedShare / 1e12) - u.rewardDebt;
        }
        uint256 toPay = u.pending + pending;
        require(toPay > 0, "nothing");

        u.pending = 0;
        u.rewardDebt = u.boostedBalance * accRewardPerBoostedShare / 1e12;

        reward.safeTransfer(msg.sender, toPay);
        emit Harvested(msg.sender, toPay);
    }

    /**
     * @notice Acil çıkış: Kilide bakmadan LP geri verilir; tüm birikmiş ödüller sıfırlanır (yaklaşım).
     * Not: Üretimde cezalı çıkış düşünülür (fee vb).
     */
    function emergencyWithdraw() external nonReentrant {
        _updatePool();
        UserInfo storage u = users[msg.sender];

        uint256 totalLP;
        for (uint256 i = 0; i < u.locks.length; i++) {
            totalLP += u.locks[i].amount;
        }
        require(totalLP > 0, "no LP");

        // Boost’u tamamen düş
        totalBoosted -= u.boostedBalance;
        u.boostedBalance = 0;
        u.rewardDebt = 0;
        u.pending = 0;

        // pozisyonları sil
        delete u.locks;

        lpToken.safeTransfer(msg.sender, totalLP);
        emit EmergencyWithdraw(msg.sender, totalLP);
    }

    // ---------- İç Mantık ----------

    function _updatePool() internal {
        if (block.timestamp <= lastUpdate) return;
        if (totalBoosted == 0 || rewardRate == 0) {
            lastUpdate = block.timestamp;
            return;
        }
        uint256 dt = block.timestamp - lastUpdate;
        uint256 rewardAmt = dt * rewardRate;
        // havuzda yeterli LLT olduğunu varsayar; prod’da mevcut bakiyeyi kontrol edebilirsin
        accRewardPerBoostedShare += rewardAmt * 1e12 / totalBoosted;
        lastUpdate = block.timestamp;
    }

    // ---------- Görüntüleme Yardımcıları ----------

    function boostTable() external view returns (uint256[] memory multipliers1e12, uint256[] memory durations) {
        return (boostMultipliers, lockDurations);
    }

    function locksOf(address user) external view returns (Lock[] memory) {
        return users[user].locks;
    }

    function pendingRewards(address user) external view returns (uint256) {
        UserInfo storage u = users[user];
        uint256 pending = u.pending;
        if (u.boostedBalance > 0) {
            uint256 _acc = accRewardPerBoostedShare;
            if (block.timestamp > lastUpdate && totalBoosted > 0 && rewardRate > 0) {
                uint256 dt = block.timestamp - lastUpdate;
                uint256 rewardAmt = dt * rewardRate;
                _acc += rewardAmt * 1e12 / totalBoosted;
            }
            pending += (u.boostedBalance * _acc / 1e12) - u.rewardDebt;
        }
        return pending;
    }
}
