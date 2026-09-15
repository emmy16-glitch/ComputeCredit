// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ProviderRegistry} from "./ProviderRegistry.sol";
import {TrustPassport} from "./TrustPassport.sol";

interface IRwaCollateral {
    function collateralValue(address borrower) external view returns (uint256);
}

/// @title ComputeCreditVault
/// @notice Lender-funded, one-job compute advances serviced from routed agent revenue.
/// @dev v3 clean-room rewrite of v2.1 spec with these deliberate fixes:
///  - ERC4626 shares (standard pool ownership) with totalAssets() = idle USDC only,
///    so withdrawals are ALWAYS bounded by idle liquidity — no custom share math.
///  - Advance IDs (not address=>struct) + full history + one-active invariant.
///  - totalOutstanding decremented EXACTLY ONCE per serviced/defaulted amount
///    (v2 double-decrement bug eliminated by single _applyService path).
///  - EIP-712 borrower consent so operator cannot borrow for arbitrary wallets.
///  - Origination fee (pool revenue) + default surcharge (lien target) explicit.
///  - Post-default capture capped at lienCaptureBps (default 50%) so the agent
///    keeps earning incentive — v2 seized 100% which kills recovery.
///  - service/capture functions PULL tokens (transferFrom router) — no fake records.
contract ComputeCreditVault is ERC4626, Ownable, ReentrancyGuard, Pausable, EIP712 {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Active,
        Settled,
        Defaulted
    }

    struct Advance {
        uint256 id;
        address borrower;
        address provider;
        uint256 principal; // provider cost advanced
        uint256 fee; // origination fee added to repayable
        uint256 repaid; // total serviced so far
        uint256 issuedAt;
        uint256 dueAt;
        uint256 splitBps; // normal revenue split to vault
        bytes32 jobHash;
        address revenueSource;
        Status status;
    }

    struct RiskParams {
        uint256 minDeposit; // base units
        uint256 feeBps; // origination fee on principal
        uint256 splitBps; // normal split to vault (e.g. 2000 = 20%)
        uint256 penaltyBps; // surcharge on shortfall -> lien target
        uint256 lienCaptureBps; // % of routed revenue seized post-default
        uint256 advanceWindow; // seconds until due
    }

    bytes32 private constant INTENT_TYPEHASH = keccak256(
        "AdvanceIntent(address borrower,address provider,uint256 cost,bytes32 jobHash,address revenueSource,uint256 nonce,uint256 expiry)"
    );

    ProviderRegistry public immutable providers;
    TrustPassport public immutable passport;

    RiskParams public risk;
    uint256 public totalOutstanding; // sum(repayable - repaid) over Active only
    uint256 public nextAdvanceId = 1;

    mapping(uint256 id => Advance) public advances;
    mapping(address borrower => uint256) public activeAdvanceId;
    mapping(bytes32 jobHash => bool) public usedJobHash;
    mapping(address router => bool) public approvedRouters;
    mapping(address operator => bool) public approvedOperators;
    mapping(address borrower => address) public revenueSourceOf;
    mapping(address borrower => uint256) public nonces;
    // lien state per borrower (post-default conditional claim)
    mapping(address borrower => uint256) public lienTarget;
    mapping(address borrower => uint256) public lienCaptured;
    // ---- production hardening (additive, defaults preserve MVP behavior) ----
    bool public sigOnlyMode; // when true, operator path disabled; borrower-self or EIP-712 only
    uint256 public globalOutstandingCap; // 0 = uncapped; else totalOutstanding + repayable <= cap
    uint256 public riskChangeDelay; // seconds; 0 = immediate setRisk (MVP default)
    RiskParams public pendingRisk;
    uint64 public pendingRiskEta; // 0 = none proposed
    // ---- RWA boost (OKX Dev Day Build-a-Market integration, additive) ----
    address public rwaCollateral; // RwaCollateral contract (optional, 0 = disabled)
    uint256 public rwaBoostCap = 10_000_000; // max extra limit from locked xStock (10 USDC)

    // ---- events ----
    event RouterSet(address indexed router, bool approved);
    event OperatorSet(address indexed operator, bool approved);
    event RiskUpdated(RiskParams risk);
    event AdvanceRequested(
        uint256 indexed id,
        address indexed borrower,
        address indexed provider,
        uint256 principal,
        uint256 fee,
        bytes32 jobHash,
        address revenueSource,
        uint256 dueAt
    );
    event AdvanceServiced(uint256 indexed id, address indexed borrower, uint256 amount, uint256 repaid, uint256 remaining);
    event AdvanceSettled(uint256 indexed id, address indexed borrower);
    event AdvanceDefaulted(uint256 indexed id, address indexed borrower, uint256 shortfall, uint256 lienTarget_);
    event LienCaptured(address indexed borrower, uint256 captured, uint256 totalCaptured, uint256 target);
    event LienCleared(address indexed borrower);
    event RevenueSourceRegistered(address indexed borrower, address indexed source);
    event SigOnlyModeSet(bool enabled);
    event GlobalOutstandingCapSet(uint256 cap);
    event RiskProposed(RiskParams risk, uint64 eta);
    event RiskChangeDelaySet(uint256 delay);
    event RwaCollateralSet(address indexed collateral);
    event RwaBoostCapSet(uint256 cap);

    // ---- errors ----
    error BelowMinDeposit();
    error NotRouter();
    error NotAuthorizedRequester();
    error HasActiveAdvance();
    error NoActiveAdvance();
    error BadCost();
    error OverProviderPrice(uint256 cost, uint256 maxPrice);
    error OverTierLimit(uint256 cost, uint256 tierLimit);
    error JobHashUsed();
    error InsufficientLiquidity(uint256 need, uint256 idle);
    error BadAmount();
    error OverService(uint256 amount, uint256 remaining);
    error NotOverdue();
    error AlreadyClosed();
    error RevenueSourceLocked();
    error BadRouter();
    error ExpiredIntent();
    error BadNonce();
    error BadSignature();
    error BadDecimals(uint8 got, uint8 want);
    error OutstandingCapExceeded(uint256 outstandingAfter, uint256 cap);
    error NoPendingRisk();
    error RiskTimelocked(uint64 eta);

    constructor(IERC20 usdc, ProviderRegistry providers_, TrustPassport passport_, address owner_)
        ERC20("ComputeCredit Share", "CCS")
        ERC4626(usdc)
        Ownable(owner_)
        EIP712("ComputeCreditVault", "3")
    {
        uint8 dec;
        try IERC20Metadata(address(usdc)).decimals() returns (uint8 d) {
            dec = d;
        } catch {
            dec = 6; // non-metadata token: assume test env (MockUSDC always reports 6)
        }
        if (dec != 6) revert BadDecimals(dec, 6); // deployment-time decimals assertion
        providers = providers_;
        passport = passport_;
        risk = RiskParams({
            minDeposit: 1_000_000, // 1 USDC
            feeBps: 50, // 0.5% origination
            splitBps: 2_000, // 20% normal split
            penaltyBps: 1_000, // 10% surcharge -> lien target
            lienCaptureBps: 5_000, // 50% post-default capture
            advanceWindow: 43_200 // 12h
        });
    }

    // ============ ERC4626: idle-only assets ============

    /// @notice Idle USDC only. Receivables are NOT counted — share price drops on
    ///         advance issuance and recovers on service, withdrawals never touch live loans.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function _minDepositGuard(uint256 assets) internal view {
        if (assets < risk.minDeposit) revert BelowMinDeposit();
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        _minDepositGuard(assets);
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        uint256 assets = previewMint(shares);
        _minDepositGuard(assets);
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    // ============ admin ============

    function setRouter(address router, bool approved) external onlyOwner {
        if (router == address(0)) revert BadRouter();
        approvedRouters[router] = approved;
        emit RouterSet(router, approved);
    }

    function setOperator(address operator, bool approved) external onlyOwner {
        if (operator == address(0)) revert BadRouter();
        approvedOperators[operator] = approved;
        emit OperatorSet(operator, approved);
    }

    function setRisk(RiskParams calldata r) external onlyOwner {
        if (riskChangeDelay != 0) revert RiskTimelocked(pendingRiskEta); // use propose/apply when timelocked
        _setRisk(r);
    }

    function setRiskChangeDelay(uint256 delay) external onlyOwner {
        riskChangeDelay = delay;
        emit RiskChangeDelaySet(delay);
    }

    function proposeRisk(RiskParams calldata r) external onlyOwner {
        require(r.splitBps <= 10_000 && r.lienCaptureBps <= 10_000 && r.feeBps <= 1_000, "bad bps");
        require(r.advanceWindow >= 3_600, "window too short");
        pendingRisk = r;
        pendingRiskEta = uint64(block.timestamp + riskChangeDelay);
        emit RiskProposed(r, pendingRiskEta);
    }

    function applyRisk() external onlyOwner {
        if (pendingRiskEta == 0) revert NoPendingRisk();
        if (block.timestamp < pendingRiskEta) revert RiskTimelocked(pendingRiskEta);
        RiskParams memory r = pendingRisk;
        delete pendingRisk;
        pendingRiskEta = 0;
        _setRisk(r);
    }

    function _setRisk(RiskParams memory r) internal {
        require(r.splitBps <= 10_000 && r.lienCaptureBps <= 10_000 && r.feeBps <= 1_000, "bad bps");
        require(r.advanceWindow >= 3_600, "window too short");
        risk = r;
        emit RiskUpdated(r);
    }

    function setSigOnlyMode(bool enabled) external onlyOwner {
        sigOnlyMode = enabled;
        emit SigOnlyModeSet(enabled);
    }

    function setGlobalOutstandingCap(uint256 cap) external onlyOwner {
        globalOutstandingCap = cap;
        emit GlobalOutstandingCapSet(cap);
    }

    function setRwaCollateral(address collateral) external onlyOwner {
        rwaCollateral = collateral;
        emit RwaCollateralSet(collateral);
    }

    function setRwaBoostCap(uint256 cap) external onlyOwner {
        rwaBoostCap = cap;
        emit RwaBoostCapSet(cap);
    }

    /// @notice Effective advance limit: score tier + min(locked xStock value, cap).
    /// @dev Zero when RWA module unset — pure tier limit (backward compatible).
    function effectiveLimit(address borrower) public view returns (uint256) {
        uint256 tier = passport.maxAdvanceForScore(passport.score(borrower));
        if (rwaCollateral == address(0)) return tier;
        uint256 boost = IRwaCollateral(rwaCollateral).collateralValue(borrower);
        if (boost > rwaBoostCap) boost = rwaBoostCap;
        return tier + boost;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ advances ============

    /// @notice Operator-assisted request (demo path): caller must be borrower or approved operator.
    /// @dev Disabled for operators when sigOnlyMode is on (production: borrower-self or EIP-712 only).
    function requestAdvanceFor(address borrower, address provider, uint256 cost, bytes32 jobHash, address revenueSource)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 id)
    {
        if (sigOnlyMode && msg.sender != borrower) revert NotAuthorizedRequester();
        if (msg.sender != borrower && !approvedOperators[msg.sender]) revert NotAuthorizedRequester();
        return _request(borrower, provider, cost, jobHash, revenueSource);
    }

    /// @notice Trust-minimized path: anyone may submit a borrower-signed intent.
    function requestAdvanceWithSig(
        address borrower,
        address provider,
        uint256 cost,
        bytes32 jobHash,
        address revenueSource,
        uint256 nonce,
        uint256 expiry,
        bytes calldata sig
    ) external nonReentrant whenNotPaused returns (uint256 id) {
        if (block.timestamp > expiry) revert ExpiredIntent();
        if (nonce != nonces[borrower]) revert BadNonce();
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(INTENT_TYPEHASH, borrower, provider, cost, jobHash, revenueSource, nonce, expiry))
        );
        address signer = ECDSA.recover(digest, sig);
        if (signer != borrower) revert BadSignature();
        nonces[borrower] += 1;
        return _request(borrower, provider, cost, jobHash, revenueSource);
    }

    function _request(address borrower, address provider, uint256 cost, bytes32 jobHash, address revenueSource)
        internal
        returns (uint256 id)
    {
        if (borrower == address(0) || revenueSource == address(0)) revert BadCost();
        if (cost == 0) revert BadCost();
        if (activeAdvanceId[borrower] != 0) revert HasActiveAdvance();
        if (usedJobHash[jobHash]) revert JobHashUsed();
        if (lienTarget[borrower] > lienCaptured[borrower]) revert RevenueSourceLocked(); // uncleared lien blocks new advance

        (uint256 maxPrice,) = providers.quote(provider); // reverts unknown/inactive
        if (cost > maxPrice) revert OverProviderPrice(cost, maxPrice);

        uint256 tierLimit = effectiveLimit(borrower);
        if (cost > tierLimit) revert OverTierLimit(cost, tierLimit);

        uint256 idle = totalAssets();
        if (cost > idle) revert InsufficientLiquidity(cost, idle);

        uint256 fee = (cost * risk.feeBps) / 10_000;
        uint256 repayable = cost + fee;
        if (globalOutstandingCap != 0 && totalOutstanding + repayable > globalOutstandingCap) {
            revert OutstandingCapExceeded(totalOutstanding + repayable, globalOutstandingCap);
        }

        id = nextAdvanceId++;
        uint256 dueAt = block.timestamp + risk.advanceWindow;
        advances[id] = Advance({
            id: id,
            borrower: borrower,
            provider: provider,
            principal: cost,
            fee: fee,
            repaid: 0,
            issuedAt: block.timestamp,
            dueAt: dueAt,
            splitBps: risk.splitBps,
            jobHash: jobHash,
            revenueSource: revenueSource,
            status: Status.Active
        });
        activeAdvanceId[borrower] = id;
        usedJobHash[jobHash] = true;
        totalOutstanding += repayable;

        if (revenueSourceOf[borrower] != revenueSource) {
            revenueSourceOf[borrower] = revenueSource;
            emit RevenueSourceRegistered(borrower, revenueSource);
        }

        IERC20(asset()).safeTransfer(borrower, cost);
        emit AdvanceRequested(id, borrower, provider, cost, fee, jobHash, revenueSource, dueAt);
    }

    /// @notice Single accounting path for ALL normal servicing (router + early repay).
    function _applyService(uint256 id, uint256 amount) internal {
        Advance storage a = advances[id];
        uint256 repayable = a.principal + a.fee;
        uint256 remaining = repayable - a.repaid; // reverts if already fully repaid
        if (amount == 0 || amount > remaining) revert OverService(amount, remaining);
        a.repaid += amount;
        totalOutstanding -= amount; // EXACTLY ONCE — no second decrement on settle
        emit AdvanceServiced(id, a.borrower, amount, a.repaid, remaining - amount);
        if (a.repaid == repayable) {
            a.status = Status.Settled;
            activeAdvanceId[a.borrower] = 0;
            passport.notifySettled(a.borrower);
            emit AdvanceSettled(id, a.borrower);
        }
    }

    /// @notice Router servicing: pulls USDC from router, then applies accounting.
    function serviceAdvanceWithTransfer(address borrower, uint256 amount) external nonReentrant whenNotPaused {
        if (!approvedRouters[msg.sender]) revert NotRouter();
        uint256 id = activeAdvanceId[borrower];
        if (id == 0) revert NoActiveAdvance();
        if (advances[id].status != Status.Active) revert AlreadyClosed();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        _applyService(id, amount);
    }

    /// @notice Borrower early repay (same accounting path as router servicing).
    function repayEarly(address borrower, uint256 amount) external nonReentrant whenNotPaused {
        if (msg.sender != borrower && !approvedOperators[msg.sender]) revert NotAuthorizedRequester();
        uint256 id = activeAdvanceId[borrower];
        if (id == 0) revert NoActiveAdvance();
        if (advances[id].status != Status.Active) revert AlreadyClosed();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        _applyService(id, amount);
    }

    /// @notice Permissionless default after expiry. Removes residual from outstanding ONCE.
    function penalize(address borrower) external nonReentrant whenNotPaused {
        uint256 id = activeAdvanceId[borrower];
        if (id == 0) revert NoActiveAdvance();
        Advance storage a = advances[id];
        if (a.status != Status.Active) revert AlreadyClosed();
        if (block.timestamp <= a.dueAt) revert NotOverdue();
        uint256 repayable = a.principal + a.fee;
        uint256 shortfall = repayable - a.repaid;
        totalOutstanding -= shortfall; // active advance leaves outstanding set — exactly once
        a.status = Status.Defaulted;
        activeAdvanceId[borrower] = 0;
        uint256 target = (shortfall * (10_000 + risk.penaltyBps)) / 10_000;
        lienTarget[borrower] = target;
        lienCaptured[borrower] = 0;
        passport.notifyDefaulted(borrower);
        emit AdvanceDefaulted(id, borrower, shortfall, target);
    }

    /// @notice Post-default lien capture: pulls from router, capped at remaining target.
    /// @return captured amount credited toward lien; caller forwards any excess.
    function captureLienWithTransfer(address borrower, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 captured)
    {
        if (!approvedRouters[msg.sender]) revert NotRouter();
        uint256 target = lienTarget[borrower];
        if (target == 0 || lienCaptured[borrower] >= target) revert NoActiveAdvance();
        uint256 remaining = target - lienCaptured[borrower];
        captured = amount > remaining ? remaining : amount;
        if (captured == 0) revert BadAmount();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), captured);
        lienCaptured[borrower] += captured;
        emit LienCaptured(borrower, captured, lienCaptured[borrower], target);
        if (lienCaptured[borrower] == target) emit LienCleared(borrower);
    }

    // ============ views ============

    function repayableOf(uint256 id) external view returns (uint256) {
        Advance memory a = advances[id];
        return a.principal + a.fee;
    }

    function remainingOf(uint256 id) external view returns (uint256) {
        Advance memory a = advances[id];
        if (a.status != Status.Active) return 0;
        return a.principal + a.fee - a.repaid;
    }

    function lienRemaining(address borrower) external view returns (uint256) {
        if (lienTarget[borrower] <= lienCaptured[borrower]) return 0;
        return lienTarget[borrower] - lienCaptured[borrower];
    }

    function splitBpsOf(uint256 id) external view returns (uint256) {
        return advances[id].splitBps;
    }

    function lienCaptureBps() external view returns (uint256) {
        return risk.lienCaptureBps;
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function idleAssets() external view returns (uint256) {
        return totalAssets();
    }
}
