//+------------------------------------------------------------------+
//|                                            StraddleNetBank.mq5    |
//|   Hedging grid straddle with stepped trailing + net-bank cycle   |
//|                                                                  |
//|   REQUIRES: MT5 HEDGING account (buys and sells run together).   |
//|   Attach to the instrument you want (e.g. XAUUSD). All distances |
//|   below are in PRICE terms (for gold, 1.0 = $1).                 |
//|                                                                  |
//|   ---------------------------- HOW IT WORKS ------------------   |
//|   Launch @ center = current price. The first buy/sell stops sit  |
//|   CenterSideGap above/below center; later levels are GridGap     |
//|   apart. Orders split into 3 tiers (near/mid/far), each with its |
//|   own lot size.                                                  |
//|                                                                  |
//|   TIERS: near = orders 1..TierSize, mid = TierSize+1..2*TierSize, |
//|   far = 2*TierSize+1..OrdersPerSide. Defaults produce near 1-5,   |
//|   mid 6-10, and far 11-20.                                       |
//|                                                                  |
//|   TRAIL (BROKER SL; Arm=3, GapWide=3, TightenAt=4.5, Gap=1.5):     |
//|   each filled order arms when price is Arm beyond its fill; the    |
//|   real broker SL is kept at price -/+ GapWide until price is       |
//|   TightenAt beyond fill, then Gap, ratcheting only. Each position  |
//|   keeps its own broker SL, rate-capped to one modify per second.   |
//|   to stay clear of HFT. Sell side mirrors.                        |
//|                                                                  |
//|   REFILL: whenever a buy grid level above current price has no   |
//|   open position, its buy stop is (re)placed. As price falls back |
//|   through vacated levels they refill => exited orders revert.    |
//|                                                                  |
//|   NET-BANK CYCLE: cycle PnL = realized PnL of all exited orders  |
//|   this cycle (both sides, from deal history) + floating PnL of   |
//|   all open orders (both sides). When it reaches NetBankTarget,   |
//|   everything is closed, banked, and a fresh straddle opens.      |
//|   A symmetric CYCLE LOSS LIMIT closes + restarts on the downside.|
//|   Optional trailing OFF: profit target/lock use floating only;   |
//|   safety limits and accounting still retain actual cycle NET.   |
//|                                                                  |
//|   RISK: this is an averaging/re-entering grid. In a strong trend |
//|   against you, floating loss can grow large. TEST ON DEMO FIRST. |
//+------------------------------------------------------------------+
#property copyright "custom"
#property version   "1.60"
#property strict
 
#include <Trade/Trade.mqh>
CTrade trade;

enum ENUM_REVERSAL_LEVEL_MODE
{
   REVERSAL_LEVELS_ALTERNATE = 0, // Odd levels: B1/B3/B5 or S1/S3/S5
   REVERSAL_LEVELS_ALL       = 1  // Every level on the opposite side
};

enum ENUM_REVERSAL_TRIGGER_MODE
{
   REVERSAL_TRIGGER_FILLS = 0,        // Original: opposite-side multiplier on center reversals
   REVERSAL_TRIGGER_FLOATING_LOSS = 1 // All BUY/SELL stops once per cycle after floating loss
};

enum ENUM_DASHBOARD_DESIGN
{
   DASHBOARD_OLD = 0, // Old design: compact text panel
   DASHBOARD_NEW = 1  // New design: responsive trading dashboard
};
 
input group "=== GRID / SPACING ==="
input double  InpCenterSideGap    = 1.5;    // Distance from center to first BUY/SELL on each side
input double  InpGridGap          = 1.5;    // Gap between consecutive orders on the same side
input int     InpOrdersPerSide    = 40;     // Orders per side (near + mid + far)
input int     InpTierSize         = 10;      // Tier size: near 1..N, mid N+1..2N, far 2N+1..end

input group "=== LOT SIZE (per tier) ==="
input double  InpLotNear          = 0.01;   // Near tier lot   (orders 1 .. TierSize)
input double  InpLotMid           = 0.03;   // Mid  tier lot   (orders TierSize+1 .. 2*TierSize)
input double  InpLotFar           = 0.09;   // Far  tier lot   (orders 2*TierSize+1 .. end)

input group "=== GRID LOT PROGRESSION (both sides) ==="
input bool    InpUseGridLotProgression = false; // false=original tier lots and original orders per side
input double  InpGridInitialLot       = 0.01;  // Base lot for B1 and S1
input double  InpGridLotMultiplier    = 1.20;  // Each next level: initial lot x multiplier^(level-1)
input int     InpProgressionOrdersPerSide = 15; // BUY STOP levels and SELL STOP levels, per side

input group "=== TRAILING STOP (broker-side, rate-capped) ==="
input bool    InpUseTrailingStop  = true;   // true=original trailing + NET targets; false=no trailing, floating-only profit target/lock
input double  InpArmDistance      = 5.0;    // Arm point: start trailing when price is this far beyond fill ($)
input double  InpTrailGapWide     = 5.0;    // Wide gap: SL distance behind price after arming ($)
input double  InpTrailTightenAt   = 8.0;    // Tighten point: switch to tight gap at this distance beyond fill ($)
input double  InpTrailGap         = 3.0;    // Tight gap: SL distance behind price after tightening ($)
input double  InpDisasterSL       = 50.0;   // Wide hard broker SL at entry (0 = off; disconnect safety)

input group "=== ORDER PLACEMENT ==="
input double  InpRefillBuffer     = 0.50;   // Min distance from price to (re)place a level (price units)
input int     InpMaxPlacePerTick  = 3;      // Max new orders placed per tick (refills; anti-burst)
input int     InpInitialPlacePerTick = 12;  // Startup grid batch size (0 = use the refill limit)
input bool    InpInstantGrid      = false;  // Initial formation: true=place whole grid at once, false=throttled
input double  InpMaxSlippage      = 1.0;    // Max slippage in PRICE ($): stops slipping more are capped/repositioned
input bool    InpAsyncClose       = true;   // Fire all exits together (async)
input bool    InpAsyncPlacement   = false;  // Initial grid requests async (false is safer and confirms each request)
input int     InpCloseRetryMs     = 2000;   // Re-send a close if not gone after this (ms)
input int     InpEntryBackoffSec  = 2;      // Pause new entry requests after a broker rejection

input group "=== CYCLE EXIT: PROFIT / LOSS ==="
input double  InpNetBankTarget    = 20.0;   // Full cycle profit target (account ccy)
input bool    InpUseCycleLoss     = true;    // Enable the hard cycle loss cutout
input double  InpCycleLossLimit   = 300.0;   // Hard loss cutout: close + restart at this net loss ($)
input bool    InpUseFloatingLoss  = false;   // Enable a separate open-position floating-loss cutout
input double  InpFloatingLossLimit = 300.0;  // Close the full cycle at this floating loss ($, positive)
input double  InpCycleCooldownMin = 5.0;     // Extra wait (MINUTES) after a cycle banks (0 = off)
input double  InpLossCooldownMin  = 60.0;    // Minimum cooldown after a loss exit (MINUTES)
input int     InpReformDelaySec   = 1;      // Settle pause (SECONDS) after flat before locking center + reforming

input group "=== CYCLE BANK PROFIT LOCK ==="
input bool    InpUseBankProfitLock   = false; // At the normal target, trail cycle NET instead of closing immediately
input double  InpBankLockArmProfit   = 20.0;  // Minimum cycle NET required to arm, even if the adaptive target is lower ($)
input double  InpBankLockMinProfit   = 5.0;   // Minimum protected NET if the active target is lower ($)
input double  InpBankLockGiveback    = 10.0;  // Trail the protected floor this far behind new peak NET ($)
input bool    InpBankLockFreezeAdds  = true;  // On arming, cancel pending orders and block grid/recovery additions
input bool    InpBankLockCloseOpposite = false; // When FreezeAdds cancels both pending grids at lock activation, also close opposite open positions

input group "=== MANUAL TRADE INTEGRATION ==="
input bool    InpIncludeManualTradesInCycle = true; // Include new same-symbol manual trades/pending orders in the active cycle's accounting
input bool    InpManageManualTrades = true; // Also manage adopted trades with trailing, cycle exits and pending cancellation (requires Include)

input group "=== TREND-ADAPTIVE EXIT (1-min) ==="
input bool    InpUseTrend         = true;   // Enable trend-adaptive exit target
input int     InpTrendCandles     = 7;      // Trend look-back window (1-min candles)
input double  InpTrendPoints      = 10.0;   // Min net close-to-close move to call a trend (price units)
input double  InpTrendQuickProfit = 5.0;    // Quick target: price opposite an untouched trend side ($)
input double  InpNoTrendTarget    = 5.0;    // Target when NO trend is detected ($)
input double  InpBreakevenTarget  = 0.0;    // "Breakeven" target ($; set 1-2 to cover costs)
input bool    InpUseLastSide      = true;   // Same side as last cycle's exit -> quick +profit
input bool    InpUseAgainstTrend  = true;   // If a cycle exits AGAINST the trend -> next cycle target is quick +profit
input double  InpAgainstTrendTgt  = 5.0;    // Target for the cycle after an against-trend exit ($)

input group "=== HIGH-IMPACT NEWS FILTER ==="
input bool    InpUseNewsFilter       = false; // Block new cycles around high-impact calendar events
input string  InpNewsCurrency        = "USD"; // Calendar currency (USD is appropriate for XAUUSD)
input int     InpNewsMinutesBefore   = 30;    // Lock this many minutes before the event
input int     InpNewsMinutesAfter    = 45;    // Keep locked this many minutes after the event
input bool    InpNewsCloseOpenCycle  = false; // true=flatten now; false=allow the running cycle to continue
input bool    InpNewsCancelPending   = false; // true=cancel/freeze adds; false=let the running cycle operate normally
input string  InpNewsTesterFile      = "";    // Common Files CSV: server time,currency,event (chronological)

input group "=== DEPTH-TRIGGERED DOUBLING ==="
input bool    InpUseDepthDouble   = false;  // Enable depth-triggered lot doubling (off by default for safety)
input int     InpDblTriggerIdx    = 15;     // Fill depth (either side) that arms doubling
input bool    InpDblRequireCenter = true;   // true=arm after a center return; false=arm immediately at trigger depth
input double  InpDblMultiplier    = 2.0;    // Multiplier for all pending/future grid stops after arming

input group "=== CENTER-REVERSAL GRID MULTIPLIER ==="
input bool    InpUseCenterReversalMultiplier = false; // Enable this group and suspend depth-triggered doubling
input ENUM_REVERSAL_TRIGGER_MODE InpReversalTriggerMode = REVERSAL_TRIGGER_FLOATING_LOSS; // Floating loss (both sides once) or original center reversals
input double  InpReversalFloatingLoss = 100.0; // Floating mode: this EA/symbol open loss to arm (positive, account currency)
input bool    InpReversalRequireCenter = true; // Floating mode: wait for center return; false=apply immediately
input int     InpReversalTriggerOrders = 2; // Original fills mode only: distinct filled levels to arm
input ENUM_REVERSAL_LEVEL_MODE InpReversalLevels = REVERSAL_LEVELS_ALTERNATE; // Original fills mode only: odd or all opposite levels
input double  InpReversalMultiplier = 2.0;  // Base grid lot multiplier (floating mode: both sides, once)
input bool    InpReversalCompound   = true; // Original fills mode only: compound across switches
input int     InpReversalMaxSwitches = 6;   // Original fills mode only: maximum switches per cycle (1..30)
input double  InpReversalMaxLot     = 0.10; // Cap this feature's per-order lot; never reduce the base tier lot (0 = off)

input group "=== ALTERNATE-EXIT (stretch & return) ==="
input bool    InpUseAltExit       = false;   // Enable alternate-close on stretch-and-return
input int     InpAltDepthTrigger  = 11;     // Fill depth that arms it (11 = reached 2nd tier)

input group "=== DEPTH-DRAWDOWN EXIT (two-sided) ==="
input bool    InpUseDepthDD       = false;   // Enable the two-stage depth drawdown exit
input int     InpDDTrig1          = 7;      // Stage 1: one side reaches this depth (no exit)
input int     InpDDTrig2          = 10;    // Stage 2: OPPOSITE side reaches this depth -> mark NET
input double  InpDDFraction       = 0.5;   // Exit when NET recovers to this fraction of the marked NET
input double  InpDDMinLoss         = 50.0;  // Only mark at center if the loss is at least this ($; avoids instant exit)

input group "=== DAILY TARGET ==="
input bool    InpUseDailyTarget   = false;  // After a cycle closes, stop new cycles at the daily target
input double  InpDailyTarget      = 100.0;  // Daily realized profit target (account ccy)

input group "=== MONTHLY CAPITAL MULTIPLE TARGET ==="
input bool    InpUseMonthlyCapitalTarget = false; // Finish the active cycle normally, then halt for the month
input double  InpMonthlyCapital          = 3000.0; // Capital used as the monthly calculation base
input double  InpMonthlyCapitalMultiple  = 2.0;    // Target virtual capital (3000 x 2 = 6000; requires +3000 month NET)

input group "=== FRIDAY STOP ==="
input bool    InpUseFridayStop    = true;   // After cutoff, finish the current cycle and block the next cycle
input int     InpFridayCutHour    = 5;      // Friday SERVER hour when new cycles become blocked
input int     InpMondayStartDelayMin = 10;  // After Monday symbol-session open: delay NEW cycles this many minutes (0 = off)
input double  InpFridayMinLoss    = 0.0;    // Optional small-loss wind-down threshold ($; 0 = off)
input double  InpFridayWeeklyFrac = 0.0;    // Optional loss fraction of weekly profit (0 = off; 0.5 = 50%)

input group "=== SESSION FILTER (broker session times) ==="
input bool    InpUseSessionFilter = true;   // Restrict NEW cycles to the session window
input int     InpStartDelayMin    = 2;      // Start this many MINUTES after session open
input double  InpEndBufferHours   = 5.0;    // Stop this many HOURS before session close
input bool    InpCloseAtCutoff    = false;  // Also close a running cycle at the cutoff

input group "=== MISC ==="
input long    InpMagic            = 990011; // Magic number
input int     InpDeviation        = 30;     // Max slippage (points)

input group "=== SAFETY / RECOVERY ==="
input bool    InpPersistState       = true;  // Persist cycle state and reconcile it after terminal/EA restart
input double  InpMaxCycleRiskPct    = 8.0;   // Equity-based cycle loss cap (% of cycle-start equity; 0 = off)
input double  InpMaxDailyLossPct    = 8.0;   // Daily realized+floating loss cap (% of day-start balance; 0 = off)
input double  InpMaxExposureLots    = 0.75;  // Maximum open + pending volume for this EA/symbol (0 = off)
input double  InpMinMarginLevelPct  = 300.0; // Block new exposure below projected margin level (0 = off)
input double  InpExitCostPerLot      = 0.0;   // Estimated one-way closing costs per open lot (account ccy)
input int     InpMaxConsecutiveLosses = 2;    // Halt new cycles for the day after this many losses (0 = off)

input group "=== DASHBOARD ==="
input bool    InpShowPanel        = true;   // Show the on-chart dashboard
input ENUM_DASHBOARD_DESIGN InpDashboardDesign = DASHBOARD_NEW; // Dashboard design: Old / New
input int     InpDashboardWidth   = 1180;   // New design maximum width (96-DPI pixels; 0 = fit chart)
input int     InpPanelX           = 12;     // Panel X (px from left)
input int     InpPanelY           = 24;     // Panel Y (px from top)
input int     InpMaxRows          = 12;     // Max exited orders to list
input bool    InpEnableJournalLogs = false;  // Enable EA and CTrade messages in the Journal

input group "=== MOBILE PUSH NOTIFICATIONS ==="
input bool    InpUsePushNotifications = false; // Master switch for periodic and cycle-completion mobile notifications
input int     InpPushIntervalMin     = 15;    // Minutes between summaries (minimum 1; first message after this interval)
input bool    InpPushNetBank         = true;  // Include cycle NET: realized bank + floating P/L
input bool    InpPushRealizedBank    = true;  // Include this cycle's realized bank
input bool    InpPushDailyProfit     = true;  // Include today's booked P/L for this EA/symbol (server day)
input bool    InpPushCycleExit       = false; // Send a separate final NET result after each complete cycle exit

input group "=== HTTP DASHBOARD PUSH ==="
input string  InpApiUrl              = "http://localhost:8000/api/push"; // Dashboard API URL (add to WebRequest whitelist in Tools > Options)
input string  InpApiKey              = "";     // API Key for authentication (generate with add-account.js)
input int     InpPushSeconds         = 5;      // Push interval in seconds (minimum 1)
input long    InpMagicFilter         = 0;      // Magic number filter (0 = all positions, >0 = filter by magic)

//--- state
double   gCenter     = 0.0;
datetime gCycleStart = 0;
long     gCycleStartMsc = 0;
long     gCycleExcludedPositions[];
ulong    gCycleExcludedDeals[];
long     gResetPositionIds[];     // observed cycle positions; retained through reset to exclude late closing deals
ulong    gCycleAccountingRevision = 1;
bool     gCycleIdentityDirty = true;
struct ManualCycleTrade
{
   long id;                      // original order / stable position identifier
   long cycle;                   // millisecond cycle boundary; retained for later day/month reporting
};
ManualCycleTrade gManualTrades[];
struct TradeOrigin
{
   long id, magic, reason, setupMsc;
   string symbol;
};
TradeOrigin gTradeOrigins[];      // origin lookups do not change the selected deal-history list
bool     gManualIdentityDirty = true;
bool     gManualRefreshDirty = true;
bool     gManualDiscoveryPending = false;
datetime gCycleBoundaryRetryAfter = 0;
bool     gInit       = false;
datetime gDayStart    = 0;
bool     gHaltedToday = false;
double   gDailyPnL    = 0.0;
datetime gMonthStart   = 0;
bool     gHaltedMonth  = false;
double   gMonthlyPnL   = 0.0;
bool     gAwaitFlat   = false;    // cycle reset in progress: waiting for flat
bool     gCycleOpen   = false;    // a straddle is currently placed/running
bool     gDashboardResetPending = false;
datetime gDashboardResetSettleUntil = 0;
datetime gDashboardResetRetryAfter = 0;
datetime gCooldownUntil = 0;      // no new cycle may open until this time
string   gSessTxt     = "";       // session window text for the dashboard
ulong    gClosingTk[];            // tickets with a close already sent
uint     gClosingMs[];            // when that close was sent (ms)
ulong    gDelTk[];                // pending-order tickets with a delete already sent
uint     gDelMs[];                // when that delete was sent (ms)
int      gTrendDir     = 0;       // 1-min trend: 0 none, +1 up, -1 down
datetime gTrendLastBar = 0;       // last M1 bar time the trend was evaluated
bool     gAltBuyDone   = false;   // buy-side alternate-exit already fired this cycle
bool     gAltSellDone  = false;   // sell-side alternate-exit already fired this cycle
int      gBuyDepth  = 0;          // deepest BUY level filled this cycle (high-water)
int      gSellDepth = 0;          // deepest SELL level filled this cycle (high-water)
bool     gDblArmed  = false;      // depth-double armed using the selected trigger/center mode
bool     gReversalLossArmed = false;
bool     gReversalLossApplied = false;
int      gReversalLossSide = 0;   // side of center when the floating-loss threshold was reached
bool     gReversalArmed = false;
int      gReversalOriginSide = 0; // filled side waiting for a center return
int      gReversalTargetSide = 0; // only a new fill on this side can qualify the next switch
int      gReversalSwitches = 0;
double   gReversalFactor = 1.0;
double   gReversalBuyFactor = 1.0;
double   gReversalSellFactor = 1.0;
long     gReversalLastSwitchMsc = 0;
long     gReversalLastFillMsc = 0;
bool     gReversalFilledBuy[];
bool     gReversalFilledSell[];
int      gReversalBuyFillCount = 0;
int      gReversalSellFillCount = 0;
bool     gInstantForm = false;    // (kept for compatibility; formation now via FormGridNow)
void FormGridNow();               // forward decl: immediate full-grid placement at lock
double   gLastMid   = 0.0;        // most recent mid price (for recording exit side)
double   gCycleRealized = 0.0;    // running realized PnL this cycle (event-driven; see OnTradeTransaction)
enum ENUM_BANK_SCOPE { BANK_CYCLE, BANK_DAY, BANK_MONTH };
struct BankDealRecord
{
   ulong ticket;
   datetime time;
   datetime cycleStart, dayStart, monthStart;
   double cycleNet, dayNet, monthNet;
};
struct BankReconcileDeal
{
   ulong ticket;
   datetime time;
   double net;
   bool cycle;
};
BankDealRecord gBankDeals[];       // sorted by ticket; each bank records its own applied value
bool     gBankHistoryDirty = false;
bool     gBankScanFailed = false;
datetime gBankRetryAfter = 0;
bool     gFlatSettling = false;   // reached flat, bank zeroed, waiting out the reform delay
bool     gFlatCyclePending = false;
datetime gFlatCycleRetryAfter = 0;
datetime gSettleUntil  = 0;       // when the reform delay ends (lock center + form after this)
int      gLastExitSide = 0;       // side the PREVIOUS cycle exited on: +1 buy(above), -1 sell(below), 0 none
bool     gNextCycleQuick = false; // previous cycle exited AGAINST the trend -> this cycle uses quick target
bool     gDDArmed   = false;      // two-stage depth-drawdown: NET marked at center
bool     gDDEligible = false;     // both trigger depths reached -> mark on next center touch
double   gDDMarkNet = 0.0;        // NET snapshot taken at center
double   gCycleStartEquity = 0.0; // equity snapshot used by the percentage cycle-risk guard
double   gDayStartBalance  = 0.0; // balance snapshot used by the daily-loss guard
bool     gBankLockArmed    = false;
double   gBankLockPeak     = 0.0;
double   gBankLockFloor    = 0.0;
int      gBankLockRetainSide = 0; // +1 keep BUY, -1 keep SELL, 0 neutral at arming; never flips within the cycle
bool     gLossExitPending  = false;
int      gConsecutiveLosses = 0;
bool     gRecoveryBlocked  = false;
bool     gRetiredCycleSnapshot = false;
string   gRecoveryMessage  = "";
bool     gRecoveryCommentShown = false;
datetime gLastStateSave    = 0;
datetime gEntryBackoffUntil = 0;
bool     gIsTester          = false;
bool     gIsVisualTester    = false;
bool     gGridDirty          = true;
bool     gInitialGridForming = false;
bool     gGridInitialBuySeen[];
bool     gGridInitialSellSeen[];
bool     gGridPosBuy[];
bool     gGridPosSell[];
bool     gGridPendBuy[];
bool     gGridPendSell[];
ulong    gGridPendBuyTk[];
ulong    gGridPendSellTk[];
double   gGridPendBuyVol[];
double   gGridPendSellVol[];
double   gGridPendBuyPrice[];
double   gGridPendSellPrice[];
double   gGridOpenVolume = 0.0;
bool     gExposureBatchActive = false;
double   gExposureBatchLots = 0.0;
double   gExposureBatchPendingMargin = 0.0;
double   gExposureBatchEquity = 0.0;
double   gExposureBatchLastExtra = 0.0;
double   gWeeklyCacheValue = 0.0;
datetime gWeeklyCacheWeek = 0;
datetime gWeeklyCacheCycle = 0;
bool     gNewsLock = false;
datetime gNewsLockUntil = 0;
datetime gNewsLastRefresh = 0;
datetime gNewsLastErrorLog = 0;
string   gNewsEventName = "";
datetime gNewsTimes[];
string   gNewsNames[];
int      gNewsNextIndex = 0;
bool     gNewsFileReady = false;
double   gSymbolTickSize = 0.0;
double   gSymbolVolumeMin = 0.0;
double   gSymbolVolumeMax = 0.0;
double   gSymbolVolumeStep = 0.0;

double   gGridLevelBuyPrice[];
double   gGridLevelSellPrice[];
double   gGridPriceCacheCenter = 0.0;
double   gGridPriceCacheCenterGap = 0.0;
double   gGridPriceCacheGap = 0.0;
double   gGridCachedExposureLots = 0.0;
bool     gGridWatchValid = false;
double   gGridWatchBuyRemoveAsk = 1.0e100;
double   gGridWatchSellRemoveBid = -1.0e100;
double   gGridWatchBuyActionAsk = -1.0e100;
double   gGridWatchSellActionBid = 1.0e100;

bool     gPositionSnapshotValid = false;
ulong    gPositionSnapshotRevision = 0;
int      gPositionSnapshotAccountCount = -1;
int      gPositionSnapshotCount = 0;
double   gPositionSnapshotFloating = 0.0;
double   gPositionSnapshotBuy = 0.0;
double   gPositionSnapshotSell = 0.0;
int      gPositionSnapshotManualBuyCount = 0;
int      gPositionSnapshotManualSellCount = 0;
double   gPositionSnapshotVolume = 0.0;
uint     gResetRetryMs = 0;
uint     gResetStuckMs = 0;
bool     gResetRetryStarted = false;

struct DashboardPosition
{
   long id;
   double net;
   int side;
   long closeMsc;
   bool exited;
};
DashboardPosition gDashboardPositions[];
int      gDashboardRows[];
bool     gDashboardHistoryDirty = true;
bool     gDashboardHistoryReady = false;
ulong    gDashboardRevision = 0;
double   gDashboardSum = 0.0;
double   gDashboardBuy = 0.0;
double   gDashboardSell = 0.0;
int      gDashboardExited = 0;

struct UILabelCache
{
   string key, text;
   int x, y, size, width, height;
   color clr;
   bool created;
   string font, tip, raw;
   int kind, fitWidth;
   color fill;
   bool touched;
};
UILabelCache gUILabelCache[];
bool     gUIChanged = false;
datetime gDashboardLastDraw = 0;
ulong    gDashboardLastDrawRevision = 0;
string   gAttachedSymbol = "";
long     gAttachedLogin = 0;
bool     gChartResumePending = false;
string   gStateCacheFields[];
double   gStateCacheValues[];
bool     gStateForceWrite = false;
datetime gLastStateFullSave = 0;
bool     gPushScheduleStarted = false;
ulong    gPushNextAttemptMs = 0;
ulong    gPushSendAfterMs = 0;
datetime gPushExitCycleStart = 0;
long     gPushExitCycleStartMsc = 0;
string   gPushExitMessages[];
long     gPushExitIds[];
datetime gHttpPushLastSend = 0;
bool     gHttpPushTimerSet = false;

struct DashboardTradeDetail
{
   double closedVolume, priceVolume;
};
DashboardTradeDetail gDashboardDetails[];
bool     gDashboardDetailsReady = false;
bool     gDashboardPaintPending = true;
bool     gDashboardCollapsed = false;
int      gDashboardView = 0;
int      gDashboardPage = 0;
int      gDashboardChartWidth = 0;
int      gDashboardChartHeight = 0;
double   gDashboardScale = 1.0;
double   gDashboardQuoteBid = 0.0;
double   gDashboardQuoteAsk = 0.0;
ulong    gDashboardPageRevision = 0;

//--- forward declarations for restart persistence and safety helpers
bool ValidateConfiguration();
bool LoadPersistentState();
void SavePersistentState(bool flush=false);
void LoadMonthlyHaltState();
void SaveMonthlyHaltState();
void RebuildRuntimeTracking();
double CycleRealizedScan();
double DailyRealized();
datetime CurrentMonthStart();
double MonthlyRealized();
double MonthlyProfitTarget();
double WeeklyRealized();
double CostAdjustedTarget(double baseTarget);
void UpdateFillDepths();
void UpdateFillDepthFromDeal(ulong dealTk);
int CountMyPositions();
int CountMyPendings();
bool LoadTesterNewsFile();
void UpdateNewsGuard();
bool EntryRiskLocked();
bool ActiveCycleRiskLocked();
bool EnforceEntryRiskLock(double cycleNet, bool cycleActive);
void LogEntryGuard(string reason);
bool ManageBankProfitLock(double cycleNet, bool cycleActive, int openPositions, double mid);
double CycleProfitValue(double cycleNet, double floating);
void ResetInitialGridFormation();
void ResetCenterReversalMultiplier();
void RecordCenterReversalFill(bool isBuy, int idx, long fillTimeMsc);
void RebuildCenterReversalOrigin();
void UpdateCenterReversalMultiplier(double bid, double ask);
int GridOrdersPerSide();
double TierLot(int idx);
void RefreshBankAccounting();
bool IsCurrentCycleDeal(ulong ticket);
bool BeginCycleAccounting();
void ResetCycleAccounting();
void CaptureResetPositions();
void RememberCyclePosition(long id);
bool ReconcileExternallyFlatCycle(int openPositions);
void DrawDashboard(double bid, double ask);
void InvalidatePositionSnapshot();
void RefreshPositionSnapshot();
uint RequestClockMs();
void ResetDashboardDisplay();
bool CanResumeChartCycle();
int FinishChartInitialization();
void CapturePushCycleExit();
void QueuePushCycleExit();
void RefreshManualTradeIntegration();
string DashboardResetBlockReason();
bool RequestDashboardCycleReset();
void ManageDashboardCycleReset(double bid,double ask);
void ClearCycleRuntimeCaches();
bool ReadFlatCycleHistory(datetime start,long startMsc,double &profit,bool verifyUnmanaged);
bool IsAccountingDeal(ulong ticket);
bool IsCyclePositionSelected();
bool IsManagedPositionSelected();
bool IsCycleOrderSelected();
bool IsManagedOrderSelected();
 
//+------------------------------------------------------------------+
int OnInit()
{
   bool resumeChartCycle = CanResumeChartCycle();
   if(!resumeChartCycle)
   {
      ArrayResize(gManualTrades,0);
      ArrayResize(gTradeOrigins,0);
      gManualIdentityDirty=true;
      gManualRefreshDirty=true;
      gPushScheduleStarted = false;
      gPushNextAttemptMs = 0;
      gPushSendAfterMs = 0;
      gPushExitCycleStart = 0;
      gPushExitCycleStartMsc = 0;
      ArrayResize(gPushExitMessages, 0);
      ArrayResize(gPushExitIds, 0);
   }
   gChartResumePending = false;
   ResetDashboardDisplay();
   gIsTester       = (MQLInfoInteger(MQL_TESTER) != 0);
   gIsVisualTester = (MQLInfoInteger(MQL_VISUAL_MODE) != 0);
   gSymbolTickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(gSymbolTickSize <= 0.0) gSymbolTickSize = _Point;
   gSymbolVolumeMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   gSymbolVolumeMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   gSymbolVolumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(gSymbolVolumeStep <= 0.0) gSymbolVolumeStep = 0.01;
   trade.LogLevel(InpEnableJournalLogs ? LOG_LEVEL_ALL : LOG_LEVEL_NO);
   if(!ValidateConfiguration()) return(INIT_PARAMETERS_INCORRECT);
   if(gIsTester && InpUseNewsFilter && !LoadTesterNewsFile())
   {
      if(InpEnableJournalLogs) Print("Initialization refused: the tester news filter is enabled but no valid event CSV was loaded.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(!InpUseCycleLoss && InpMaxCycleRiskPct <= 0.0 && !InpUseFloatingLoss)
   {
      if(InpEnableJournalLogs) Print("RISK WARNING: both cycle-loss protections are disabled; cycle loss is uncapped.");
   }
   else if(!InpUseCycleLoss && InpMaxCycleRiskPct <= 0.0 && InpUseFloatingLoss)
   {
      if(InpEnableJournalLogs) Print("RISK WARNING: cycle NET loss is uncapped; only the floating-loss cutout is active.");
   }
   if(InpMaxExposureLots <= 0.0 && InpEnableJournalLogs)
      Print("RISK WARNING: InpMaxExposureLots is disabled; total grid/recovery volume is uncapped.");
   if(!gIsTester && !InpPersistState && InpEnableJournalLogs)
      Print("RISK WARNING: state persistence is off; after an EA/terminal restart existing exposure will be recovery-blocked for manual handling.");
   if(InpDisasterSL <= 0.0 && InpEnableJournalLogs)
      Print("RISK WARNING: InpDisasterSL is off; unarmed positions have no broker-side disconnect protection.");
   if((InpUseGridLotProgression || UseDepthDoubling() || InpUseCenterReversalMultiplier) && InpEnableJournalLogs)
      Print("RISK WARNING: a lot-escalation feature is enabled; verify exposure limits before live trading.");
   if(InpUseCenterReversalMultiplier && InpUseDepthDouble && InpEnableJournalLogs)
      Print("Depth-triggered doubling is suspended while CENTER-REVERSAL GRID MULTIPLIER is enabled.");
   if(InpUseGridLotProgression && InpEnableJournalLogs)
   {
      double ladderLots = 0.0;
      for(int i=1; i<=GridOrdersPerSide(); i++) ladderLots += 2.0*TierLot(i);
      PrintFormat("Grid lot progression: %d levels per side, initial %.8f, multiplier %.4f, base pending volume %.8f lots (before doubling/reversal).",
                  GridOrdersPerSide(), InpGridInitialLot, InpGridLotMultiplier, ladderLots);
      if(InpMaxExposureLots > 0.0 && ladderLots > InpMaxExposureLots+1e-9)
         Print("Grid progression volume exceeds InpMaxExposureLots; safety guards can leave part of the grid unplaced.");
   }
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      if(InpEnableJournalLogs) Print("Initialization refused: this EA requires an MT5 hedging account.");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetMarginMode();
   int devPts = (int)MathRound(InpMaxSlippage / _Point);   // $ slippage -> points for this symbol
   if(devPts < 1) devPts = InpDeviation;                   // fall back if input is 0
   trade.SetDeviationInPoints(devPts);
   trade.SetTypeFillingBySymbol(_Symbol);
   if(resumeChartCycle)
   {
      // MT5 retains globals on a chart-period change. Keep cycle identity,
      // multiplier state, pending requests and trailing rate-limit tickets.
      gGridDirty = true;
      gManualRefreshDirty = true;
      gGridWatchValid = false;
      gRecoveryCommentShown = false;
      if(!gRecoveryBlocked)
      {
         UpdateFillDepths();
         if(InpUseCenterReversalMultiplier) RebuildCenterReversalOrigin();
         gBankHistoryDirty = true; // reconcile deals delivered during reinitialization
      }
      return FinishChartInitialization();
   }
   gRecoveryBlocked = false;
   gRecoveryMessage = "";
   gRecoveryCommentShown = false;
   gInit = false;                       // lazy-init on first tick when no cycle is being recovered
   gDailyPnL   = DailyRealized();
   gMonthlyPnL = MonthlyRealized();
   LoadMonthlyHaltState();
   bool haveExposure = (CountMyPositions() > 0 || CountMyPendings() > 0);
   bool loaded = LoadPersistentState();
   if(!loaded && HasClaimedManualExposure()) haveExposure=true;
   if(gRetiredCycleSnapshot)
   {
      gRecoveryBlocked = true;
      gInit = true;
      gRecoveryMessage = "Incompatible active cycle found. Finish it with its original settings/backup EA, then switch only while flat.";
      return FinishChartInitialization();
   }
   if(loaded)
   {
      gInit = true;
      gManualRefreshDirty = true;
      RefreshManualTradeIntegration();
      haveExposure = (CountMyPositions() > 0 || CountMyPendings() > 0);
      // Saved day/month boundaries can precede the current server date.
      gDailyPnL = DailyRealized();
      gMonthlyPnL = MonthlyRealized();
   }
   if(haveExposure)
   {
      if(!loaded || (!gCycleOpen && !gAwaitFlat && (!gDashboardResetPending || CountMyPositions() > 0)))
      {
         gRecoveryBlocked = true;
         gRecoveryMessage = "Existing EA exposure found without matching saved cycle state. No trades will be changed or added.";
         if(InpEnableJournalLogs) Print("RECOVERY BLOCK: ", gRecoveryMessage,
               " Resolve the positions/orders manually, then reinitialize the EA.");
         gInit = true;
      }
      else
      {
         gInit = true;
         gCycleRealized = CycleRealizedScan();
         RebuildRuntimeTracking();
         UpdateFillDepths();
         if(InpUseCenterReversalMultiplier) RebuildCenterReversalOrigin();
         if(InpEnableJournalLogs) PrintFormat("Recovered cycle: center=%.5f start=%s positions=%d orders=%d net=%.2f",
                     gCenter, TimeToString(gCycleStart, TIME_DATE|TIME_SECONDS),
                     CountMyPositions(), CountMyPendings(), gCycleRealized);
      }
   }
   else if(gDashboardResetPending)
   {
      gInit=true; // finish the pending-only reset even if cancellation completed before restart
   }
   else
   {
      // Preserve cooldown/last-side context, but never revive a stale empty cycle.
      gCycleOpen = false;
      gAwaitFlat = false;
      gFlatSettling = false;
      gInit = false;
   }

   return FinishChartInitialization();
}

bool CanResumeChartCycle()
{
   return(gChartResumePending && gInit && gAttachedSymbol == _Symbol &&
          gAttachedLogin > 0 && gAttachedLogin == AccountInfoInteger(ACCOUNT_LOGIN));
}

int FinishChartInitialization()
{
   if(!gIsTester && !EventSetTimer(1))
   {
      if(InpEnableJournalLogs) PrintFormat("Initialization failed: timer could not start (error %d).", GetLastError());
      return(INIT_FAILED);
   }
   gAttachedSymbol = _Symbol;
   gAttachedLogin = AccountInfoInteger(ACCOUNT_LOGIN);
   // Display immediately on a chart change, including when no new tick arrives.
   if(gInit && !gRecoveryBlocked)
   {
      RefreshBankAccounting();
      double bid, ask;
      if(FreshPrice(bid, ask)) DrawDashboard(bid, ask);
   }
   return(INIT_SUCCEEDED);
}
 
void OnDeinit(const int reason)
{
   gChartResumePending = (reason == REASON_CHARTCHANGE && gInit);
   if(gInit && !gRecoveryBlocked) SavePersistentState(true);
   EventKillTimer();
   ObjectsDeleteAll(0, "STRUI_");
   ResetDashboardDisplay();
   Comment("");
   ChartRedraw(0);
}

bool TradeRetcodeOK(uint code)
{
   return(code == TRADE_RETCODE_DONE ||
          code == TRADE_RETCODE_PLACED ||
          code == TRADE_RETCODE_DONE_PARTIAL ||
          code == TRADE_RETCODE_NO_CHANGES ||
          code == TRADE_RETCODE_ORDER_CHANGED ||
          code == TRADE_RETCODE_POSITION_CLOSED ||
          code == TRADE_RETCODE_CLOSE_ORDER_EXIST);
}

double DealNet(ulong ticket)
{
   return HistoryDealGetDouble(ticket, DEAL_PROFIT)
        + HistoryDealGetDouble(ticket, DEAL_SWAP)
        + HistoryDealGetDouble(ticket, DEAL_COMMISSION)
        + HistoryDealGetDouble(ticket, DEAL_FEE);
}

string DealTag(ulong ticket)
{
   string comment = HistoryDealGetString(ticket, DEAL_COMMENT);
   if(comment != "") return comment;
   ulong order = (ulong)HistoryDealGetInteger(ticket, DEAL_ORDER);
   if(order == 0) return "";
   if(!HistoryOrderSelect(order)) return ""; // an origin lookup may have selected a different historical order
   return HistoryOrderGetString(order, ORDER_COMMENT);
}

bool AddCyclePositionId(long &ids[], long id)
{
   if(id <= 0) return true;
   int size = ArraySize(ids), lo = 0, hi = size;
   while(lo < hi)
   {
      int mid = lo+(hi-lo)/2;
      if(ids[mid] < id) lo = mid+1;
      else hi = mid;
   }
   if(lo < size && ids[lo] == id) return true;
   if(ArrayResize(ids, size+1, 64) < 0) { gBankHistoryDirty = true; return false; }
   for(int i=size; i>lo; i--) ids[i] = ids[i-1];
   ids[lo] = id;
   return true;
}

void RememberCyclePosition(long id)
{
   if(!gCycleOpen || gFlatSettling || id <= 0) return;
   int before = ArraySize(gResetPositionIds);
   if(AddCyclePositionId(gResetPositionIds,id) && ArraySize(gResetPositionIds) != before)
      gCycleIdentityDirty = true;
}

void CaptureResetPositions()
{
   int before = ArraySize(gResetPositionIds);
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsManagedPositionSelected()) continue;
      AddCyclePositionId(gResetPositionIds, PositionGetInteger(POSITION_IDENTIFIER));
   }
   if(ArraySize(gResetPositionIds) != before) gCycleIdentityDirty = true;
}

bool IsCurrentCycleDeal(ulong ticket)
{
   if(!gCycleOpen || gFlatSettling || ticket == 0) return false;
   long time = HistoryDealGetInteger(ticket, DEAL_TIME_MSC);
   if(time <= 0) time = HistoryDealGetInteger(ticket, DEAL_TIME)*1000;
   long start = (gCycleStartMsc > 0 ? gCycleStartMsc : (long)gCycleStart*1000);
   if(time < start) return false;
   long id = HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
   long manualCycle = ManualTradeCycle(id);
   if(manualCycle > 0 && manualCycle != start) return false;
   int lo = 0, hi = ArraySize(gCycleExcludedPositions);
   while(lo < hi)
   {
      int mid = lo+(hi-lo)/2;
      if(gCycleExcludedPositions[mid] < id) lo = mid+1;
      else hi = mid;
   }
   if(id > 0 && lo < ArraySize(gCycleExcludedPositions) && gCycleExcludedPositions[lo] == id) return false;
   for(int i=0; i<ArraySize(gCycleExcludedDeals); i++)
      if(gCycleExcludedDeals[i] == ticket) return false;
   return true;
}

void ResetCycleAccounting()
{
   gCycleRealized = 0.0;
   gFlatCyclePending = false;
   gFlatCycleRetryAfter = 0;
   gCycleStartMsc = 0;
   ClearBankScope(BANK_CYCLE);
   gBankLockArmed = false;
   gBankLockPeak = 0.0;
   gBankLockFloor = 0.0;
   gBankLockRetainSide = 0;
   gWeeklyCacheWeek = 0;
   gCycleAccountingRevision++;
   gCycleIdentityDirty = true;
   gDashboardHistoryDirty = true;
}

bool BeginCycleAccounting()
{
   datetime now = TimeCurrent();
   if(now < gCycleBoundaryRetryAfter) return false;
   if(CountMyPositions() > 0 || CountMyPendings() > 0) return false;
   // Capture history before submitting this cycle's first order. Equal-ms
   // fills remain valid; already-existing deals/position IDs are excluded.
   if(!HistorySelect(now, now+1))
   {
      gCycleBoundaryRetryAfter = now+1;
      gBankHistoryDirty = true;
      return false;
   }
   long excludedPositions[];
   ulong excludedDeals[];
   for(int i=0; i<ArraySize(gResetPositionIds); i++)
      if(!AddCyclePositionId(excludedPositions, gResetPositionIds[i])) return false;
   if(InpIncludeManualTradesInCycle)
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         if(PositionGetTicket(i) == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
            PositionGetInteger(POSITION_MAGIC) != 0) continue;
         if(!AddCyclePositionId(excludedPositions,PositionGetInteger(POSITION_IDENTIFIER))) return false;
      }
      for(int i=OrdersTotal()-1; i>=0; i--)
      {
         ulong ticket=OrderGetTicket(i);
         if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != 0) continue;
         if(!AddCyclePositionId(excludedPositions,(long)ticket)) return false;
      }
   }
   int total = HistoryDealsTotal();
   for(int i=0; i<total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(!IsMine(HistoryDealGetInteger(ticket, DEAL_MAGIC), HistoryDealGetString(ticket, DEAL_SYMBOL)) &&
         !(InpIncludeManualTradesInCycle && HistoryDealGetString(ticket,DEAL_SYMBOL) == _Symbol &&
           HistoryDealGetInteger(ticket,DEAL_MAGIC) == 0)) continue;
      if(!AddCyclePositionId(excludedPositions, HistoryDealGetInteger(ticket, DEAL_POSITION_ID))) return false;
      int n = ArraySize(excludedDeals);
      if(ArrayResize(excludedDeals, n+1, 64) < 0) { gBankHistoryDirty = true; return false; }
      excludedDeals[n] = ticket;
   }
   if(ArrayResize(gCycleExcludedPositions, ArraySize(excludedPositions)) < 0 ||
      ArrayResize(gCycleExcludedDeals, ArraySize(excludedDeals)) < 0)
   { gBankHistoryDirty = true; return false; }
   ArrayCopy(gCycleExcludedPositions, excludedPositions);
   ArrayCopy(gCycleExcludedDeals, excludedDeals);
   ArrayResize(gResetPositionIds, 0);
   ResetCycleAccounting();
   gCycleStart = now;
   gCycleStartMsc = (long)now*1000;
   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick) && tick.time_msc >= gCycleStartMsc && tick.time_msc < gCycleStartMsc+1000)
      gCycleStartMsc = tick.time_msc;
   gCycleBoundaryRetryAfter = 0;
   gManualRefreshDirty = true;
   return true;
}

int BankDealIndex(ulong ticket)
{
   int size = ArraySize(gBankDeals), lo = 0, hi = size;
   while(lo < hi)
   {
      int mid = lo+(hi-lo)/2;
      if(gBankDeals[mid].ticket < ticket) lo = mid+1;
      else hi = mid;
   }
   if(lo < size && gBankDeals[lo].ticket == ticket) return lo;
   if(ArrayResize(gBankDeals, size+1, 256) < 0)
   {
      gBankScanFailed = true;
      gBankHistoryDirty = true;
      return -1;
   }
   for(int i=size; i>lo; i--) gBankDeals[i] = gBankDeals[i-1];
   ZeroMemory(gBankDeals[lo]);
   gBankDeals[lo].ticket = ticket;
   return lo;
}

double ApplyBankDeal(int idx, ENUM_BANK_SCOPE scope, datetime start, datetime time, double net)
{
   if(idx < 0 || start <= 0 || time < start) return 0.0;
   gBankDeals[idx].time = time;
   double previous = 0.0;
   switch(scope)
   {
      case BANK_CYCLE:
         if(gBankDeals[idx].cycleStart == start) previous = gBankDeals[idx].cycleNet;
         gBankDeals[idx].cycleStart = start; gBankDeals[idx].cycleNet = net;
         break;
      case BANK_DAY:
         if(gBankDeals[idx].dayStart == start) previous = gBankDeals[idx].dayNet;
         gBankDeals[idx].dayStart = start; gBankDeals[idx].dayNet = net;
         break;
      case BANK_MONTH:
         if(gBankDeals[idx].monthStart == start) previous = gBankDeals[idx].monthNet;
         gBankDeals[idx].monthStart = start; gBankDeals[idx].monthNet = net;
         break;
   }
   return net-previous;
}

void ClearBankScope(ENUM_BANK_SCOPE scope)
{
   // Rebuild just this scope: other banks may still be awaiting a deal callback.
   for(int i=0; i<ArraySize(gBankDeals); i++)
   {
      switch(scope)
      {
         case BANK_CYCLE: gBankDeals[i].cycleStart=0; gBankDeals[i].cycleNet=0.0; break;
         case BANK_DAY: gBankDeals[i].dayStart=0; gBankDeals[i].dayNet=0.0; break;
         case BANK_MONTH: gBankDeals[i].monthStart=0; gBankDeals[i].monthNet=0.0; break;
      }
   }
}

void PruneBankDeals()
{
   datetime keepFrom = gMonthStart;
   if(gDayStart > 0 && (keepFrom <= 0 || gDayStart < keepFrom)) keepFrom = gDayStart;
   if((gCycleOpen || gAwaitFlat) && gCycleStart > 0 && (keepFrom <= 0 || gCycleStart < keepFrom))
      keepFrom = gCycleStart;
   if(keepFrom <= 0) return;
   int kept = 0;
   for(int i=0; i<ArraySize(gBankDeals); i++)
      if(gBankDeals[i].time >= keepFrom)
      {
         if(kept != i) gBankDeals[kept] = gBankDeals[i];
         kept++;
      }
   ArrayResize(gBankDeals, kept);
}

bool ReconcileBankHistory()
{
   datetime now=TimeCurrent();
   MqlDateTime parts;
   TimeToStruct(now,parts);
   parts.hour=0; parts.min=0; parts.sec=0;
   datetime dayStart=StructToTime(parts);
   datetime monthStart=CurrentMonthStart();
   bool newDay=(dayStart != gDayStart), newMonth=(monthStart != gMonthStart);
   if(newDay)
   {
      gDayStart=dayStart;
      gDayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
      gHaltedToday=false;
      gConsecutiveLosses=0;
      gDailyPnL=0.0;
   }
   if(newMonth) { gMonthStart=monthStart; gHaltedMonth=false; gMonthlyPnL=0.0; }
   if(newDay || newMonth) PruneBankDeals();
   bool cycle=(gCycleOpen && !gFlatSettling);
   datetime from=(dayStart < monthStart ? dayStart : monthStart);
   if(cycle && gCycleStart < from) from=gCycleStart;
   if(!HistorySelect(from,now+1)) return false;

   // Stage a single history read before replacing any confirmed ledger scope.
   // A missing origin or allocation failure must not partially seed a bank.
   BankReconcileDeal rows[];
   int total=HistoryDealsTotal(), count=0;
   double dayNet=0.0, monthNet=0.0, cycleNet=0.0;
   for(int i=0; i<total; i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(ticket == 0) return false;
      if(!IsAccountingDeal(ticket)) continue;
      if(gBankScanFailed) return false;
      if(ArrayResize(rows,count+1,256) != count+1) return false;
      if(BankDealIndex(ticket) < 0) return false;
      rows[count].ticket=ticket;
      rows[count].time=(datetime)HistoryDealGetInteger(ticket,DEAL_TIME);
      rows[count].net=DealNet(ticket);
      rows[count].cycle=(cycle && IsCurrentCycleDeal(ticket));
      if(rows[count].time >= dayStart) dayNet+=rows[count].net;
      if(rows[count].time >= monthStart) monthNet+=rows[count].net;
      if(rows[count].cycle) cycleNet+=rows[count].net;
      count++;
   }
   if(gBankScanFailed) return false;
   ClearBankScope(BANK_DAY);
   ClearBankScope(BANK_MONTH);
   if(cycle) ClearBankScope(BANK_CYCLE);
   for(int i=0; i<count; i++)
   {
      int idx=BankDealIndex(rows[i].ticket); // all records were allocated before committing
      ApplyBankDeal(idx,BANK_DAY,dayStart,rows[i].time,rows[i].net);
      ApplyBankDeal(idx,BANK_MONTH,monthStart,rows[i].time,rows[i].net);
      if(rows[i].cycle) ApplyBankDeal(idx,BANK_CYCLE,gCycleStart,rows[i].time,rows[i].net);
   }
   gDailyPnL=dayNet;
   gMonthlyPnL=monthNet;
   if(cycle) { gCycleRealized=cycleNet; gDashboardHistoryDirty=true; }
   return true;
}

void RefreshBankAccounting()
{
   if(!gBankHistoryDirty || gRecoveryBlocked) return;
   datetime now = TimeCurrent();
   if(now < gBankRetryAfter) return;
   bool wasRetrying = (gBankRetryAfter > 0);
   gBankScanFailed = false;
   if(!ReconcileBankHistory()) gBankScanFailed=true;
   gBankHistoryDirty = gBankScanFailed;
   gBankRetryAfter = (gBankScanFailed ? now+1 : 0);
   if(gBankScanFailed && !wasRetrying && InpEnableJournalLogs)
      Print("Bank accounting pending: history could not be read. New exposure and bank-profit exits are paused; retrying once per server second.");
   else if(!gBankScanFailed && wasRetrying && InpEnableJournalLogs)
      Print("Bank accounting recovered: realized totals reconciled with deal history.");
}
 
//+------------------------------------------------------------------+
//| Event-driven bank includes booked profit, swap, commission and  |
//| fees, including entry costs. A history refresh and its queued    |
//| callback must not book the same deal twice.                     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   // Only inventory-changing events invalidate the grid cache. PositionModify
   // requests (trailing SL updates) do not force an unnecessary full rebuild.
   if(trans.type == TRADE_TRANSACTION_ORDER_ADD ||
      trans.type == TRADE_TRANSACTION_ORDER_UPDATE ||
      trans.type == TRADE_TRANSACTION_ORDER_DELETE ||
      trans.type == TRADE_TRANSACTION_DEAL_ADD ||
      trans.type == TRADE_TRANSACTION_DEAL_UPDATE ||
      trans.type == TRADE_TRANSACTION_DEAL_DELETE)
   {
      gGridDirty = true;
      gFlatCycleRetryAfter = 0;
      InvalidatePositionSnapshot();
   }
   if(InpIncludeManualTradesInCycle &&
      (trans.type == TRADE_TRANSACTION_ORDER_ADD || trans.type == TRADE_TRANSACTION_ORDER_UPDATE) &&
      (trans.symbol == _Symbol || trans.symbol == ""))
   {
      if(trans.order > 0 && OrderSelect(trans.order))
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
            IsManualOrigin(OrderGetInteger(ORDER_MAGIC),OrderGetInteger(ORDER_REASON)))
            AdoptManualTrade((long)trans.order,OrderGetInteger(ORDER_TIME_SETUP_MSC));
      }
      else gManualRefreshDirty=true; // inventory may not yet reflect this event
   }
   if(trans.type == TRADE_TRANSACTION_POSITION) InvalidatePositionSnapshot();
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD ||
      trans.type == TRADE_TRANSACTION_DEAL_UPDATE ||
      trans.type == TRADE_TRANSACTION_DEAL_DELETE)
      gDashboardHistoryDirty = true;

   if(trans.type == TRADE_TRANSACTION_REQUEST &&
      request.magic == (ulong)InpMagic && request.symbol == _Symbol &&
      !TradeRetcodeOK(result.retcode))
   {
      if(InpEnableJournalLogs) PrintFormat("Trade server rejected request: action=%d retcode=%u comment=%s order=%I64u deal=%I64u",
                  (int)request.action, result.retcode, result.comment, result.order, result.deal);
      if(request.position == 0 &&
         (request.action == TRADE_ACTION_DEAL || request.action == TRADE_ACTION_PENDING))
      {
         int seconds = InpEntryBackoffSec;
         if(result.retcode == TRADE_RETCODE_TOO_MANY_REQUESTS && seconds < 5) seconds = 5;
         if((result.retcode == TRADE_RETCODE_MARKET_CLOSED || result.retcode == TRADE_RETCODE_TRADE_DISABLED ||
             result.retcode == TRADE_RETCODE_CONNECTION) && seconds < 30) seconds = 30;
         gEntryBackoffUntil = TimeCurrent() + seconds;
      }
   }

   if(trans.type == TRADE_TRANSACTION_DEAL_UPDATE || trans.type == TRADE_TRANSACTION_DEAL_DELETE)
   {
      if(trans.symbol == _Symbol || trans.symbol == "") gBankHistoryDirty = true;
      return;
   }
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong dealTk = trans.deal;
   if(dealTk == 0) return;
   if(!HistoryDealSelect(dealTk)) { gBankHistoryDirty = true; return; }
   if(!IsAccountingDeal(dealTk)) return;
   // Daily accounting is independent of the active cycle boundary, including a
   // rare late-fill close during the reset settle window.
   datetime dealTime = (datetime)HistoryDealGetInteger(dealTk, DEAL_TIME);
   double dealNet = DealNet(dealTk);
   int bankIdx = BankDealIndex(dealTk);
   gDailyPnL += ApplyBankDeal(bankIdx, BANK_DAY, gDayStart, dealTime, dealNet);
   gMonthlyPnL += ApplyBankDeal(bankIdx, BANK_MONTH, gMonthStart, dealTime, dealNet);

   // The remaining banks and depth state belong only to the current cycle.
   if(!IsCurrentCycleDeal(dealTk)) { gWeeklyCacheWeek=0; return; }
   long type = HistoryDealGetInteger(dealTk,DEAL_TYPE);
   if(type == DEAL_TYPE_BUY || type == DEAL_TYPE_SELL)
      RememberCyclePosition(HistoryDealGetInteger(dealTk,DEAL_POSITION_ID));
   if(gCycleOpen && !gFlatSettling)
      gCycleRealized += ApplyBankDeal(bankIdx, BANK_CYCLE, gCycleStart, dealTime, dealNet);

   UpdateFillDepthFromDeal(dealTk);
   SavePersistentState(false);
}
 
//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double NormPrice(double p)
{
   double ts = (gSymbolTickSize > 0.0 ? gSymbolTickSize : _Point);
   return NormalizeDouble(MathRound(p/ts)*ts, _Digits);
}
 
double NormLot(double l)
{
   double mn = gSymbolVolumeMin;
   double mx = gSymbolVolumeMax;
   double st = (gSymbolVolumeStep > 0.0 ? gSymbolVolumeStep : 0.01);
   if(mn <= 0.0) mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(mx <= 0.0) mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   // Never round risk upward. Values below the broker minimum still use minimum.
   l = MathFloor((l + 1e-12)/st)*st;
   if(l < mn) l = mn;
   if(l > mx) l = mx;
   return NormalizeDouble(l, 8);
}
 
double StopsMin()
{
   long lvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long frz = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if(frz > lvl) lvl = frz;
   double m = lvl * _Point;
   if(m < 2*_Point) m = 2*_Point;
   return m;
}

int GridOrdersPerSide()
{
   return (InpUseGridLotProgression ? InpProgressionOrdersPerSide : InpOrdersPerSide);
}

double TierLot(int idx)  // idx 1..GridOrdersPerSide()
{
   if(InpUseGridLotProgression)
   {
      // Compound the raw initial lot, not the previously rounded order volume.
      double lot = InpGridInitialLot*MathPow(InpGridLotMultiplier, idx-1);
      if(!MathIsValidNumber(lot))
         lot = (gSymbolVolumeMax > 0.0 ? gSymbolVolumeMax : SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));
      return NormLot(lot);
   }
   double lot;
   if(idx <= InpTierSize)          lot = InpLotNear;   // near
   else if(idx <= 2*InpTierSize)   lot = InpLotMid;    // mid
   else                            lot = InpLotFar;    // far (2*TierSize+1 .. OrdersPerSide)
   return NormLot(lot);
}
 
bool IsMine(long magic, string sym)
{
   return(magic == InpMagic && sym == _Symbol);
}

long ManualTradeCycle(long id)
{
   int lo=0, hi=ArraySize(gManualTrades);
   while(lo < hi)
   {
      int mid=lo+(hi-lo)/2;
      if(gManualTrades[mid].id < id) lo=mid+1; else hi=mid;
   }
   return(lo < ArraySize(gManualTrades) && gManualTrades[lo].id == id ? gManualTrades[lo].cycle : 0);
}

bool IsManualOrigin(long magic, long reason)
{
   return(magic == 0 && (reason == ORDER_REASON_CLIENT || reason == ORDER_REASON_MOBILE || reason == ORDER_REASON_WEB));
}

int TradeOriginIndex(long id)
{
   if(id <= 0) return -1;
   int size=ArraySize(gTradeOrigins), lo=0, hi=size;
   while(lo < hi)
   {
      int mid=lo+(hi-lo)/2;
      if(gTradeOrigins[mid].id < id) lo=mid+1; else hi=mid;
   }
   if(lo < size && gTradeOrigins[lo].id == id) return lo;
   TradeOrigin origin;
   origin.id=id;
   // On a hedging account the stable identifier is the original opening order.
   // HistoryOrderSelect changes only the order list, never the caller's deal list.
   if(HistoryOrderSelect((ulong)id))
   {
      origin.magic=HistoryOrderGetInteger((ulong)id,ORDER_MAGIC);
      origin.reason=HistoryOrderGetInteger((ulong)id,ORDER_REASON);
      origin.setupMsc=HistoryOrderGetInteger((ulong)id,ORDER_TIME_SETUP_MSC);
      origin.symbol=HistoryOrderGetString((ulong)id,ORDER_SYMBOL);
   }
   else if(OrderSelect((ulong)id)) // a partially filled opening order may still be active
   {
      origin.magic=OrderGetInteger(ORDER_MAGIC);
      origin.reason=OrderGetInteger(ORDER_REASON);
      origin.setupMsc=OrderGetInteger(ORDER_TIME_SETUP_MSC);
      origin.symbol=OrderGetString(ORDER_SYMBOL);
   }
   else
   {
      gBankScanFailed=true; gBankHistoryDirty=true;
      return -1; // unknown origins must be retried, never guessed or negatively cached
   }
   if(ArrayResize(gTradeOrigins,size+1,128) < 0)
   { gBankScanFailed=true; gBankHistoryDirty=true; return -1; }
   for(int i=size; i>lo; i--) gTradeOrigins[i]=gTradeOrigins[i-1];
   gTradeOrigins[lo]=origin;
   return lo;
}

// One terminal owner per manual opening order prevents two different magic
// numbers from booking/managing the same manual trade. No broker request is sent.
string ManualOwnershipKey(long id)
{
   return StringFormat("SNBM.%I64d.%u.%I64d",AccountInfoInteger(ACCOUNT_LOGIN),StateSymbolHash(),id);
}

bool HasClaimedManualExposure()
{
   if(gIsTester) return false;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(PositionGetTicket(i) == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != 0) continue;
      string key=ManualOwnershipKey(PositionGetInteger(POSITION_IDENTIFIER));
      if(GlobalVariableCheck(key) && GlobalVariableGet(key) == (double)InpMagic) return true;
   }
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != 0) continue;
      string key=ManualOwnershipKey((long)ticket);
      if(GlobalVariableCheck(key) && GlobalVariableGet(key) == (double)InpMagic) return true;
   }
   return false;
}

bool ClaimManualTrade(long id)
{
   if(gIsTester) return true;
   string prefix=StringFormat("SNBM.%I64d.%u.",AccountInfoInteger(ACCOUNT_LOGIN),StateSymbolHash());
   string key=ManualOwnershipKey(id), mutex=prefix+"lock";
   if(!GlobalVariableCheck(mutex) && !GlobalVariableTemp(mutex) && !GlobalVariableCheck(mutex))
   { gManualDiscoveryPending=true; gBankScanFailed=true; gBankHistoryDirty=true; return false; }
   double previous=GlobalVariableGet(mutex), now=(double)GetTickCount64();
   if(previous > now || !GlobalVariableSetOnCondition(mutex,now+5000.0,previous))
   { gManualDiscoveryPending=true; gBankScanFailed=true; gBankHistoryDirty=true; return false; }
   bool owned=false;
   if(GlobalVariableCheck(key)) owned=(GlobalVariableGet(key) == (double)InpMagic);
   else
   {
      owned=(GlobalVariableSet(key,(double)InpMagic) > 0);
      if(!owned) { gManualDiscoveryPending=true; gBankScanFailed=true; gBankHistoryDirty=true; }
   }
   GlobalVariableSetOnCondition(mutex,0.0,now+5000.0);
   return owned;
}

bool AdoptManualTrade(long id, long setupMsc)
{
   if(ManualTradeCycle(id) > 0) return true;
   if(!gInit || !InpIncludeManualTradesInCycle || (!gCycleOpen && !gAwaitFlat) || gFlatSettling ||
      gRecoveryBlocked || id <= 0 || gCycleStartMsc <= 0 || setupMsc < gCycleStartMsc) return false;
   int excludedLo=0, excludedHi=ArraySize(gCycleExcludedPositions);
   while(excludedLo < excludedHi)
   {
      int mid=excludedLo+(excludedHi-excludedLo)/2;
      if(gCycleExcludedPositions[mid] < id) excludedLo=mid+1; else excludedHi=mid;
   }
   if(excludedLo < ArraySize(gCycleExcludedPositions) && gCycleExcludedPositions[excludedLo] == id) return false;
   if(!ClaimManualTrade(id)) return false;
   int size=ArraySize(gManualTrades), lo=0, hi=size;
   if(size >= 100000) { gBankScanFailed=true; gBankHistoryDirty=true; return false; }
   while(lo < hi)
   {
      int mid=lo+(hi-lo)/2;
      if(gManualTrades[mid].id < id) lo=mid+1; else hi=mid;
   }
   if(ArrayResize(gManualTrades,size+1,32) < 0)
   { gBankScanFailed=true; gBankHistoryDirty=true; return false; }
   for(int i=size; i>lo; i--) gManualTrades[i]=gManualTrades[i-1];
   gManualTrades[lo].id=id;
   gManualTrades[lo].cycle=gCycleStartMsc;
   gManualIdentityDirty=true;
   gBankHistoryDirty=true; gDashboardHistoryDirty=true; gGridDirty=true;
   InvalidatePositionSnapshot();
   SavePersistentState(true); // commit ownership before trailing/cancel/close can act
   if(InpEnableJournalLogs) PrintFormat("Manual trade adopted into this cycle: original order/position ID %I64d; management %s.",id,InpManageManualTrades ? "on" : "off");
   return true;
}

bool IsAccountingDeal(ulong ticket)
{
   if(ticket == 0 || HistoryDealGetString(ticket,DEAL_SYMBOL) != _Symbol) return false;
   long type=HistoryDealGetInteger(ticket,DEAL_TYPE);
   if(type == DEAL_TYPE_BALANCE || type == DEAL_TYPE_CREDIT || type == DEAL_TYPE_BONUS) return false;
   if(HistoryDealGetInteger(ticket,DEAL_MAGIC) == InpMagic) return true; // retain separately booked EA costs as well
   if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) return false;
   long id=HistoryDealGetInteger(ticket,DEAL_POSITION_ID);
   if(id <= 0) return false;
   if(ManualTradeCycle(id) > 0) return true;
   int origin=TradeOriginIndex(id);
   if(origin < 0 || gTradeOrigins[origin].symbol != _Symbol) return false;
   if(gTradeOrigins[origin].magic == InpMagic) return true; // includes manual/partial/close-by exits of EA positions
   if(!IsManualOrigin(gTradeOrigins[origin].magic,gTradeOrigins[origin].reason)) return false;
   return AdoptManualTrade(id,gTradeOrigins[origin].setupMsc);
}

bool ManualTradeInCurrentCycle(long id)
{
   return((gCycleOpen || gAwaitFlat) && !gFlatSettling && gCycleStartMsc > 0 &&
          ManualTradeCycle(id) == gCycleStartMsc);
}

bool AdoptSelectedManualPosition()
{
   if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != 0) return false;
   long reason=PositionGetInteger(POSITION_REASON);
   if(reason != POSITION_REASON_CLIENT && reason != POSITION_REASON_MOBILE && reason != POSITION_REASON_WEB) return false;
   long opened=PositionGetInteger(POSITION_TIME_MSC);
   if(opened <= 0) opened=PositionGetInteger(POSITION_TIME)*1000;
   // Pre-cycle positions and pending orders are also excluded by stable ID at
   // BeginCycleAccounting. A live manual fill need not wait for order history.
   return AdoptManualTrade(PositionGetInteger(POSITION_IDENTIFIER),opened);
}

bool IsCyclePositionSelected()
{
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   long magic=PositionGetInteger(POSITION_MAGIC), id=PositionGetInteger(POSITION_IDENTIFIER);
   if(magic == InpMagic) return true;
   if(magic == 0 && ManualTradeCycle(id) == 0 && InpIncludeManualTradesInCycle &&
      gInit && (gCycleOpen || gAwaitFlat) && !gFlatSettling && !gRecoveryBlocked)
   {
      AdoptSelectedManualPosition();
   }
   return ManualTradeInCurrentCycle(id);
}

bool IsManagedPositionSelected()
{
   return(IsCyclePositionSelected() && (PositionGetInteger(POSITION_MAGIC) == InpMagic ||
          (InpIncludeManualTradesInCycle && InpManageManualTrades)));
}

bool IsCycleOrderSelected()
{
   if(OrderGetString(ORDER_SYMBOL) != _Symbol) return false;
   long magic=OrderGetInteger(ORDER_MAGIC), id=(long)OrderGetInteger(ORDER_TICKET);
   if(magic == InpMagic) return true;
   if(IsManualOrigin(magic,OrderGetInteger(ORDER_REASON)) && ManualTradeCycle(id) == 0)
      AdoptManualTrade(id,OrderGetInteger(ORDER_TIME_SETUP_MSC));
   return ManualTradeInCurrentCycle(id);
}

bool IsManagedOrderSelected()
{
   return(IsCycleOrderSelected() && (OrderGetInteger(ORDER_MAGIC) == InpMagic ||
          (InpIncludeManualTradesInCycle && InpManageManualTrades)));
}

void RefreshManualTradeIntegration()
{
   if(!gManualRefreshDirty || !InpIncludeManualTradesInCycle || (!gCycleOpen && !gAwaitFlat) ||
      gFlatSettling || gRecoveryBlocked) return;
   gManualRefreshDirty=false;
   gManualDiscoveryPending=false;
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol ||
         !IsManualOrigin(OrderGetInteger(ORDER_MAGIC),OrderGetInteger(ORDER_REASON))) continue;
      AdoptManualTrade((long)ticket,OrderGetInteger(ORDER_TIME_SETUP_MSC));
   }
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != 0) continue;
      long id=PositionGetInteger(POSITION_IDENTIFIER);
      if(ManualTradeCycle(id) > 0) continue;
      AdoptSelectedManualPosition();
   }
   gManualRefreshDirty=(gManualDiscoveryPending || gBankScanFailed);
}
 
//--- Compatibility only: positions opened by versions with the removed PPG
//--- engine remain part of the main cycle, but grid logic must not adopt them.
bool IsLegacyPPGCmt(string cmt)
{
   return(StringFind(cmt, "PPG") == 0);
}
//--- true for any sub-engine leg (skip in grid/trailing/depth scans)
bool IsSubEngineCmt(string cmt)
{
   return IsLegacyPPGCmt(cmt);
}

bool TradeCallOK(bool sent, string action)
{
   uint code = trade.ResultRetcode();
   if(sent && TradeRetcodeOK(code)) return true;
   if(InpEnableJournalLogs) PrintFormat("%s failed: sent=%s retcode=%u (%s) terminalError=%d",
               action, sent ? "true" : "false", code,
               trade.ResultRetcodeDescription(), GetLastError());
   return false;
}

double CurrentExposureLots()
{
   RefreshPositionSnapshot();
   double lots = gPositionSnapshotVolume;
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(IsCycleOrderSelected())
         lots += OrderGetDouble(ORDER_VOLUME_CURRENT);
   }
   return lots;
}

void LogEntryGuard(string reason)
{
   static datetime lastLog = 0;
   datetime now = TimeCurrent();
   if(now - lastLog >= 10)
   {
      lastLog = now;
      if(InpEnableJournalLogs) Print("Entry blocked by safety guard: ", reason);
   }
}

double PendingWorstCaseMargin()
{
   double total = 0.0;
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!IsCycleOrderSelected()) continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      ENUM_ORDER_TYPE calcType;
      if(ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_BUY_LIMIT || ot == ORDER_TYPE_BUY_STOP_LIMIT)
         calcType = ORDER_TYPE_BUY;
      else if(ot == ORDER_TYPE_SELL_STOP || ot == ORDER_TYPE_SELL_LIMIT || ot == ORDER_TYPE_SELL_STOP_LIMIT)
         calcType = ORDER_TYPE_SELL;
      else
         continue;
      double margin = 0.0;
      if(OrderCalcMargin(calcType, _Symbol, OrderGetDouble(ORDER_VOLUME_CURRENT),
                         OrderGetDouble(ORDER_PRICE_OPEN), margin))
         total += margin;
   }
   return total;
}

void BeginExposureBatch()
{
   gExposureBatchLots = CurrentExposureLots();
   gExposureBatchPendingMargin = (InpMinMarginLevelPct > 0.0 ? PendingWorstCaseMargin() : 0.0);
   gExposureBatchEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   gExposureBatchLastExtra = 0.0;
   gExposureBatchActive = true;
}

void EndExposureBatch()
{
   gExposureBatchActive = false;
   gExposureBatchLastExtra = 0.0;
}

void CommitExposureBatch(double lot)
{
   if(!gExposureBatchActive) return;
   gExposureBatchLots += lot;
   gExposureBatchPendingMargin += gExposureBatchLastExtra;
   gExposureBatchLastExtra = 0.0;
}

bool CanAddExposure(ENUM_ORDER_TYPE orderType, double lot, double price,
                    string context, double reservedLots=0.0)
{
   if(gRecoveryBlocked || gAwaitFlat || gDashboardResetPending || gHaltedToday ||
      (gHaltedMonth && !gCycleOpen)) return false;
   if(gCycleOpen ? ActiveCycleRiskLocked() : EntryRiskLocked()) return false;
   if(TimeCurrent() < gEntryBackoffUntil) return false;

   if(InpMaxExposureLots > 0.0)
   {
      double currentLots = (gExposureBatchActive ? gExposureBatchLots : CurrentExposureLots());
      double projectedLots = currentLots + reservedLots + lot;
      if(projectedLots > InpMaxExposureLots + 1e-8)
      {
         LogEntryGuard(StringFormat("%s would raise exposure to %.2f lots (limit %.2f)",
                                    context, projectedLots, InpMaxExposureLots));
         return false;
      }
   }

   if(InpMinMarginLevelPct > 0.0)
   {
      double equity = (gExposureBatchActive ? gExposureBatchEquity : AccountInfoDouble(ACCOUNT_EQUITY));
      double pendingMargin = (gExposureBatchActive ? gExposureBatchPendingMargin : PendingWorstCaseMargin());
      double used   = AccountInfoDouble(ACCOUNT_MARGIN) + pendingMargin;
      double extra  = 0.0;
      ENUM_ORDER_TYPE calcType = (orderType == ORDER_TYPE_BUY || orderType == ORDER_TYPE_BUY_STOP ||
                                  orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP_LIMIT)
                                 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(OrderCalcMargin(calcType, _Symbol, lot, price, extra))
      {
         if(gExposureBatchActive) gExposureBatchLastExtra = extra;
         double projectedMargin = used + extra;
         double projectedLevel = (projectedMargin > 0.0 ? 100.0*equity/projectedMargin : 1.0e100);
         if(projectedLevel < InpMinMarginLevelPct)
         {
            LogEntryGuard(StringFormat("%s projects margin level %.1f%% (minimum %.1f%%)",
                                       context, projectedLevel, InpMinMarginLevelPct));
            return false;
         }
      }
      else
      {
         LogEntryGuard(StringFormat("%s margin calculation failed (error %d)", context, GetLastError()));
         return false;
      }
   }
   return true;
}

void ApplyEntryBackoff()
{
   uint code = trade.ResultRetcode();
   int seconds = InpEntryBackoffSec;
   if(code == TRADE_RETCODE_TOO_MANY_REQUESTS && seconds < 5) seconds = 5;
   if(code == TRADE_RETCODE_MARKET_CLOSED || code == TRADE_RETCODE_TRADE_DISABLED ||
      code == TRADE_RETCODE_CONNECTION)
      if(seconds < 30) seconds = 30;
   gEntryBackoffUntil = TimeCurrent() + seconds;
}



bool PlaceBuyStop(double lot, double price, double sl, string comment, double reservedLots=0.0)
{
   lot = NormLot(lot);
   if(!CanAddExposure(ORDER_TYPE_BUY_STOP, lot, price, comment, reservedLots)) return false;
   InvalidatePositionSnapshot();
   bool ok = TradeCallOK(trade.BuyStop(lot, price, _Symbol, sl, 0, ORDER_TIME_GTC, 0, comment),
                         "BuyStop "+comment);
   if(ok) CommitExposureBatch(lot);
   if(!ok) ApplyEntryBackoff();
   return ok;
}

bool PlaceSellStop(double lot, double price, double sl, string comment, double reservedLots=0.0)
{
   lot = NormLot(lot);
   if(!CanAddExposure(ORDER_TYPE_SELL_STOP, lot, price, comment, reservedLots)) return false;
   InvalidatePositionSnapshot();
   bool ok = TradeCallOK(trade.SellStop(lot, price, _Symbol, sl, 0, ORDER_TIME_GTC, 0, comment),
                         "SellStop "+comment);
   if(ok) CommitExposureBatch(lot);
   if(!ok) ApplyEntryBackoff();
   return ok;
}

bool ModifyPositionSafe(ulong ticket, double sl, double tp)
{
   InvalidatePositionSnapshot();
   return TradeCallOK(trade.PositionModify(ticket, sl, tp),
                      StringFormat("PositionModify #%I64u", ticket));
}

bool DeleteOrderSafe(ulong ticket)
{
   InvalidatePositionSnapshot();
   // A stop may have filled since the grid snapshot; an absent order is not a
   // cancellation failure. Maintenance refreshes inventory before replacing it.
   if(!OrderSelect(ticket)) return true;
   return TradeCallOK(trade.OrderDelete(ticket), StringFormat("OrderDelete #%I64u", ticket));
}

bool ClosePositionSafe(ulong ticket)
{
   InvalidatePositionSnapshot();
   if(!PositionSelectByTicket(ticket)) return true;
   return TradeCallOK(trade.PositionClose(ticket), StringFormat("PositionClose #%I64u", ticket));
}
 
 
 
//+------------------------------------------------------------------+
//| BULK EXIT ENGINE (async dispatch, pending-close guard)           |
//+------------------------------------------------------------------+
bool IsClosePending(ulong ticket)
{
   uint now = RequestClockMs();
   for(int i=0; i<ArraySize(gClosingTk); i++)
      if(gClosingTk[i] == ticket)
         return((now - gClosingMs[i]) < (uint)InpCloseRetryMs);   // still fresh
   return false;
}
 
void MarkClosePending(ulong ticket)
{
   uint now = RequestClockMs();
   for(int i=0; i<ArraySize(gClosingTk); i++)
      if(gClosingTk[i] == ticket){ gClosingMs[i] = now; return; }
   int n = ArraySize(gClosingTk);
   ArrayResize(gClosingTk, n+1); ArrayResize(gClosingMs, n+1);
   gClosingTk[n] = ticket; gClosingMs[n] = now;
}
 
void SweepClosePending()
{
   for(int i=ArraySize(gClosingTk)-1; i>=0; i--)
   {
      if(!PositionSelectByTicket(gClosingTk[i]))
      {
         int last = ArraySize(gClosingTk)-1;
         gClosingTk[i] = gClosingTk[last];
         gClosingMs[i] = gClosingMs[last];
         ArrayResize(gClosingTk, last);
         ArrayResize(gClosingMs, last);
      }
   }
}
 
int BulkClosePositions(ulong &tickets[], int count)
{
   if(count <= 0) return 0;
   int sent = 0;
   trade.SetAsyncMode(InpAsyncClose);          // don't block on each reply
   for(int i=0; i<count; i++)
   {
      ulong tk = tickets[i];
      if(IsClosePending(tk)) continue;         // already in flight
      MarkClosePending(tk); // rejected/partial requests must not be retried on every tick
      if(ClosePositionSafe(tk)) sent++;
   }
   trade.SetAsyncMode(false);                  // back to sync for order placement
   return sent;
}
 
int CloseAllMyPositions()
{
   ulong tk[]; int n = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(!IsManagedPositionSelected()) continue;
      ArrayResize(tk, n+1); tk[n] = t; n++;
   }
   return BulkClosePositions(tk, n);
}
 
//+------------------------------------------------------------------+
//| Cycle PnL pieces                                                 |
//+------------------------------------------------------------------+
//--- Recovery/correction baseline; seed the ledger before queued deal callbacks.
double CycleRealizedScan()
{
   if(!gCycleOpen || gFlatSettling) return 0.0;
   double sum = 0.0;
   if(!HistorySelect(gCycleStart, TimeCurrent()+1))
   {
      gBankScanFailed = true; gBankHistoryDirty = true;
      return gCycleRealized;
   }
   ClearBankScope(BANK_CYCLE);
   gDashboardHistoryDirty = true;
   int total = HistoryDealsTotal();
   for(int i=0; i<total; i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if(!IsAccountingDeal(t)) continue;
      if(!IsCurrentCycleDeal(t)) continue;
      double net = DealNet(t);
      int bankIdx = BankDealIndex(t);
      if(bankIdx < 0) return gCycleRealized;
      ApplyBankDeal(bankIdx, BANK_CYCLE, gCycleStart, (datetime)HistoryDealGetInteger(t, DEAL_TIME), net);
      sum += net;
   }
   return(gBankScanFailed ? gCycleRealized : sum);
}
 
//--- FAST realized PnL: returns the running total maintained event-driven by
//--- OnTradeTransaction (no history scan -> fast + accurate on live). A
//--- periodic reconcile in the heavy block re-syncs it to CycleRealizedScan().
double CycleRealized()
{
   return gCycleRealized;
}
 
void PositionSummary(double &floating, int &count)
{
   RefreshPositionSnapshot();
   floating = gPositionSnapshotFloating;
   count = gPositionSnapshotCount;
}

void InvalidatePositionSnapshot()
{
   gPositionSnapshotValid = false;
   gPositionSnapshotRevision++;
}

void CachePositionSnapshot(double floating, int count, double buy, double sell,
                           double volume, int accountCount, ulong revision, int manualBuys, int manualSells)
{
   gPositionSnapshotFloating = floating;
   gPositionSnapshotCount = count;
   gPositionSnapshotBuy = buy;
   gPositionSnapshotSell = sell;
   gPositionSnapshotManualBuyCount = manualBuys;
   gPositionSnapshotManualSellCount = manualSells;
   gPositionSnapshotVolume = volume;
   gPositionSnapshotAccountCount = accountCount;
   gPositionSnapshotValid = (revision == gPositionSnapshotRevision && accountCount == PositionsTotal());
}

void RefreshPositionSnapshot()
{
   int accountCount = PositionsTotal();
   if(gPositionSnapshotValid && accountCount == gPositionSnapshotAccountCount) return;
   ulong revision = gPositionSnapshotRevision;
   double floating=0.0, buy=0.0, sell=0.0, volume=0.0;
   int count=0, manualBuys=0, manualSells=0;
   for(int i=accountCount-1; i>=0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsCyclePositionSelected()) continue;
      RememberCyclePosition(PositionGetInteger(POSITION_IDENTIFIER));
      double pnl = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      floating += pnl;
      volume += PositionGetDouble(POSITION_VOLUME);
      bool isBuy=(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if(isBuy) buy += pnl;
      else sell += pnl;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
      {
         if(isBuy) manualBuys++; else manualSells++;
      }
      count++;
   }
   CachePositionSnapshot(floating, count, buy, sell, volume, accountCount, revision, manualBuys, manualSells);
}

double FloatingPnL()     // floating PnL of all open positions
{
   double floating=0.0; int count=0;
   PositionSummary(floating, count);
   return floating;
}

double EffectiveCycleLossLimit()
{
   double limit = (InpUseCycleLoss ? InpCycleLossLimit : 0.0);
   if(InpMaxCycleRiskPct > 0.0)
   {
      double base = (gCycleStartEquity > 0.0 ? gCycleStartEquity
                                             : AccountInfoDouble(ACCOUNT_EQUITY));
      double pctLimit = base * InpMaxCycleRiskPct / 100.0;
      if(pctLimit > 0.0 && (limit <= 0.0 || pctLimit < limit)) limit = pctLimit;
   }
   return limit;
}

bool CycleLossHit(double net)
{
   double limit = EffectiveCycleLossLimit();
   return(limit > 0.0 && net <= -limit);
}

double DailyLossLimit()
{
   if(InpMaxDailyLossPct <= 0.0) return 0.0;
   double base = (gDayStartBalance > 0.0 ? gDayStartBalance
                                        : AccountInfoDouble(ACCOUNT_BALANCE));
   return base * InpMaxDailyLossPct / 100.0;
}
 
double DailyRealized()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);
   double fallback = (dayStart == gDayStart ? gDailyPnL : 0.0);
 
   if(dayStart != gDayStart)          // new trading day
   {
      gDayStart     = dayStart;
      gDayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      gHaltedToday  = false;
      gConsecutiveLosses = 0;
      PruneBankDeals();
   }
 
   double sum = 0.0;
   if(!HistorySelect(dayStart, TimeCurrent()+1))
   {
      gBankScanFailed = true; gBankHistoryDirty = true;
      return fallback;
   }
   ClearBankScope(BANK_DAY);
   int td = HistoryDealsTotal();
   for(int i=0; i<td; i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if(!IsAccountingDeal(t)) continue;
      datetime time = (datetime)HistoryDealGetInteger(t,DEAL_TIME);
      if(time < dayStart) continue;
      double net = DealNet(t);
      int bankIdx = BankDealIndex(t);
      if(bankIdx < 0) return fallback;
      ApplyBankDeal(bankIdx, BANK_DAY, dayStart, time, net);
      sum += net;
   }
   return(gBankScanFailed ? fallback : sum);
}

datetime CurrentMonthStart()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.day = 1; dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

double MonthlyProfitTarget()
{
   if(!InpUseMonthlyCapitalTarget) return 0.0;
   return InpMonthlyCapital * (InpMonthlyCapitalMultiple - 1.0);
}

double MonthlyRealized()
{
   datetime monthStart = CurrentMonthStart();
   double fallback = (monthStart == gMonthStart ? gMonthlyPnL : 0.0);
   if(monthStart != gMonthStart)
   {
      gMonthStart = monthStart;
      gHaltedMonth = false;
      PruneBankDeals();
   }

   double sum = 0.0;
   if(!HistorySelect(monthStart, TimeCurrent()+1))
   {
      gBankScanFailed = true; gBankHistoryDirty = true;
      return fallback;
   }
   ClearBankScope(BANK_MONTH);
   int td = HistoryDealsTotal();
   for(int i=0; i<td; i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if(!IsAccountingDeal(t)) continue;
      datetime time = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
      if(time < monthStart) continue;
      double net = DealNet(t);
      int bankIdx = BankDealIndex(t);
      if(bankIdx < 0) return fallback;
      ApplyBankDeal(bankIdx, BANK_MONTH, monthStart, time, net);
      sum += net;
   }
   return(gBankScanFailed ? fallback : sum);
}
 
//--- true when it's Friday and server time is at/after the cutoff hour
bool IsFridayCutoff()
{
   if(!InpUseFridayStop) return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return(dt.day_of_week == FRIDAY && dt.hour >= InpFridayCutHour);
}
 
//--- this EA's realized PnL since the broker week open (excludes the current
//--- cycle so it reflects profit already banked this week before now).
double WeeklyRealized()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   // back up to the most recent Sunday 00:00 (broker week open)
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);
   datetime weekStart = dayStart - (datetime)dt.day_of_week*86400;  // Sunday = day_of_week 0
 
   double sum = 0.0;
   if(HistorySelect(weekStart, TimeCurrent()+1))
   {
      int td = HistoryDealsTotal();
      for(int i=0; i<td; i++)
      {
         ulong t = HistoryDealGetTicket(i);
         if(t == 0) continue;
         if(!IsAccountingDeal(t)) continue;
         datetime dtime = (datetime)HistoryDealGetInteger(t,DEAL_TIME);
         if(dtime < weekStart) continue;
         if(IsCurrentCycleDeal(t)) continue;                // exclude only the current cycle's own deals
         sum += DealNet(t);
      }
   }
   return sum;
}

double CachedWeeklyRealized()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   datetime dayStart = StructToTime(dt);
   datetime weekStart = dayStart - (datetime)dt.day_of_week*86400;
   if(gWeeklyCacheWeek != weekStart || gWeeklyCacheCycle != gCycleStart)
   {
      gWeeklyCacheWeek = weekStart;
      gWeeklyCacheCycle = gCycleStart;
      gWeeklyCacheValue = WeeklyRealized();
   }
   return gWeeklyCacheValue;
}
bool IsDelPending(ulong ticket)
{
   uint now = RequestClockMs();
   for(int i=0;i<ArraySize(gDelTk);i++)
      if(gDelTk[i]==ticket) return((now - gDelMs[i]) < (uint)InpCloseRetryMs);
   return false;
}
void MarkDelPending(ulong ticket)
{
   uint now = RequestClockMs();
   for(int i=0;i<ArraySize(gDelTk);i++) if(gDelTk[i]==ticket){ gDelMs[i]=now; return; }
   int n=ArraySize(gDelTk); ArrayResize(gDelTk,n+1); ArrayResize(gDelMs,n+1);
   gDelTk[n]=ticket; gDelMs[n]=now;
}
//--- drop delete-guard entries whose order is already gone
void SweepDelPending()
{
   for(int i=ArraySize(gDelTk)-1;i>=0;i--)
      if(!OrderSelect(gDelTk[i]))
      {
         int last=ArraySize(gDelTk)-1;
         gDelTk[i]=gDelTk[last]; gDelMs[i]=gDelMs[last];
         ArrayResize(gDelTk,last); ArrayResize(gDelMs,last);
      }
}
 
void CancelAllPending(bool guardFailed=false)
{
   SweepDelPending();
   trade.SetAsyncMode(InpAsyncClose);      // dispatch all deletes together
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!IsManagedOrderSelected()) continue;
      if(IsDelPending(t)) continue;         // delete already in flight - don't spam
      bool deleted=DeleteOrderSafe(t);
      if(deleted || guardFailed) MarkDelPending(t);
   }
   trade.SetAsyncMode(false);
}
 
int CountMyPositions()
{
   int c = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(IsManagedPositionSelected()) c++;
   }
   return c;
}
 
int CountMyPendings()
{
   int c = 0;
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(IsManagedOrderSelected()) c++;
   }
   return c;
}
 
//+------------------------------------------------------------------+
//| TRADING SESSION FILTER                                           |
//+------------------------------------------------------------------+
bool GetSessionToday(int &secFrom, int &secTo)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   ENUM_DAY_OF_WEEK dow = (ENUM_DAY_OF_WEEK)dt.day_of_week;
 
   datetime f, t;
   bool got = false;
   int mn = 0, mx = 0;
 
   for(uint idx=0; idx<8; idx++)                  // brokers may list several
   {
      if(!SymbolInfoSessionTrade(_Symbol, dow, idx, f, t)) break;
      int fi = (int)f, ti = (int)t;
      if(!got) { mn = fi; mx = ti; got = true; }
      else     { if(fi < mn) mn = fi; if(ti > mx) mx = ti; }
   }
   if(!got) return false;                         // weekend / holiday
   secFrom = mn; secTo = mx;
   return true;
}
 
bool IsInsideRawTradeSession(int nowSec)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   ENUM_DAY_OF_WEEK dow = (ENUM_DAY_OF_WEEK)dt.day_of_week;
   for(uint idx=0; idx<8; idx++)
   {
      datetime f, t;
      if(!SymbolInfoSessionTrade(_Symbol, dow, idx, f, t)) break;
      int from = (int)f, to = (int)t;
      if(from == to) return true;
      if(from < to && nowSec >= from && nowSec <= to) return true;
      if(from > to && (nowSec >= from || nowSec <= to)) return true;
   }
   return false;
}

bool ComputeSessionAllowsNewCycle()
{
   if(!InpUseSessionFilter) { gSessTxt = "filter off"; return true; }
 
   int f, t;
   if(!GetSessionToday(f, t)) { gSessTxt = "no session today"; return false; }
 
   const int DAY = 86400;
   int len   = (t > f ? t - f : DAY - f + t);     // handles sessions over midnight
   int delay = InpStartDelayMin * 60;
   int buf   = (int)(InpEndBufferHours * 3600.0);
 
   if(len <= delay + buf)                         // window would be empty
   {
      gSessTxt = "window too small";
      return false;
   }
 
   int s = (f + delay) % DAY;                     // window opens
   int e = t - buf;                               // window closes
   while(e < 0) e += DAY;
   e %= DAY;
 
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int now = dt.hour*3600 + dt.min*60 + dt.sec;
 
   bool insideWindow = (s <= e ? (now >= s && now <= e)
                         : (now >= s || now <= e));   // wraps midnight
 
   bool rawSessionOpen = IsInsideRawTradeSession(now);
   bool inside = insideWindow && rawSessionOpen;

   gSessTxt = StringFormat("%02d:%02d-%02d:%02d %s",
                           s/3600, (s%3600)/60, e/3600, (e%3600)/60,
                           inside ? "OPEN" : (insideWindow ? "BREAK" : "SHUT"));
   return inside;
}

bool SessionAllowsNewCycle()
{
   static datetime cachedAt = 0;
   static bool cachedResult = false;
   static string cachedText = "";
   datetime now = TimeCurrent();
   if(now == cachedAt)
   {
      gSessTxt = cachedText;
      return cachedResult;
   }
   cachedAt = now;
   cachedResult = ComputeSessionAllowsNewCycle();
   cachedText = gSessTxt;
   return cachedResult;
}

//--- When Friday stop is enabled, hold new cycles briefly after the broker's
//--- Monday symbol-session opens. Existing cycles are not affected.
bool IsMondayStartDelay()
{
   if(!InpUseFridayStop || InpMondayStartDelayMin <= 0) return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week != MONDAY) return false;

   int nowSec = dt.hour*3600 + dt.min*60 + dt.sec;
   int sessionFrom = 0, sessionTo = 0;
   int mondayOpenSec = 0;
   if(GetSessionToday(sessionFrom, sessionTo))
      mondayOpenSec = sessionFrom;

   int delaySec = InpMondayStartDelayMin*60;
   if(delaySec >= 86400-mondayOpenSec)
      return (nowSec >= mondayOpenSec);
   return(nowSec >= mondayOpenSec && nowSec < mondayOpenSec+delaySec);
}

//+------------------------------------------------------------------+
//| Cycle reset: fire ALL exits at once, then re-center when flat    |
//+------------------------------------------------------------------+
string DashboardResetBlockReason()
{
   if(!gInit || gRecoveryBlocked) return "Reset unavailable: cycle initialization/recovery is unresolved.";
   if(gAwaitFlat || gExposureBatchActive) return "Reset unavailable: cycle cleanup or order submission is in progress.";
   if(gDashboardResetPending) return "Reset pending: cancelling orders and confirming a flat basket.";
   for(int i=PositionsTotal()-1; i>=0; i--)
      if(PositionGetTicket(i) > 0 && IsCyclePositionSelected())
         return "Reset blocked: an open cycle position exists. No positions will be closed by this button.";
   for(int i=OrdersTotal()-1; i>=0; i--)
      if(OrderGetTicket(i) > 0 && IsCycleOrderSelected() && !IsManagedOrderSelected())
         return "Reset blocked: a cycle pending order has manual management disabled.";
   return "";
}

bool RequestDashboardCycleReset()
{
   if(gDashboardResetPending) return false;
   RefreshManualTradeIntegration();
   string reason=DashboardResetBlockReason();
   if(reason != "")
   {
      if(InpEnableJournalLogs) Print(reason);
      return false;
   }
   gDashboardResetPending=true;
   gDashboardResetSettleUntil=0;
   gDashboardResetRetryAfter=0;
   gDashboardPaintPending=true;
   gDashboardLastDraw=0;
   gBankHistoryDirty=true;
   SavePersistentState(true);
   return true;
}

void ClearCycleRuntimeCaches()
{
   ArrayResize(gGridInitialBuySeen,0); ArrayResize(gGridInitialSellSeen,0);
   ArrayResize(gGridPosBuy,0); ArrayResize(gGridPosSell,0);
   ArrayResize(gGridPendBuy,0); ArrayResize(gGridPendSell,0);
   ArrayResize(gGridPendBuyTk,0); ArrayResize(gGridPendSellTk,0);
   ArrayResize(gGridPendBuyVol,0); ArrayResize(gGridPendSellVol,0);
   ArrayResize(gGridPendBuyPrice,0); ArrayResize(gGridPendSellPrice,0);
   ArrayResize(gGridLevelBuyPrice,0); ArrayResize(gGridLevelSellPrice,0);
   ArrayResize(gTsTk,0); ArrayResize(gTsLast,0);
   ArrayResize(gClosingTk,0); ArrayResize(gClosingMs,0);
   ArrayResize(gDelTk,0); ArrayResize(gDelMs,0);
   gGridPriceCacheCenter=0.0; gGridPriceCacheCenterGap=0.0; gGridPriceCacheGap=0.0;
   gGridOpenVolume=0.0; gGridCachedExposureLots=0.0;
   gGridDirty=true; gGridWatchValid=false;
   gGridWatchBuyRemoveAsk=1.0e100; gGridWatchSellRemoveBid=-1.0e100;
   gGridWatchBuyActionAsk=-1.0e100; gGridWatchSellActionBid=1.0e100;
   gInitialGridForming=false; gInstantForm=false;
   gExposureBatchActive=false; gExposureBatchLots=0.0; gExposureBatchPendingMargin=0.0;
   gExposureBatchEquity=0.0; gExposureBatchLastExtra=0.0;
   gAltBuyDone=false; gAltSellDone=false; gBuyDepth=0; gSellDepth=0; gDblArmed=false;
   ResetCenterReversalMultiplier();
   gDDArmed=false; gDDEligible=false; gDDMarkNet=0.0; gCycleStartEquity=0.0;
   gResetRetryMs=0; gResetStuckMs=0; gResetRetryStarted=false;
   gFlatSettling=false; gSettleUntil=0; gLossExitPending=false;
   ResetCycleAccounting();
   InvalidatePositionSnapshot();
   gPositionSnapshotCount=0; gPositionSnapshotFloating=0.0;
   gPositionSnapshotBuy=0.0; gPositionSnapshotSell=0.0; gPositionSnapshotVolume=0.0;
   gPositionSnapshotManualBuyCount=0; gPositionSnapshotManualSellCount=0;
   gDashboardHistoryReady=false; gDashboardDetailsReady=false;
   ArrayResize(gDashboardPositions,0); ArrayResize(gDashboardRows,0); ArrayResize(gDashboardDetails,0);
   gDashboardSum=0.0; gDashboardBuy=0.0; gDashboardSell=0.0; gDashboardExited=0;
   gDashboardPage=0; gDashboardPageRevision=0; gDashboardPaintPending=true; gDashboardLastDraw=0;
   gCycleBoundaryRetryAfter=0; gManualRefreshDirty=true;
}

void ManageDashboardCycleReset(double bid,double ask)
{
   if(!gDashboardResetPending) return;
   // Never turn a pending-only reset into a position-closing action. A stop
   // can fill during cancellation; abort and leave its original cycle intact.
   bool exposed=false;
   for(int i=PositionsTotal()-1; i>=0; i--)
      if(PositionGetTicket(i) > 0 && IsCyclePositionSelected()) { exposed=true; break; }
   for(int i=OrdersTotal()-1; !exposed && i>=0; i--)
      if(OrderGetTicket(i) > 0 && IsCycleOrderSelected() && !IsManagedOrderSelected()) exposed=true;
   if(exposed || gRecoveryBlocked || gAwaitFlat)
   {
      gDashboardResetPending=false; gDashboardResetSettleUntil=0; gDashboardResetRetryAfter=0;
      gGridDirty=true; gGridWatchValid=false; gDashboardPaintPending=true; gDashboardLastDraw=0;
      SavePersistentState(true);
      if(InpEnableJournalLogs) Print("Dashboard reset aborted: exposure or another cleanup appeared; the existing cycle is retained.");
      return;
   }
   CancelAllPending(true);
   if(CountMyPendings() > 0) { gDashboardResetSettleUntil=0; return; }
   datetime now=TimeCurrent();
   if(gDashboardResetSettleUntil == 0)
   {
      gDashboardResetSettleUntil=now+(InpReformDelaySec > 0 ? InpReformDelaySec : 1);
      return;
   }
   if(now < gDashboardResetSettleUntil || now < gDashboardResetRetryAfter) return;
   gDashboardResetRetryAfter=now+1;
   gBankHistoryDirty=true;
   RefreshBankAccounting();
   if(gBankHistoryDirty || gBankScanFailed) return;
   double result=0.0;
   if(gCycleOpen && !ReadFlatCycleHistory(gCycleStart,gCycleStartMsc,result,true)) return;
   // Recheck live inventory after history/API calls, before clearing identity.
   for(int i=PositionsTotal()-1; i>=0; i--)
      if(PositionGetTicket(i) > 0 && IsCyclePositionSelected()) return;
   for(int i=OrdersTotal()-1; i>=0; i--)
      if(OrderGetTicket(i) > 0 && IsCycleOrderSelected()) return;
   bool completed=(gCycleOpen && (ArraySize(gResetPositionIds) > 0 || MathAbs(result) > 1e-8));
   if(completed)
   {
      bool loss=(result < 0.0);
      if(loss) gConsecutiveLosses++; else gConsecutiveLosses=0;
      if(InpMaxConsecutiveLosses > 0 && gConsecutiveLosses >= InpMaxConsecutiveLosses) gHaltedToday=true;
      int side=((bid+ask)/2.0 > gCenter ? 1 : ((bid+ask)/2.0 < gCenter ? -1 : 0));
      gLastExitSide=side;
      gNextCycleQuick=(InpUseAgainstTrend && gTrendDir != 0 && side != 0 && side == -gTrendDir);
      double cooldown=InpCycleCooldownMin;
      if(loss && InpLossCooldownMin > cooldown) cooldown=InpLossCooldownMin;
      datetime until=now+(int)MathRound(cooldown*60.0);
      if(until > gCooldownUntil) gCooldownUntil=until;
      CapturePushCycleExit();
      QueuePushCycleExit();
   }
   ClearCycleRuntimeCaches(); // retain daily/monthly ledger, ownership and old-position exclusions
   gCycleOpen=false;
   gCenter=NormPrice((bid+ask)/2.0); gLastMid=(bid+ask)/2.0; gCycleStart=now;
   gDashboardResetPending=false; gDashboardResetSettleUntil=0; gDashboardResetRetryAfter=0;
   SavePersistentState(true);
   if(InpEnableJournalLogs) PrintFormat("Dashboard reset complete: fresh center %.5f. The next cycle still obeys cooldown/session/news/risk guards.",gCenter);
}

bool ReconcileExternallyFlatCycle(int openPositions)
{
   if(!gCycleOpen || gAwaitFlat || gFlatSettling || gExposureBatchActive) return false;
   bool exposed = (openPositions > 0);
   for(int i=OrdersTotal()-1; !exposed && i>=0; i--)
      if(OrderGetTicket(i) > 0 && IsCycleOrderSelected()) exposed=true;
   if(exposed)
   {
      gFlatCyclePending=false;
      gFlatCycleRetryAfter=0;
      return false;
   }
   datetime now=TimeCurrent();
   if(now < gFlatCycleRetryAfter) return gFlatCyclePending;
   gFlatCycleRetryAfter=now+1;
   if(!HistorySelect(gCycleStart,now+1))
   {
      gBankScanFailed=true; gBankHistoryDirty=true; gFlatCyclePending=true;
      return true;
   }

   // A vanished position can precede its closing deal callback. Verify each
   // observed position's full entry/exit volume before retiring its bank.
   int total=HistoryDealsTotal();
   for(int i=0; i<total; i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(ticket == 0) { gBankHistoryDirty=true; gFlatCyclePending=true; return true; }
      if(!IsAccountingDeal(ticket) || !IsCurrentCycleDeal(ticket)) continue;
      long type=HistoryDealGetInteger(ticket,DEAL_TYPE);
      if(type == DEAL_TYPE_BUY || type == DEAL_TYPE_SELL)
         RememberCyclePosition(HistoryDealGetInteger(ticket,DEAL_POSITION_ID));
   }
   int count=ArraySize(gResetPositionIds);
   if(count == 0 && !gBankHistoryDirty)
   {
      gFlatCyclePending=false;
      return false; // an unfilled/rejected initial grid is not a completed traded cycle
   }
   gFlatCyclePending=true;
   if(gBankHistoryDirty || count == 0) return true;
   double balance[];
   bool entered[];
   if(ArrayResize(balance,count) != count || ArrayResize(entered,count) != count) return true;
   ArrayInitialize(balance,0.0);
   ArrayInitialize(entered,false);
   for(int i=0; i<total; i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(!IsAccountingDeal(ticket) || !IsCurrentCycleDeal(ticket)) continue;
      long type=HistoryDealGetInteger(ticket,DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
      long id=HistoryDealGetInteger(ticket,DEAL_POSITION_ID);
      int lo=0, hi=count;
      while(lo < hi)
      {
         int mid=lo+(hi-lo)/2;
         if(gResetPositionIds[mid] < id) lo=mid+1; else hi=mid;
      }
      if(lo >= count || gResetPositionIds[lo] != id) return true;
      double volume=HistoryDealGetDouble(ticket,DEAL_VOLUME);
      long entry=HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(!MathIsValidNumber(volume) || volume <= 0.0) return true;
      if(entry == DEAL_ENTRY_IN) { balance[lo]+=volume; entered[lo]=true; }
      else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) balance[lo]-=volume;
      else return true;
   }
   for(int i=0; i<count; i++)
      if(!entered[i] || MathAbs(balance[i]) > 1e-8) return true;

   gBankHistoryDirty=true;
   gBankRetryAfter=0;
   RefreshBankAccounting();
   if(gBankHistoryDirty || gBankScanFailed) return true;
   double floating=0.0; int positions=0;
   InvalidatePositionSnapshot();
   PositionSummary(floating,positions);
   if(positions > 0) return true; // inventory changed while history was being reconciled
   for(int i=OrdersTotal()-1; i>=0; i--)
      if(OrderGetTicket(i) > 0 && IsCycleOrderSelected()) return true;
   if(InpEnableJournalLogs)
      PrintFormat("Externally flattened cycle completed: booked NET %.2f. Resetting cycle bank/state; daily/monthly history is retained.",gCycleRealized);
   CloseAllAndReset(gCycleRealized < 0.0);
   return true;
}

void RequestCloseAll()
{
   CloseAllMyPositions();   // one async burst - all positions exit together
   CancelAllPending();      // remove the untriggered legs
}
 
void CloseAllAndReset(bool lossExit=false)
{
   if(!gAwaitFlat)
   {
      if(lossExit) gConsecutiveLosses++;
      else         gConsecutiveLosses = 0;
      if(InpMaxConsecutiveLosses > 0 && gConsecutiveLosses >= InpMaxConsecutiveLosses)
      {
         gHaltedToday = true;
         if(InpEnableJournalLogs) PrintFormat("Consecutive-loss guard: %d losses; new cycles halted for today.", gConsecutiveLosses);
      }
   }

   // record which side price is on at the moment of exit (old center still set),
   // for the next cycle's last-exit-side rule
   int exitSide = 0;
   if(gLastMid > 0.0)
   {
      exitSide = (gLastMid > gCenter ? +1 : (gLastMid < gCenter ? -1 : 0));
      gLastExitSide = exitSide;
   }
   // against-trend exit: trend up but exited SELL side (or trend down + BUY side)
   // -> lock the NEXT cycle to the quick target (overrides everything).
   gNextCycleQuick = false;
   if(InpUseAgainstTrend && gTrendDir != 0 && exitSide != 0 && exitSide == -gTrendDir)
      gNextCycleQuick = true;
   gLossExitPending = lossExit;
   gResetRetryStarted = false;
   CaptureResetPositions();
   gAwaitFlat    = true;    // finalize once the server confirms everything gone
   gFlatSettling = false;   // start in phase 1 (reach flat)
   SavePersistentState(true);
   RequestCloseAll();
}
 
//--- Retry all remaining exposure without bypassing per-ticket request pacing.
//--- Newly arrived late-fill tickets have no guard and are handled immediately.
int ForceFlatten()
{
   int stillOpen=CountMyPositions();
   CloseAllMyPositions();
   CancelAllPending(true); // failed deletes also consume the existing retry interval
   return stillOpen;
}
 
void TryFinalizeReset(double bid, double ask)
{
   SweepClosePending();
   SweepDelPending();
 
   // PHASE 1: reach truly flat. Retry remaining tickets under the existing
   // request guards; an unseen late fill is not delayed by another ticket.
   if(!gFlatSettling)
   {
      if(CountMyPositions() > 0 || CountMyPendings() > 0)
      {
         uint now = RequestClockMs();
         bool firstTry = !gResetRetryStarted;
         if(firstTry) { gResetStuckMs = now; gResetRetryStarted = true; }
         if(firstTry || now - gResetRetryMs >= 300)
         {
            gResetRetryMs = now;
            CaptureResetPositions();
            int wasOpen = ForceFlatten();
            if(wasOpen > 0 && (now - gResetStuckMs) > 1500 && InpEnableJournalLogs)
               PrintFormat("Reset: force-closing %d lingering position(s) after exit (late fill / volatile).", wasOpen);
         }
         // Cleanup may already have confirmed flat on this tick.
         if(CountMyPositions() > 0 || CountMyPendings() > 0) return;
      }
 
      // Confirmed flat: clear only this cycle's bank/lock and redraw zero NET.
      // The next cycle captures a fresh precise boundary before placing orders.
      CapturePushCycleExit();
      gCycleStart = TimeCurrent();
      ResetCycleAccounting();
      gCycleOpen = false;
      ArrayResize(gClosingTk, 0); ArrayResize(gClosingMs, 0);
      ArrayResize(gDelTk, 0);     ArrayResize(gDelMs, 0);
      gFlatSettling = true;
      gResetRetryStarted = false;
      gSettleUntil  = TimeCurrent() + (InpReformDelaySec > 0 ? InpReformDelaySec : 0);
      SavePersistentState(true);
      DrawDashboard(bid, ask);
      return;
   }
 
   // PHASE 2: settle pause elapsed -> lock center at the CURRENT price (whatever
   // it is) and complete the re-arm so the new straddle can form.
   if(TimeCurrent() < gSettleUntil) return;
 
   // guard: if a stray order slipped in during the settle pause, force flat and
   // restart phase 1 rather than forming a new cycle on top of a leftover.
   if(CountMyPositions() > 0 || CountMyPendings() > 0)
   {
      CaptureResetPositions();
      ForceFlatten();
      gFlatSettling = false;   // drop back to phase 1 to confirm flat again
      gResetRetryStarted = false;
      return;
   }

   // All close deals and late-fill cleanup are now settled. Evaluate the daily
   // target only at this completed-cycle boundary, never during an active cycle.
   QueuePushCycleExit();
   gDailyPnL = DailyRealized();
   if(InpUseDailyTarget && gDailyPnL >= InpDailyTarget && !gHaltedToday)
   {
      gHaltedToday = true;
      if(InpEnableJournalLogs) PrintFormat("Completed-cycle daily target reached: realized %.2f >= %.2f. No new cycle today.",
                  gDailyPnL, InpDailyTarget);
   }
 
   gCenter    = NormPrice((bid+ask)/2.0);
   gGridDirty = true;
   gCycleStart = TimeCurrent();              // the next actual cycle captures its own precise boundary
   gAwaitFlat    = false;
   gFlatSettling = false;
   gCycleOpen = false;         // the entry path reforms only when every guard allows it
   gInitialGridForming = false;
   gAltBuyDone      = false;
   gAltSellDone     = false;
   gBuyDepth  = 0;             // fresh cycle -> depth doubling resets
   gSellDepth = 0;
   gDblArmed  = false;
   ResetCenterReversalMultiplier();
   gDDArmed = false; gDDEligible = false; gDDMarkNet = 0.0;
   gCycleRealized = 0.0;
   gCycleStartEquity = 0.0;
   gBankLockArmed = false;
   gBankLockPeak = 0.0;
   gBankLockFloor = 0.0;
   gBankLockRetainSide = 0;
   // Use the longest cooldown required by the completed cycle.
   double coolMin = InpCycleCooldownMin;
   if(gLossExitPending && InpLossCooldownMin > coolMin)
      coolMin = InpLossCooldownMin;
   gCooldownUntil = TimeCurrent() + (int)MathRound(coolMin*60.0);
   gLossExitPending = false;
   SavePersistentState(true);
}
 
//+------------------------------------------------------------------+
//| Broker-side trailing SL (throttled: step + rate limit, anti-HFT)  |
//+------------------------------------------------------------------+
bool FreshPrice(double &bid, double &ask)
{
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk)) return false;
   bid = tk.bid; ask = tk.ask;
   InvalidatePositionSnapshot();
   return (bid > 0 && ask > 0);
}

uint RequestClockMs()
{
   if(!gIsTester) return GetTickCount();
   long ms = (long)TimeCurrent()*1000;
   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick) && tick.time_msc >= ms && tick.time_msc < ms+1000)
      ms = tick.time_msc;
   // Unsigned subtraction preserves elapsed intervals across the 32-bit wrap.
   return (uint)ms;
}
 
//+------------------------------------------------------------------+
//| BROKER-SIDE TRAILING STOP (rate-capped, anti-HFT)               |
//|  Per filled order, measured from its OPEN (fill) price:          |
//|    - profit < Arm            -> no stop yet                       |
//|    - Arm .. TightenAt        -> SL = price - GapWide              |
//|    - profit >= TightenAt     -> SL = price - Gap                  |
//|  Real broker SL (PositionModify), ratchets forward only.         |
//|  Rate cap: at most ONE modify per second per position (anti-HFT).|
//+------------------------------------------------------------------+
// per-position modify tracking (parallel arrays, swept when a position closes)
ulong    gTsTk[];      // ticket
uint     gTsLast[];    // timestamp of last modify (ms)

uint StateSymbolHash()
{
   uint h = 2166136261;
   for(int i=0; i<StringLen(_Symbol); i++)
   {
      h ^= (uint)StringGetCharacter(_Symbol, i);
      h *= 16777619;
   }
   return h;
}

string StateKey(string field)
{
   return StringFormat("SNB.%I64d.%I64d.%u.%s",
                       AccountInfoInteger(ACCOUNT_LOGIN), InpMagic,
                       StateSymbolHash(), field);
}

bool StateWrite(string field, double value)
{
   int size=ArraySize(gStateCacheFields), lo=0, hi=size;
   while(lo < hi)
   {
      int mid=lo+(hi-lo)/2;
      if(StringCompare(gStateCacheFields[mid], field) < 0) lo=mid+1;
      else hi=mid;
   }
   bool found=(lo < size && gStateCacheFields[lo] == field);
   if(!gStateForceWrite && found && gStateCacheValues[lo] == value) return true;
   if(GlobalVariableSet(StateKey(field), value) <= 0) return false;
   if(!found)
   {
      if(ArrayResize(gStateCacheFields,size+1,128) < 0 ||
         ArrayResize(gStateCacheValues,size+1,128) < 0)
      {
         ArrayResize(gStateCacheFields,0); ArrayResize(gStateCacheValues,0);
         return true; // write succeeded; caching is optional
      }
      for(int i=size; i>lo; i--)
      {
         gStateCacheFields[i]=gStateCacheFields[i-1];
         gStateCacheValues[i]=gStateCacheValues[i-1];
      }
      gStateCacheFields[lo]=field;
   }
   gStateCacheValues[lo]=value;
   return true;
}

double StateValue(string field, bool &ok)
{
   string key = StateKey(field);
   if(!GlobalVariableCheck(key))
   {
      ok = false;
      return 0.0;
   }
   return GlobalVariableGet(key);
}

double StateValueOrDefault(string field, double fallback)
{
   string key = StateKey(field);
   if(!GlobalVariableCheck(key)) return fallback;
   return GlobalVariableGet(key);
}

bool StateWriteId(string field, ulong id)
{
   // Terminal globals are doubles; split 64-bit IDs to preserve every bit.
   bool ok = StateWrite(field+"h", (double)(id >> 32));
   return StateWrite(field+"l", (double)(id & (ulong)4294967295)) && ok;
}

ulong StateReadId(string field, bool &ok)
{
   double high = StateValue(field+"h", ok), low = StateValue(field+"l", ok);
   if(!ok || !MathIsValidNumber(high) || !MathIsValidNumber(low) ||
      high < 0 || low < 0 || high > 4294967295.0 || low > 4294967295.0 ||
      high != MathFloor(high) || low != MathFloor(low)) { ok = false; return 0; }
   ulong id = ((ulong)high << 32) | (ulong)low;
   if(id == 0) ok = false;
   return id;
}

void SaveMonthlyHaltState()
{
   if(gIsTester) return;
   bool ok = StateWrite("month", (double)gMonthStart);
   ok = StateWrite("mhalt", gHaltedMonth ? 1.0 : 0.0) && ok;
   GlobalVariablesFlush();
   if(!ok && InpEnableJournalLogs) Print("Monthly target halt persistence failed.");
}

void LoadMonthlyHaltState()
{
   gHaltedMonth = false;
   if(gIsTester || !InpUseMonthlyCapitalTarget) return;
   datetime savedMonth = (datetime)StateValueOrDefault("month", 0.0);
   if(savedMonth == gMonthStart)
      gHaltedMonth = (StateValueOrDefault("mhalt", 0.0) > 0.5);
}

bool ValidateConfiguration()
{
   if(InpIncludeManualTradesInCycle && InpMagic > 9007199254740991)
   {
      if(InpEnableJournalLogs) Print("Invalid input: manual-trade ownership requires InpMagic <= 9007199254740991 for exact terminal-global ownership claims.");
      return false;
   }
   if(InpUsePushNotifications && (InpPushNetBank || InpPushRealizedBank || InpPushDailyProfit) &&
      InpPushIntervalMin < 1)
   {
      if(InpEnableJournalLogs) Print("Invalid input: InpPushIntervalMin must be at least 1 minute when mobile push notifications are enabled.");
      return false;
   }
   if(InpMagic <= 0)                         { if(InpEnableJournalLogs) Print("Invalid input: InpMagic must be positive."); return false; }
   if(InpCenterSideGap <= 0.0 || InpGridGap <= 0.0)
                                               { if(InpEnableJournalLogs) Print("Invalid input: center-side and grid gaps must be greater than zero."); return false; }
   if(InpUseGridLotProgression)
   {
      if(InpProgressionOrdersPerSide < 1 || InpProgressionOrdersPerSide > 500 ||
         !MathIsValidNumber(InpGridInitialLot) || InpGridInitialLot <= 0.0 ||
         !MathIsValidNumber(InpGridLotMultiplier) || InpGridLotMultiplier < 1.0 || InpGridLotMultiplier > 100.0)
      {
         if(InpEnableJournalLogs) Print("Invalid input: grid progression requires 1..500 levels per side, a positive initial lot, and a multiplier between 1 and 100.");
         return false;
      }
   }
   else
   {
      if(InpOrdersPerSide < 1 || InpOrdersPerSide > 500)
                                               { if(InpEnableJournalLogs) Print("Invalid input: InpOrdersPerSide must be between 1 and 500."); return false; }
      if(InpTierSize < 1 || InpTierSize > InpOrdersPerSide)
                                               { if(InpEnableJournalLogs) Print("Invalid input: InpTierSize must be within the grid size."); return false; }
      if(InpLotNear <= 0.0 || InpLotMid <= 0.0 || InpLotFar <= 0.0)
                                               { if(InpEnableJournalLogs) Print("Invalid input: all tier lots must be positive."); return false; }
   }
   if(InpUseTrailingStop && (InpArmDistance < 0.0 || InpTrailGapWide <= 0.0 || InpTrailGap <= 0.0 ||
      InpTrailTightenAt < InpArmDistance))     { if(InpEnableJournalLogs) Print("Invalid input: trailing distances are inconsistent."); return false; }
   if(InpDisasterSL < 0.0 || InpRefillBuffer < 0.0 || InpMaxSlippage < 0.0)
                                               { if(InpEnableJournalLogs) Print("Invalid input: stop/refill/slippage distances cannot be negative."); return false; }
   if(InpMaxPlacePerTick < 1 || InpCloseRetryMs < 100 || InpEntryBackoffSec < 1)
                                               { if(InpEnableJournalLogs) Print("Invalid input: placement/retry limits are too small."); return false; }
   if(InpInitialPlacePerTick < 0 || InpInitialPlacePerTick > 1000)
                                               { if(InpEnableJournalLogs) Print("Invalid input: InpInitialPlacePerTick must be between 0 and 1000."); return false; }
   if(InpNetBankTarget <= 0.0 || (InpUseCycleLoss && InpCycleLossLimit <= 0.0))
                                               { if(InpEnableJournalLogs) Print("Invalid input: cycle profit/loss limits must be positive."); return false; }
   if(InpUseBankProfitLock && (InpBankLockArmProfit < 0.0 ||
      InpBankLockMinProfit < 0.0 || InpBankLockGiveback <= 0.0))
                                               { if(InpEnableJournalLogs) Print("Invalid input: bank-lock arm/minimum profit cannot be negative and giveback must be positive."); return false; }
   if(InpUseFloatingLoss && InpFloatingLossLimit <= 0.0)
                                               { if(InpEnableJournalLogs) Print("Invalid input: InpFloatingLossLimit must be positive when enabled."); return false; }
   if(InpUseDailyTarget && InpDailyTarget <= 0.0)
                                               { if(InpEnableJournalLogs) Print("Invalid input: InpDailyTarget must be positive when enabled."); return false; }
   if(InpUseMonthlyCapitalTarget &&
      (InpMonthlyCapital <= 0.0 || InpMonthlyCapitalMultiple <= 1.0))
                                               { if(InpEnableJournalLogs) Print("Invalid input: monthly capital must be positive and its multiple must be greater than 1."); return false; }
   if(InpCycleCooldownMin < 0.0 || InpLossCooldownMin < 0.0 || InpReformDelaySec < 0)
                                               { if(InpEnableJournalLogs) Print("Invalid input: cooldown/reform delays cannot be negative."); return false; }
   if(InpTrendCandles < 1)
                                               { if(InpEnableJournalLogs) Print("Invalid input: trend candle count must be positive."); return false; }
   if(InpUseNewsFilter && (StringLen(InpNewsCurrency) < 3 || InpNewsMinutesBefore < 0 ||
      InpNewsMinutesAfter < 0 || (InpNewsMinutesBefore == 0 && InpNewsMinutesAfter == 0)))
                                               { if(InpEnableJournalLogs) Print("Invalid input: high-impact news-filter settings are inconsistent."); return false; }
   if(UseDepthDoubling() && (InpDblTriggerIdx < 1 || !MathIsValidNumber(InpDblMultiplier) || InpDblMultiplier < 1.0))
                                               { if(InpEnableJournalLogs) Print("Invalid input: depth-doubling settings are inconsistent."); return false; }
   if(InpUseCenterReversalMultiplier &&
      ((InpReversalTriggerMode != REVERSAL_TRIGGER_FILLS && InpReversalTriggerMode != REVERSAL_TRIGGER_FLOATING_LOSS) ||
       !MathIsValidNumber(InpReversalMultiplier) || InpReversalMultiplier < 1.0 || InpReversalMultiplier > 100.0 ||
       !MathIsValidNumber(InpReversalMaxLot) || InpReversalMaxLot < 0.0 ||
       (InpReversalMaxLot > 0.0 && InpReversalMaxLot < gSymbolVolumeMin)))
                                               { if(InpEnableJournalLogs) Print("Invalid input: center-reversal trigger mode, multiplier (1..100), or lot cap is invalid."); return false; }
   if(InpUseCenterReversalMultiplier && InpReversalTriggerMode == REVERSAL_TRIGGER_FLOATING_LOSS &&
      (!MathIsValidNumber(InpReversalFloatingLoss) || InpReversalFloatingLoss <= 0.0))
                                               { if(InpEnableJournalLogs) Print("Invalid input: floating-loss multiplier threshold must be positive, in account currency."); return false; }
   if(InpUseCenterReversalMultiplier && InpReversalTriggerMode == REVERSAL_TRIGGER_FILLS &&
      (InpReversalTriggerOrders < 1 || InpReversalTriggerOrders > GridOrdersPerSide() ||
       (InpReversalLevels != REVERSAL_LEVELS_ALTERNATE && InpReversalLevels != REVERSAL_LEVELS_ALL) ||
       InpReversalMaxSwitches < 1 || InpReversalMaxSwitches > 30))
                                               { if(InpEnableJournalLogs) Print("Invalid input: original center-reversal filled-level count, level mode, or switch cap is invalid."); return false; }
   if(InpDDFraction <= 0.0 || InpDDFraction > 1.0)
                                               { if(InpEnableJournalLogs) Print("Invalid input: InpDDFraction must be in (0, 1]."); return false; }
   if(InpStartDelayMin < 0 || InpEndBufferHours < 0.0 || InpFridayCutHour < 0 || InpFridayCutHour > 23 ||
      InpMondayStartDelayMin < 0 ||
      InpFridayMinLoss < 0.0 || InpFridayWeeklyFrac < 0.0)
                                               { if(InpEnableJournalLogs) Print("Invalid input: session/Friday timing is inconsistent."); return false; }
   if(InpMaxCycleRiskPct < 0.0 || InpMaxCycleRiskPct > 100.0 ||
      InpMaxDailyLossPct < 0.0 || InpMaxDailyLossPct > 100.0 ||
      InpMaxExposureLots < 0.0 || InpMinMarginLevelPct < 0.0 || InpExitCostPerLot < 0.0 ||
      InpMaxConsecutiveLosses < 0)
                                               { if(InpEnableJournalLogs) Print("Invalid input: safety limits cannot be negative or exceed 100% risk."); return false; }
   return true;
}

void SavePersistentState(bool flush)
{
   if(gIsTester || !InpPersistState || gRecoveryBlocked) return;
   if(!flush && gLastStateSave > 0 && TimeCurrent() - gLastStateSave < 5) return;

   // A durable boundary still flushes to disk, but unchanged fields need not
   // be rewritten. Keep the first/hourly full refresh for recovery/ownership.
   gStateForceWrite = (gLastStateFullSave == 0 || TimeCurrent()-gLastStateFullSave >= 3600);
   bool fullWrite = gStateForceWrite;
   bool ok = true;
   ok = StateWrite("ok", 0.0) && ok; // validity marker is committed last
   if(!ok)
   {
      gStateForceWrite=false;
      if(InpEnableJournalLogs) Print("State persistence failed before opening the snapshot; previous state retained.");
      return;
   }
   ok = StateWrite("ver", 133.0) && ok; // includes a recoverable pending-only dashboard reset
   ok = StateWrite("uireset",gDashboardResetPending ? 1.0 : 0.0) && ok;
   ok = StateWrite("manon", InpIncludeManualTradesInCycle ? 1.0 : 0.0) && ok;
   ok = StateWrite("manmanage", (InpIncludeManualTradesInCycle && InpManageManualTrades) ? 1.0 : 0.0) && ok;
   if(fullWrite || gManualIdentityDirty)
   {
      ok = StateWrite("mann", ArraySize(gManualTrades)) && ok;
      for(int i=0; i<ArraySize(gManualTrades); i++)
      {
         string field="man"+IntegerToString(i);
         ok = StateWriteId(field, (ulong)gManualTrades[i].id) && ok;
         ok = StateWrite(field+"c", (double)gManualTrades[i].cycle) && ok;
         if(fullWrite)
         {
            string owner=ManualOwnershipKey(gManualTrades[i].id);
            if(GlobalVariableCheck(owner)) GlobalVariableGet(owner); // keep the terminal's ownership claim alive with the snapshot
         }
      }
   }
   ok = StateWrite("trailing", InpUseTrailingStop ? 1.0 : 0.0) && ok;
   ok = StateWrite("gpon", InpUseGridLotProgression ? 1.0 : 0.0) && ok;
   ok = StateWrite("rvon", InpUseCenterReversalMultiplier ? 1.0 : 0.0) && ok;
   ok = StateWrite("dpon", UseDepthDoubling() ? 1.0 : 0.0) && ok;
   if(UseDepthDoubling())
   {
      ok = StateWrite("dpidx", InpDblTriggerIdx) && ok;
      ok = StateWrite("dpcntr", InpDblRequireCenter ? 1.0 : 0.0) && ok;
      ok = StateWrite("dpmult", InpDblMultiplier) && ok;
   }
   ok = StateWrite("gap", InpGridGap) && ok;
   ok = StateWrite("cgap", InpCenterSideGap) && ok;
   ok = StateWrite("n", GridOrdersPerSide()) && ok;
   ok = StateWrite("tier", InpTierSize) && ok;
   ok = StateWrite("ln", InpLotNear) && ok;
   ok = StateWrite("lm", InpLotMid) && ok;
   ok = StateWrite("lf", InpLotFar) && ok;
   if(InpUseGridLotProgression)
   {
      ok = StateWrite("gpstart", InpGridInitialLot) && ok;
      ok = StateWrite("gpmult", InpGridLotMultiplier) && ok;
   }

   ok = StateWrite("ctr", gCenter) && ok;
   ok = StateWrite("start", (double)gCycleStart) && ok;
   ok = StateWrite("cms", (double)gCycleStartMsc) && ok;
   if(fullWrite || gCycleIdentityDirty)
   {
      ok = StateWrite("cxpn", ArraySize(gCycleExcludedPositions)) && ok;
      ok = StateWrite("cxdn", ArraySize(gCycleExcludedDeals)) && ok;
      ok = StateWrite("crpn", ArraySize(gResetPositionIds)) && ok;
      for(int i=0; i<ArraySize(gCycleExcludedPositions); i++)
         ok = StateWriteId("cxp"+IntegerToString(i), (ulong)gCycleExcludedPositions[i]) && ok;
      for(int i=0; i<ArraySize(gCycleExcludedDeals); i++)
         ok = StateWriteId("cxd"+IntegerToString(i), gCycleExcludedDeals[i]) && ok;
      for(int i=0; i<ArraySize(gResetPositionIds); i++)
         ok = StateWriteId("crp"+IntegerToString(i), (ulong)gResetPositionIds[i]) && ok;
   }
   ok = StateWrite("open", gCycleOpen ? 1.0 : 0.0) && ok;
   ok = StateWrite("await", gAwaitFlat ? 1.0 : 0.0) && ok;
   ok = StateWrite("settling", gFlatSettling ? 1.0 : 0.0) && ok;
   ok = StateWrite("settleto", (double)gSettleUntil) && ok;
   ok = StateWrite("cool", (double)gCooldownUntil) && ok;
   ok = StateWrite("ceq", gCycleStartEquity) && ok;
   ok = StateWrite("blarm", gBankLockArmed ? 1.0 : 0.0) && ok;
   ok = StateWrite("blpeak", gBankLockPeak) && ok;
   ok = StateWrite("blfloor", gBankLockFloor) && ok;
   ok = StateWrite("blopp", UseBankLockCloseOpposite() ? 1.0 : 0.0) && ok;
   ok = StateWrite("blside", gBankLockRetainSide) && ok;
   ok = StateWrite("day", (double)gDayStart) && ok;
   ok = StateWrite("dbal", gDayStartBalance) && ok;
   ok = StateWrite("halt", gHaltedToday ? 1.0 : 0.0) && ok;
   ok = StateWrite("month", (double)gMonthStart) && ok;
   ok = StateWrite("mhalt", gHaltedMonth ? 1.0 : 0.0) && ok;
   ok = StateWrite("lossx", gLossExitPending ? 1.0 : 0.0) && ok;
   ok = StateWrite("losses", gConsecutiveLosses) && ok;

   ok = StateWrite("lastside", gLastExitSide) && ok;
   ok = StateWrite("nextq", gNextCycleQuick ? 1.0 : 0.0) && ok;
   ok = StateWrite("trend", gTrendDir) && ok;
   ok = StateWrite("altb", gAltBuyDone ? 1.0 : 0.0) && ok;
   ok = StateWrite("alts", gAltSellDone ? 1.0 : 0.0) && ok;
   ok = StateWrite("bdep", gBuyDepth) && ok;
   ok = StateWrite("sdep", gSellDepth) && ok;
   ok = StateWrite("dbl", gDblArmed ? 1.0 : 0.0) && ok;
   if(InpUseCenterReversalMultiplier)
   {
      ok = StateWrite("rvtrigger", (int)InpReversalTriggerMode) && ok;
      ok = StateWrite("rvmult", InpReversalMultiplier) && ok;
      ok = StateWrite("rvlot", InpReversalMaxLot) && ok;
      if(InpReversalTriggerMode == REVERSAL_TRIGGER_FLOATING_LOSS)
      {
         ok = StateWrite("rvloss", InpReversalFloatingLoss) && ok;
         ok = StateWrite("rvcenter", InpReversalRequireCenter ? 1.0 : 0.0) && ok;
         ok = StateWrite("rvflarm", gReversalLossArmed ? 1.0 : 0.0) && ok;
         ok = StateWrite("rvflon", gReversalLossApplied ? 1.0 : 0.0) && ok;
         ok = StateWrite("rvflside", gReversalLossSide) && ok;
      }
      else
      {
         ok = StateWrite("rvorders", InpReversalTriggerOrders) && ok;
         ok = StateWrite("rvlevels", (int)InpReversalLevels) && ok;
         ok = StateWrite("rvcompound", InpReversalCompound ? 1.0 : 0.0) && ok;
         ok = StateWrite("rvmax", InpReversalMaxSwitches) && ok;
         ok = StateWrite("rvarm", gReversalArmed ? 1.0 : 0.0) && ok;
         ok = StateWrite("rvorigin", gReversalOriginSide) && ok;
         ok = StateWrite("rvtarget", gReversalTargetSide) && ok;
         ok = StateWrite("rvcount", gReversalSwitches) && ok;
         ok = StateWrite("rvfactor", gReversalFactor) && ok;
         ok = StateWrite("rvbuy", gReversalBuyFactor) && ok;
         ok = StateWrite("rvsell", gReversalSellFactor) && ok;
         ok = StateWrite("rvtime", (double)gReversalLastSwitchMsc) && ok;
         ok = StateWrite("rvfill", (double)gReversalLastFillMsc) && ok;
      }
   }
   ok = StateWrite("ddarm", gDDArmed ? 1.0 : 0.0) && ok;
   ok = StateWrite("ddelig", gDDEligible ? 1.0 : 0.0) && ok;
   ok = StateWrite("ddmark", gDDMarkNet) && ok;

   if(ok) ok = StateWrite("ok", 1.0);
   if(flush) GlobalVariablesFlush();
   gStateForceWrite = false;
   if(ok)
   {
      gManualIdentityDirty = false;
      gCycleIdentityDirty = false;
      gLastStateSave = TimeCurrent();
      if(fullWrite) gLastStateFullSave = gLastStateSave;
   }
   else if(InpEnableJournalLogs) Print("State persistence failed; restart recovery may be unavailable.");
}

bool MultiplierStateMatches(string key, double expected, bool &ok)
{
   double saved = StateValue(key, ok);
   return (ok && MathIsValidNumber(saved) && MathAbs(saved-expected) <= 1e-9);
}

bool LoadGridMultiplierState(bool &ok)
{
   bool active = (gCycleOpen || gAwaitFlat);
   double rvon = StateValue("rvon", ok), dpon = StateValue("dpon", ok);
   if(!ok || (rvon != 0.0 && rvon != 1.0) || (dpon != 0.0 && dpon != 1.0) ||
      (rvon > 0.5 && dpon > 0.5)) return false;
   bool changed = ((rvon > 0.5) != InpUseCenterReversalMultiplier || (dpon > 0.5) != UseDepthDoubling());
   if(InpUseCenterReversalMultiplier && rvon > 0.5)
   {
      if(!MultiplierStateMatches("rvtrigger", (int)InpReversalTriggerMode, ok) ||
         !MultiplierStateMatches("rvmult", InpReversalMultiplier, ok) ||
         !MultiplierStateMatches("rvlot", InpReversalMaxLot, ok)) changed = true;
      if(InpReversalTriggerMode == REVERSAL_TRIGGER_FLOATING_LOSS)
      {
         if(!MultiplierStateMatches("rvloss", InpReversalFloatingLoss, ok) ||
            !MultiplierStateMatches("rvcenter", InpReversalRequireCenter ? 1.0 : 0.0, ok)) changed = true;
      }
      else if(!MultiplierStateMatches("rvorders", InpReversalTriggerOrders, ok) ||
              !MultiplierStateMatches("rvlevels", (int)InpReversalLevels, ok) ||
              !MultiplierStateMatches("rvcompound", InpReversalCompound ? 1.0 : 0.0, ok) ||
              !MultiplierStateMatches("rvmax", InpReversalMaxSwitches, ok)) changed = true;
   }
   if(UseDepthDoubling() && dpon > 0.5 &&
      (!MultiplierStateMatches("dpidx", InpDblTriggerIdx, ok) ||
       !MultiplierStateMatches("dpcntr", InpDblRequireCenter ? 1.0 : 0.0, ok) ||
       !MultiplierStateMatches("dpmult", InpDblMultiplier, ok))) changed = true;
   if(!ok || (changed && active))
   {
      if(InpEnableJournalLogs) Print("Saved grid-multiplier settings differ or are incomplete. Change multiplier modes/settings only while flat.");
      return false;
   }
   if(!active) return true; // Completed cycles never revive multiplier latches.
   if(UseDepthDoubling())
   {
      double armed = StateValue("dbl", ok);
      if(!ok || (armed != 0.0 && armed != 1.0)) return false;
      gDblArmed = (armed > 0.5);
   }
   if(!InpUseCenterReversalMultiplier) return ok;
   if(InpReversalTriggerMode == REVERSAL_TRIGGER_FLOATING_LOSS)
   {
      double armed = StateValue("rvflarm", ok), applied = StateValue("rvflon", ok);
      double side = StateValue("rvflside", ok);
      if(!ok || (armed != 0.0 && armed != 1.0) || (applied != 0.0 && applied != 1.0) ||
         (side != -1.0 && side != 0.0 && side != 1.0) ||
         (applied > 0.5 && armed < 0.5) || (armed < 0.5 && side != 0.0)) return false;
      gReversalLossArmed = (armed > 0.5);
      gReversalLossApplied = (applied > 0.5);
      gReversalLossSide = (int)side;
      return true;
   }
   gReversalArmed = (StateValue("rvarm", ok) > 0.5);
   gReversalOriginSide = (int)MathRound(StateValue("rvorigin", ok));
   gReversalTargetSide = (int)MathRound(StateValue("rvtarget", ok));
   gReversalSwitches = (int)MathRound(StateValue("rvcount", ok));
   gReversalFactor = StateValue("rvfactor", ok);
   gReversalBuyFactor = StateValue("rvbuy", ok);
   gReversalSellFactor = StateValue("rvsell", ok);
   gReversalLastSwitchMsc = (long)StateValue("rvtime", ok);
   gReversalLastFillMsc = (long)StateValue("rvfill", ok);
   return (ok && gReversalOriginSide >= -1 && gReversalOriginSide <= 1 &&
           gReversalTargetSide >= -1 && gReversalTargetSide <= 1 &&
           gReversalSwitches >= 0 && gReversalSwitches <= InpReversalMaxSwitches &&
           MathIsValidNumber(gReversalFactor) && gReversalFactor >= 1.0 &&
           MathIsValidNumber(gReversalBuyFactor) && gReversalBuyFactor >= 1.0 &&
           MathIsValidNumber(gReversalSellFactor) && gReversalSellFactor >= 1.0 &&
           gReversalLastSwitchMsc >= 0 && gReversalLastFillMsc >= 0 &&
           (gReversalSwitches == 0 || (gReversalArmed && gReversalTargetSide != 0)));
}

bool LoadBankLockOppositeState(int stateVersion, bool &ok)
{
   gBankLockRetainSide=0;
   bool active=(gCycleOpen || gAwaitFlat);
   if(stateVersion < 130)
   {
      if(active && UseBankLockCloseOpposite())
      {
         if(InpEnableJournalLogs) Print("Saved cycle predates opposite-side profit locking. Enable this option only while flat.");
         return false;
      }
      return true;
   }
   double enabled=StateValue("blopp",ok), side=StateValue("blside",ok);
   if(!ok || (enabled != 0.0 && enabled != 1.0) ||
      (side != -1.0 && side != 0.0 && side != 1.0) ||
      ((enabled < 0.5 || !gBankLockArmed) && side != 0.0)) return false;
   if(active && stateVersion == 130 && enabled > 0.5)
   {
      if(InpEnableJournalLogs) Print("Saved cycle uses the previous opposite-lock profit/freeze override. Finish it with the pre-fix backup, then switch only while flat.");
      return false;
   }
   if(active && ((enabled > 0.5) != UseBankLockCloseOpposite()))
   {
      if(InpEnableJournalLogs) Print("Saved opposite-side profit-lock mode differs. Change this option only while flat.");
      return false;
   }
   if(active && gBankLockArmed && UseBankLockCloseOpposite()) gBankLockRetainSide=(int)side;
   return true;
}

bool LoadManualTradeState(int stateVersion, bool &ok)
{
   ArrayResize(gManualTrades,0);
   if(stateVersion < 132) return true; // only flat legacy states may reach here
   double include=StateValue("manon",ok), manage=StateValue("manmanage",ok);
   double count=StateValue("mann",ok);
   if(!ok || (include != 0.0 && include != 1.0) || (manage != 0.0 && manage != 1.0) ||
      manage > include || !MathIsValidNumber(count) || count < 0 || count > 100000 || count != MathFloor(count)) return false;
   if((gCycleOpen || gAwaitFlat) &&
      ((include > 0.5) != InpIncludeManualTradesInCycle ||
       (manage > 0.5) != (InpIncludeManualTradesInCycle && InpManageManualTrades))) return false;
   ManualCycleTrade records[];
   if(ArrayResize(records,(int)count) != (int)count) return false;
   for(int i=0; i<(int)count; i++)
   {
      string field="man"+IntegerToString(i);
      records[i].id=(long)StateReadId(field,ok);
      double cycle=StateValue(field+"c",ok);
      if(!ok || records[i].id <= 0 || (i > 0 && records[i].id <= records[i-1].id) ||
         !MathIsValidNumber(cycle) || cycle <= 0 || cycle > 9007199254740991.0 || cycle != MathFloor(cycle)) return false;
      records[i].cycle=(long)cycle;
   }
   if(ArrayResize(gManualTrades,(int)count) != (int)count) return false;
   ArrayCopy(gManualTrades,records);
   gManualIdentityDirty=false;
   gManualRefreshDirty=true;
   return true;
}

bool LoadPersistentState()
{
   gRetiredCycleSnapshot = false;
   if(gIsTester || !InpPersistState) return false;
   bool ok = true;
   double valid = StateValue("ok", ok);
   double ver   = StateValue("ver", ok);
   int stateVersion = (int)MathRound(ver);
   if(!ok || valid < 0.5 ||
      (stateVersion != 112 && stateVersion != 113 &&
       stateVersion != 114 && stateVersion != 115 && stateVersion != 116 && stateVersion != 117 && stateVersion != 118 && stateVersion != 119 && stateVersion != 120 && stateVersion != 122 && stateVersion != 123 && stateVersion != 124 && stateVersion != 125 && stateVersion != 126 && stateVersion != 127 && stateVersion != 128 && stateVersion != 129 && stateVersion != 130 && stateVersion != 131 && stateVersion != 132 && stateVersion != 133)) return false;
   if(stateVersion < 132)
   {
      double open=StateValue("open",ok), awaiting=StateValue("await",ok);
      if(!ok || (open != 0.0 && open != 1.0) || (awaiting != 0.0 && awaiting != 1.0) ||
         open > 0.5 || awaiting > 0.5)
      {
         // An older EA may still have an unresolved entry/close request even
         // when the terminal inventory temporarily looks empty.
         gRetiredCycleSnapshot = true;
         if(InpEnableJournalLogs) Print("Older active cycle cannot be adopted by v1.60. Finish it with the backup EA, then switch only while flat.");
         return false;
      }
   }
   if(stateVersion == 123 && (StateValue("trailing", ok) != 0.0 || !ok)) return false;
   double savedTrailing=(stateVersion >= 124 ? StateValue("trailing",ok) : (stateVersion != 123 ? 1.0 : 0.0));
   if(!ok || (savedTrailing != 0.0 && savedTrailing != 1.0)) return false;
   // Retain flat-cycle cooldown/day context, but never reinterpret exposure
   // created by the removed modules as an ordinary fixed-grid cycle.
   if(stateVersion == 122 || stateVersion == 123 || stateVersion == 124 || stateVersion == 125)
   {
      double open=StateValue("open",ok), awaiting=StateValue("await",ok), settling=StateValue("settling",ok);
      double oldSpacing=(stateVersion == 123 ? StateValue("spon",ok) : 0.0);
      if(!ok || (open != 0.0 && open != 1.0) || (awaiting != 0.0 && awaiting != 1.0) ||
         (settling != 0.0 && settling != 1.0) || (oldSpacing != 0.0 && oldSpacing != 1.0)) return false;
      bool active=(open > 0.5 || (awaiting > 0.5 && settling < 0.5));
      if(active && (stateVersion != 123 || oldSpacing > 0.5))
      {
         if(InpEnableJournalLogs) Print("Saved active cycle belongs to removed modules. Finish it with the backup EA and switch only while flat.");
         return false;
      }
   }
   // Older variable-spacing cycles cannot be resumed against a fixed grid.
   if(stateVersion >= 113 && stateVersion <= 115 && StateValue("ageo", ok) > 0.5)
   {
      if(InpEnableJournalLogs) Print("Saved cycle uses variable spacing. Finish it with v1.42 before switching to this version.");
      return false;
   }

   double oldGap  = StateValue("gap", ok);
   // States written before v1.25 used InpGridGap for both the first-level
   // offset and later spacing, so oldGap is the compatible fallback.
   double oldCenterGap = StateValueOrDefault("cgap", oldGap);
   int oldN       = (int)MathRound(StateValue("n", ok));
   int oldTier    = (int)MathRound(StateValue("tier", ok));
   double oldNear = StateValue("ln", ok);
   double oldMid  = StateValue("lm", ok);
   double oldFar  = StateValue("lf", ok);
   bool gridChanged = (MathAbs(oldGap-InpGridGap) > 1e-9 ||
                       MathAbs(oldCenterGap-InpCenterSideGap) > 1e-9);
   bool savedProgression = (stateVersion >= 119 ? StateValue("gpon", ok) > 0.5 : stateVersion == 118);
   bool lotChanged = (savedProgression != InpUseGridLotProgression);
   if(savedProgression && InpUseGridLotProgression)
   {
      double oldInitial = StateValue("gpstart", ok);
      double oldMultiplier = StateValue("gpmult", ok);
      lotChanged = (!MathIsValidNumber(oldInitial) || !MathIsValidNumber(oldMultiplier) ||
                    MathAbs(oldInitial-InpGridInitialLot) > 1e-9 || MathAbs(oldMultiplier-InpGridLotMultiplier) > 1e-9);
   }
   else if(!savedProgression && !InpUseGridLotProgression)
      lotChanged = (oldTier != InpTierSize || MathAbs(oldNear-InpLotNear) > 1e-9 ||
                    MathAbs(oldMid-InpLotMid) > 1e-9 || MathAbs(oldFar-InpLotFar) > 1e-9);
   if(!ok || gridChanged || oldN != GridOrdersPerSide() || lotChanged)
   {
      if(InpEnableJournalLogs) Print("Saved state does not match the current grid/lot configuration.");
      return false;
   }

   gCenter           = StateValue("ctr", ok);
   gCycleStart       = (datetime)StateValue("start", ok);
   gCycleOpen        = (StateValue("open", ok) > 0.5);
   gAwaitFlat        = (StateValue("await", ok) > 0.5);
   double reset=(stateVersion >= 133 ? StateValue("uireset",ok) : 0.0);
   if(!ok || (reset != 0.0 && reset != 1.0) || (reset > 0.5 && gAwaitFlat))
   { gRetiredCycleSnapshot=true; return false; }
   gDashboardResetPending=(reset > 0.5);
   gDashboardResetSettleUntil=0; gDashboardResetRetryAfter=0;
   gFlatSettling     = (StateValue("settling", ok) > 0.5);
   if(gDashboardResetPending && gFlatSettling) { gRetiredCycleSnapshot=true; return false; }
   if((gCycleOpen || (gAwaitFlat && !gFlatSettling)) &&
      InpUseTrailingStop != (savedTrailing > 0.5))
   {
      if(InpEnableJournalLogs) Print("Saved cycle uses a different trailing/profit basis. Change InpUseTrailingStop only while flat; an armed NET lock cannot be restored as a floating lock or vice versa.");
      return false;
   }
   ArrayResize(gCycleExcludedPositions, 0);
   ArrayResize(gCycleExcludedDeals, 0);
   ArrayResize(gResetPositionIds, 0);
   gCycleStartMsc = (long)gCycleStart*1000; // legacy cycles have only a second-resolution boundary
   if(stateVersion >= 119)
   {
      double ms = StateValue("cms", ok);
      if(!ok || !MathIsValidNumber(ms) || ms < 0 || ms > 9007199254740991.0 || ms != MathFloor(ms)) return false;
      gCycleStartMsc = (long)ms;
      double np = StateValue("cxpn", ok), nd = StateValue("cxdn", ok), nr = StateValue("crpn", ok);
      if(!ok || !MathIsValidNumber(np) || !MathIsValidNumber(nd) || !MathIsValidNumber(nr) ||
         np < 0 || nd < 0 || nr < 0 || np > 100000 || nd > 100000 || nr > 100000 ||
         np != MathRound(np) || nd != MathRound(nd) || nr != MathRound(nr) ||
         gCycleStartMsc < 0 || (gCycleOpen && !gFlatSettling && gCycleStartMsc/1000 != (long)gCycleStart)) return false;
      for(int i=0; i<(int)np; i++)
      {
         long id = (long)StateReadId("cxp"+IntegerToString(i), ok);
         if(!ok || id <= 0 || !AddCyclePositionId(gCycleExcludedPositions, id)) return false;
      }
      if(ArrayResize(gCycleExcludedDeals, (int)nd) < 0) return false;
      for(int i=0; i<(int)nd; i++) gCycleExcludedDeals[i] = StateReadId("cxd"+IntegerToString(i), ok);
      for(int i=0; i<(int)nr; i++)
      {
         long id = (long)StateReadId("crp"+IntegerToString(i), ok);
         if(!ok || id <= 0 || !AddCyclePositionId(gResetPositionIds, id)) return false;
      }
   }
   gCycleIdentityDirty = false;
   gCycleAccountingRevision++;
   if(!LoadManualTradeState(stateVersion,ok))
   {
      gRetiredCycleSnapshot=true;
      if(InpEnableJournalLogs) Print("Saved manual-trade ownership is incomplete or settings differ. Change manual integration only between completed cycles.");
      return false;
   }
   gSettleUntil      = (datetime)StateValue("settleto", ok);
   gCooldownUntil    = (datetime)StateValue("cool", ok);
   gCycleStartEquity = StateValue("ceq", ok);
   if(stateVersion >= 114 && InpUseBankProfitLock)
   {
      gBankLockArmed = (StateValue("blarm", ok) > 0.5);
      gBankLockPeak = StateValue("blpeak", ok);
      gBankLockFloor = StateValue("blfloor", ok);
   }
   else
   {
      gBankLockArmed = false;
      gBankLockPeak = 0.0;
      gBankLockFloor = 0.0;
   }
   if(!LoadBankLockOppositeState(stateVersion,ok))
   {
      if(gCycleOpen || gAwaitFlat) gRetiredCycleSnapshot=true;
      return false;
   }
   gDayStart         = (datetime)StateValue("day", ok);
   gDayStartBalance  = StateValue("dbal", ok);
   gHaltedToday      = (StateValue("halt", ok) > 0.5);
   datetime savedMonth = (datetime)StateValueOrDefault("month", 0.0);
   gHaltedMonth      = (InpUseMonthlyCapitalTarget && savedMonth == gMonthStart &&
                        StateValueOrDefault("mhalt", 0.0) > 0.5);
   gLossExitPending  = (StateValue("lossx", ok) > 0.5);
   gConsecutiveLosses = (int)MathRound(StateValue("losses", ok));

   gLastExitSide     = (int)MathRound(StateValue("lastside", ok));
   gNextCycleQuick   = (StateValue("nextq", ok) > 0.5);
   gTrendDir         = (int)MathRound(StateValue("trend", ok));
   gAltBuyDone       = (StateValue("altb", ok) > 0.5);
   gAltSellDone      = (StateValue("alts", ok) > 0.5);
   gBuyDepth         = (int)MathRound(StateValue("bdep", ok));
   gSellDepth        = (int)MathRound(StateValue("sdep", ok));
   gDblArmed         = false;
   ResetCenterReversalMultiplier();
   if(stateVersion >= 129 && !LoadGridMultiplierState(ok))
   {
      if(gCycleOpen || gAwaitFlat) gRetiredCycleSnapshot = true;
      return false;
   }
   gDDArmed          = (StateValue("ddarm", ok) > 0.5);
   gDDEligible       = (StateValue("ddelig", ok) > 0.5);
   gDDMarkNet        = StateValue("ddmark", ok);


   bool bankLockInvalid = (gBankLockArmed &&
                           (gBankLockPeak < 0.0 || gBankLockFloor < 0.0 ||
                            gBankLockFloor > gBankLockPeak+0.01));
   if(!ok || gCenter <= 0.0 || gCycleStart <= 0 || bankLockInvalid)
   {
      if(InpEnableJournalLogs) Print("Saved cycle state is incomplete or invalid.");
      return false;
   }
   gTrendLastBar = 0; // refresh indicators from closed bars after restart
   return true;
}

void RebuildRuntimeTracking()
{
   ArrayResize(gTsTk, 0);       ArrayResize(gTsLast, 0);
   ArrayResize(gClosingTk, 0);  ArrayResize(gClosingMs, 0);
   ArrayResize(gDelTk, 0);      ArrayResize(gDelMs, 0);
}
 
int TsFind(ulong tk)
{
   int k=TicketLowerBound(gTsTk, tk);
   return(k < ArraySize(gTsTk) && gTsTk[k] == tk ? k : -1);
}

int TicketLowerBound(ulong &tickets[], ulong ticket)
{
   int lo=0, hi=ArraySize(tickets);
   while(lo < hi)
   {
      int mid=lo+(hi-lo)/2;
      if(tickets[mid] < ticket) lo=mid+1;
      else hi=mid;
   }
   return lo;
}
//--- one modify per second per position: allowed if >=1000ms since last modify
bool TsAllow(ulong tk)
{
   int k = TsFind(tk);
   if(k < 0) return true;                       // never modified -> allowed
   return(RequestClockMs() - gTsLast[k] >= 1000);
}
//--- record a modify for this ticket
void TsMark(ulong tk)
{
   int k=TicketLowerBound(gTsTk,tk), n=ArraySize(gTsTk);
   if(k == n || gTsTk[k] != tk)
   {
      if(ArrayResize(gTsTk,n+1,64) < 0 || ArrayResize(gTsLast,n+1,64) < 0)
      { ArrayResize(gTsTk,n); ArrayResize(gTsLast,n); return; }
      for(int i=n; i>k; i--) { gTsTk[i]=gTsTk[i-1]; gTsLast[i]=gTsLast[i-1]; }
      gTsTk[k]=tk;
   }
   gTsLast[k] = RequestClockMs();
}
//--- drop tracking rows whose position is gone (called once per pass)
void TsSweep()
{
   int kept=0;
   for(int i=0; i<ArraySize(gTsTk); i++)
      if(PositionSelectByTicket(gTsTk[i]))
      {
         gTsTk[kept]=gTsTk[i]; gTsLast[kept]=gTsLast[i]; kept++;
      }
   ArrayResize(gTsTk,kept); ArrayResize(gTsLast,kept);
}
 
void ManageTrailingAndSnapshot(double bid, double ask, double &floating, int &count)
{
   floating = 0.0;
   count = 0;
   if(!gInit || gRecoveryBlocked) return;

   // Ticket cleanup cannot affect a position more than once per server second.
   // Avoid selecting every previously-trailed ticket on every market tick.
   static datetime lastSweep = 0;
   datetime now = TimeCurrent();
   if(InpUseTrailingStop && now != lastSweep)
   {
      lastSweep = now;
      TsSweep();
   }

   int totalPositions = PositionsTotal();
   ulong snapshotRevision=gPositionSnapshotRevision;
   if(totalPositions <= 0)
   { CachePositionSnapshot(0.0,0,0.0,0.0,0.0,0,snapshotRevision,0,0); return; }
   double gapW = InpTrailGapWide, gapT = InpTrailGap;
   double arm  = InpArmDistance,  tgt = InpTrailTightenAt;
   double minDist = (InpUseTrailingStop ? StopsMin() : 0.0);
   double floatBuy=0.0, floatSell=0.0, allVolume=0.0;
   int manualBuys=0, manualSells=0;

   for(int i=totalPositions-1; i>=0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue; // PositionGetTicket also selects this position
      if(!IsCyclePositionSelected()) continue;
      RememberCyclePosition(PositionGetInteger(POSITION_IDENTIFIER));

      double pnl=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      floating += pnl;
      allVolume += PositionGetDouble(POSITION_VOLUME);
      bool isBuy=(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if(isBuy) floatBuy += pnl;
      else floatSell += pnl;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
      {
         if(isBuy) manualBuys++; else manualSells++;
      }
      count++;

      if(!IsManagedPositionSelected()) continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic && IsLegacyPPGCmt(comment)) continue;
      if(!InpUseTrailingStop) continue; // retain the complete floating snapshot, without changing broker stops

      long   type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double cur  = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
 
      if(type == POSITION_TYPE_BUY)
      {
         double profit = bid - open;
         if(profit < arm) continue;
         double gap = (profit < tgt ? gapW : gapT);
         double want = NormPrice(bid - MathMax(gap, minDist));
         if(cur > 0.0 && want <= cur) continue;                 // ratchet up only
         if(!TsAllow(t)) continue;
         TsMark(t); // failed requests also consume the rate limit
         ModifyPositionSafe(t, want, tp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profit = open - ask;
         if(profit < arm) continue;
         double gap = (profit < tgt ? gapW : gapT);
         double want = NormPrice(ask + MathMax(gap, minDist));
         if(cur > 0.0 && want >= cur) continue;
         if(!TsAllow(t)) continue;
         TsMark(t);
         ModifyPositionSafe(t, want, tp);
      }
   }
   CachePositionSnapshot(floating,count,floatBuy,floatSell,allVolume,totalPositions,snapshotRevision,manualBuys,manualSells);
   if(!gPositionSnapshotValid)
   {
      if(totalPositions != PositionsTotal()) { gBankHistoryDirty=true; gGridDirty=true; }
      PositionSummary(floating,count);
   }
}

void ManageTrailing(double bid, double ask)
{
   double floating=0.0;
   int count=0;
   ManageTrailingAndSnapshot(bid, ask, floating, count);
}
 
//+------------------------------------------------------------------+
//| Level tag helpers                                                |
//+------------------------------------------------------------------+
string LevelTag(bool isBuy, int idx)
{
   return (isBuy ? "B" : "S") + IntegerToString(idx);
}
 
int ParseLevelTag(string cmt, bool isBuy)
{
   if(StringLen(cmt) < 2) return -1;
   ushort c0 = StringGetCharacter(cmt, 0);
   if(isBuy  && c0 != 'B') return -1;
   if(!isBuy && c0 != 'S') return -1;
   int v = (int)StringToInteger(StringSubstr(cmt, 1));
   return (v >= 1 ? v : -1);
}

double GridLevelDistance(int idx)
{
   if(idx < 1) return 0.0;
   return InpCenterSideGap + (idx-1)*InpGridGap;
}

void EnsureGridLevelPriceCache()
{
   int size = GridOrdersPerSide()+1;
   double centerGap = InpCenterSideGap;
   double gridGap = InpGridGap;
   bool rebuild = (ArraySize(gGridLevelBuyPrice) != size ||
                   MathAbs(gGridPriceCacheCenter-gCenter) > 1e-9 ||
                   MathAbs(gGridPriceCacheCenterGap-centerGap) > 1e-9 ||
                   MathAbs(gGridPriceCacheGap-gridGap) > 1e-9);
   if(!rebuild) return;

   ArrayResize(gGridLevelBuyPrice, size);
   ArrayResize(gGridLevelSellPrice, size);
   gGridLevelBuyPrice[0] = 0.0;
   gGridLevelSellPrice[0] = 0.0;
   for(int i=1; i<size; i++)
   {
      double distance = centerGap+(i-1)*gridGap;
      gGridLevelBuyPrice[i] = NormPrice(gCenter+distance);
      gGridLevelSellPrice[i] = NormPrice(gCenter-distance);
   }
   gGridPriceCacheCenter = gCenter;
   gGridPriceCacheCenterGap = centerGap;
   gGridPriceCacheGap = gridGap;
}

double GridLevelPrice(bool isBuy, int idx)
{
   if(idx >= 1 && idx <= GridOrdersPerSide())
   {
      EnsureGridLevelPriceCache();
      return(isBuy ? gGridLevelBuyPrice[idx] : gGridLevelSellPrice[idx]);
   }
   double distance = GridLevelDistance(idx);
   return NormPrice(gCenter + (isBuy ? distance : -distance));
}

int GridLevelIndexFromPrice(bool isBuy, double price)
{
   double distance = (isBuy ? price-gCenter : gCenter-price);
   if(distance <= 0.0) return -1;
   int idx = 1 + (int)MathRound((distance-InpCenterSideGap)/InpGridGap);
   return (idx >= 1 ? idx : -1);
}

//--- Once armed, depth doubling is persistent for the rest of the cycle. Every
//--- existing pending grid stop is upgraded and every future stop uses the
//--- multiplied tier lot. Already-open positions keep their original volume.
bool UseDepthDoubling()
{
   return (InpUseDepthDouble && !InpUseCenterReversalMultiplier);
}

double IntendedLot(int idx)
{
   double lot = TierLot(idx);
   if(UseDepthDoubling() && gDblArmed)
      lot = NormLot(lot * InpDblMultiplier);
   return lot;
}

double GridStopLot(bool isBuy, int idx)
{
   double lot = IntendedLot(idx);
   if(!InpUseCenterReversalMultiplier) return lot;
   bool floatingMode = (InpReversalTriggerMode == REVERSAL_TRIGGER_FLOATING_LOSS);
   if(floatingMode && !gReversalLossApplied) return lot;
   if(!floatingMode && InpReversalLevels == REVERSAL_LEVELS_ALTERNATE && idx%2 == 0) return lot;
   double base = TierLot(idx);
   double factor = (floatingMode ? InpReversalMultiplier : (isBuy ? gReversalBuyFactor : gReversalSellFactor));
   double reversalLot = base*factor;
   if(InpReversalMaxLot > 0.0)
      reversalLot = MathMin(reversalLot, MathMax(base, InpReversalMaxLot));
   // The two multiplier systems must not multiply each other unexpectedly.
   return MathMax(lot, NormLot(reversalLot));
}

void ResetCenterReversalMultiplier()
{
   gReversalLossArmed = false;
   gReversalLossApplied = false;
   gReversalLossSide = 0;
   gReversalArmed = false;
   gReversalOriginSide = 0;
   gReversalTargetSide = 0;
   gReversalSwitches = 0;
   gReversalFactor = 1.0;
   gReversalBuyFactor = 1.0;
   gReversalSellFactor = 1.0;
   gReversalLastSwitchMsc = 0;
   gReversalLastFillMsc = 0;
   ArrayResize(gReversalFilledBuy, 0);
   ArrayResize(gReversalFilledSell, 0);
   gReversalBuyFillCount = 0;
   gReversalSellFillCount = 0;
}

void RecordCenterReversalFill(bool isBuy, int idx, long fillTimeMsc)
{
   if(!InpUseCenterReversalMultiplier || InpReversalTriggerMode != REVERSAL_TRIGGER_FILLS || !gCycleOpen || gAwaitFlat ||
      idx < 1 || idx > GridOrdersPerSide() ||
      fillTimeMsc <= gReversalLastSwitchMsc || fillTimeMsc < gReversalLastFillMsc ||
      gReversalSwitches >= InpReversalMaxSwitches) return;
   int side = (isBuy ? +1 : -1);
   if(gReversalTargetSide != 0 && side != gReversalTargetSide) return;
   // Keep the first qualified source until its center return is consumed.
   if(gReversalOriginSide != 0 && side != gReversalOriginSide) return;
   if(!gReversalArmed)
   {
      int size = GridOrdersPerSide()+1;
      if(ArraySize(gReversalFilledBuy) != size)
      {
         ArrayResize(gReversalFilledBuy, size);
         ArrayResize(gReversalFilledSell, size);
         ArrayInitialize(gReversalFilledBuy, false);
         ArrayInitialize(gReversalFilledSell, false);
         gReversalBuyFillCount = 0;
         gReversalSellFillCount = 0;
      }
      if(isBuy && !gReversalFilledBuy[idx])
      {
         gReversalFilledBuy[idx] = true;
         gReversalBuyFillCount++;
      }
      else if(!isBuy && !gReversalFilledSell[idx])
      {
         gReversalFilledSell[idx] = true;
         gReversalSellFillCount++;
      }
      int fills = (isBuy ? gReversalBuyFillCount : gReversalSellFillCount);
      if(fills < InpReversalTriggerOrders) return;
      gReversalArmed = true;
   }
   gReversalOriginSide = side;
   gReversalLastFillMsc = fillTimeMsc;
}

void RebuildCenterReversalOrigin()
{
   if(!InpUseCenterReversalMultiplier || InpReversalTriggerMode != REVERSAL_TRIGGER_FILLS || !gCycleOpen || gAwaitFlat) return;
   if(!HistorySelect(gCycleStart, TimeCurrent()+1)) return;
   // Recover only unconsumed fills; never replay center switches from history.
   for(int i=0; i<HistoryDealsTotal(); i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0 || HistoryDealGetInteger(t, DEAL_MAGIC) != InpMagic ||
         HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol ||
         HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      if(!IsCurrentCycleDeal(t)) continue;
      string cmt = DealTag(t);
      if(IsSubEngineCmt(cmt)) continue;
      long type = HistoryDealGetInteger(t, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
      bool isBuy = (type == DEAL_TYPE_BUY);
      int idx = ParseLevelTag(cmt, isBuy);
      if(idx < 0) idx = GridLevelIndexFromPrice(isBuy, HistoryDealGetDouble(t, DEAL_PRICE));
      RecordCenterReversalFill(isBuy, idx, HistoryDealGetInteger(t, DEAL_TIME_MSC));
   }
}

void UpdateFloatingReversalMultiplier(double bid, double ask)
{
   if(!InpUseCenterReversalMultiplier || InpReversalTriggerMode != REVERSAL_TRIGGER_FLOATING_LOSS ||
      !gCycleOpen || gAwaitFlat || gReversalLossApplied) return;
   double mid = (bid+ask)/2.0;
   double band = MathMin(InpCenterSideGap, InpGridGap)*0.5;
   if(!gReversalLossArmed)
   {
      double floating = FloatingPnL(); // Symbol + magic only; realized bank is deliberately excluded.
      if(!MathIsValidNumber(floating) || floating > -InpReversalFloatingLoss) return;
      gReversalLossArmed = true;
      gReversalLossSide = (mid > gCenter+band ? +1 : (mid < gCenter-band ? -1 : 0));
      if(InpEnableJournalLogs) PrintFormat("Floating-loss grid multiplier armed: floating %.2f <= -%.2f. %s",
                  floating, InpReversalFloatingLoss, (InpReversalRequireCenter ? "Waiting for center return." : "Immediate mode."));
      SavePersistentState(true);
   }
   // Latch the loss even during a freeze, but never bypass an exposure lock.
   if(ActiveCycleRiskLocked()) return;
   if(InpReversalRequireCenter &&
      ((gReversalLossSide > 0 && mid > gCenter+band) ||
       (gReversalLossSide < 0 && mid < gCenter-band))) return;

   gReversalLossApplied = true;
   gGridDirty = true;
   if(InpEnableJournalLogs) PrintFormat("Floating-loss grid multiplier applied ONCE: all BUY/SELL pending and future grid stops use base lot x%.2f (lot cap %.2f). Open positions and grid prices unchanged.",
               InpReversalMultiplier, InpReversalMaxLot);
   SavePersistentState(true);
}

void UpdateCenterReversalMultiplier(double bid, double ask)
{
   if(InpReversalTriggerMode == REVERSAL_TRIGGER_FLOATING_LOSS)
   {
      UpdateFloatingReversalMultiplier(bid, ask);
      return;
   }
   if(!InpUseCenterReversalMultiplier || !gCycleOpen || gAwaitFlat ||
      ActiveCycleRiskLocked() || !gReversalArmed || gReversalOriginSide == 0 ||
      gReversalSwitches >= InpReversalMaxSwitches) return;
   double mid = (bid+ask)/2.0;
   double band = MathMin(InpCenterSideGap, InpGridGap)*0.5;
   bool returned = (gReversalOriginSide > 0 ? mid <= gCenter+band : mid >= gCenter-band);
   if(!returned) return;

   int target = -gReversalOriginSide;
   double factor = (InpReversalCompound ? gReversalFactor*InpReversalMultiplier : InpReversalMultiplier);
   if(!MathIsValidNumber(factor)) return;
   gReversalFactor = factor;
   if(target > 0) gReversalBuyFactor = MathMax(gReversalBuyFactor, factor);
   else gReversalSellFactor = MathMax(gReversalSellFactor, factor);
   gReversalTargetSide = target;
   gReversalOriginSide = 0;
   gReversalSwitches++;
   MqlTick tick;
   long stamp = (long)TimeCurrent()*1000;
   if(SymbolInfoTick(_Symbol, tick) && tick.time_msc > stamp) stamp = tick.time_msc;
   gReversalLastSwitchMsc = (long)MathMax((double)stamp, (double)gReversalLastFillMsc);
   gGridDirty = true;
   if(InpEnableJournalLogs) PrintFormat("Center reversal #%d: %s %s grid stops now use tier lot x%.2f (lot cap %.2f). Open positions unchanged.",
               gReversalSwitches, (target > 0 ? "BUY" : "SELL"),
               (InpReversalLevels == REVERSAL_LEVELS_ALTERNATE ? "odd-level" : "all"), factor, InpReversalMaxLot);
   SavePersistentState(true);
}

void UpdateDepthDoubleArming(double bid, double ask)
{
   if(!UseDepthDoubling() || gDblArmed || !gCycleOpen) return;
   if(gBuyDepth < InpDblTriggerIdx && gSellDepth < InpDblTriggerIdx) return;

   if(InpDblRequireCenter)
   {
      double mid = (bid+ask)/2.0;
      bool atCenter = (MathAbs(mid-gCenter) <= MathMin(InpCenterSideGap, InpGridGap)*0.5);
      if(!atCenter) return;
   }

   gDblArmed = true;
   gGridDirty = true;
   if(InpEnableJournalLogs) PrintFormat("Depth doubling armed %s: BUY depth=%d, SELL depth=%d. All pending and future grid stops use x%.2f; open positions stay unchanged.",
               (InpDblRequireCenter ? "after center return" : "immediately at trigger depth"),
               gBuyDepth, gSellDepth, InpDblMultiplier);
   SavePersistentState(false);
}

string ReversalMultiplierStatus()
{
   if(!InpUseCenterReversalMultiplier) return "";
   string status;
   if(InpReversalTriggerMode == REVERSAL_TRIGGER_FLOATING_LOSS)
   {
      if(gReversalLossApplied) status = "float x"+DoubleToString(InpReversalMultiplier,2)+" ON";
      else if(gReversalLossArmed) status = (ActiveCycleRiskLocked() ? "float armed/frozen" : "float wait center");
      else status = "float wait -"+DoubleToString(InpReversalFloatingLoss,0);
   }
   else status = "reversal "+IntegerToString(gReversalSwitches);
   if(InpUseDepthDouble) status += " / depth paused";
   return status;
}
 
//+------------------------------------------------------------------+
//| Maintain / refill the pending-order grid                         |
//+------------------------------------------------------------------+
void ResetInitialGridFormation()
{
   int size = GridOrdersPerSide()+1;
   ArrayResize(gGridInitialBuySeen, size);
   ArrayResize(gGridInitialSellSeen, size);
   ArrayInitialize(gGridInitialBuySeen, false);
   ArrayInitialize(gGridInitialSellSeen, false);
   gInitialGridForming = true;
}

void UpdateInitialGridFormation()
{
   if(!gInitialGridForming) return;
   bool complete = true;
   for(int i=1; i<=GridOrdersPerSide(); i++)
   {
      if(gGridPosBuy[i] || gGridPendBuy[i]) gGridInitialBuySeen[i] = true;
      if(gGridPosSell[i] || gGridPendSell[i]) gGridInitialSellSeen[i] = true;
      if(!gGridInitialBuySeen[i] || !gGridInitialSellSeen[i]) complete = false;
   }
   if(complete) gInitialGridForming = false;
}

void EnsureGridCacheSize()
{
   int size = GridOrdersPerSide() + 1;
   if(ArraySize(gGridPosBuy) == size) return;
   ArrayResize(gGridPosBuy, size);      ArrayResize(gGridPosSell, size);
   ArrayResize(gGridPendBuy, size);     ArrayResize(gGridPendSell, size);
   ArrayResize(gGridPendBuyTk, size);   ArrayResize(gGridPendSellTk, size);
   ArrayResize(gGridPendBuyVol, size);  ArrayResize(gGridPendSellVol, size);
   ArrayResize(gGridPendBuyPrice, size); ArrayResize(gGridPendSellPrice, size);
   gGridDirty = true;
   gGridWatchValid = false;
}

void RebuildGridCache()
{
   EnsureGridCacheSize();
   ArrayInitialize(gGridPosBuy, false);       ArrayInitialize(gGridPosSell, false);
   ArrayInitialize(gGridPendBuy, false);      ArrayInitialize(gGridPendSell, false);
   ArrayInitialize(gGridPendBuyTk, 0);        ArrayInitialize(gGridPendSellTk, 0);
   ArrayInitialize(gGridPendBuyVol, 0.0);     ArrayInitialize(gGridPendSellVol, 0.0);
   ArrayInitialize(gGridPendBuyPrice, 0.0);   ArrayInitialize(gGridPendSellPrice, 0.0);
   gGridOpenVolume = 0.0;
   gGridCachedExposureLots = 0.0;

   int N = GridOrdersPerSide();
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(!IsCyclePositionSelected()) continue;
      double positionVolume = PositionGetDouble(POSITION_VOLUME);
      gGridOpenVolume += positionVolume;
      gGridCachedExposureLots += positionVolume;
      if(!IsMine(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue; // manual trades never occupy grid levels
      long type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      string cmt = PositionGetString(POSITION_COMMENT);
      if(IsSubEngineCmt(cmt)) continue;
      if(type == POSITION_TYPE_BUY)
      {
         int idx = ParseLevelTag(cmt, true);
         if(idx < 0) idx = GridLevelIndexFromPrice(true, open);
         if(idx >= 1 && idx <= N) gGridPosBuy[idx] = true;
      }
      else if(type == POSITION_TYPE_SELL)
      {
         int idx = ParseLevelTag(cmt, false);
         if(idx < 0) idx = GridLevelIndexFromPrice(false, open);
         if(idx >= 1 && idx <= N) gGridPosSell[idx] = true;
      }
   }

   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!IsCycleOrderSelected()) continue;
      gGridCachedExposureLots += OrderGetDouble(ORDER_VOLUME_CURRENT);
      if(!IsMine(OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_SYMBOL))) continue; // manual pending orders are not grid stops
      long type = OrderGetInteger(ORDER_TYPE);
      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      // Initial volume remains stable after a partial fill. Comparing the
      // current remainder would mistake a partially-filled doubled stop for a
      // base order and could submit another full doubled replacement.
      double volume = OrderGetDouble(ORDER_VOLUME_INITIAL);
      string cmt = OrderGetString(ORDER_COMMENT);
      if(type == ORDER_TYPE_BUY_STOP)
      {
         int idx = ParseLevelTag(cmt, true);
         if(idx < 0) idx = GridLevelIndexFromPrice(true, price);
         if(idx >= 1 && idx <= N)
         {
            gGridPendBuy[idx]=true; gGridPendBuyTk[idx]=t;
            gGridPendBuyVol[idx]=volume; gGridPendBuyPrice[idx]=price;
         }
      }
      else if(type == ORDER_TYPE_SELL_STOP)
      {
         int idx = ParseLevelTag(cmt, false);
         if(idx < 0) idx = GridLevelIndexFromPrice(false, price);
         if(idx >= 1 && idx <= N)
         {
            gGridPendSell[idx]=true; gGridPendSellTk[idx]=t;
            gGridPendSellVol[idx]=volume; gGridPendSellPrice[idx]=price;
         }
      }
   }
   gGridDirty = false;
   gGridWatchValid = false;
}

bool GridLotFitsExposureCap(int idx, bool isBuy)
{
   if(InpMaxExposureLots <= 0.0) return true;
   return(gGridCachedExposureLots+GridStopLot(isBuy, idx) <= InpMaxExposureLots+1e-8);
}

void RefreshGridMaintenanceWatch(double buffer)
{
   EnsureGridLevelPriceCache();
   gGridWatchBuyRemoveAsk = 1.0e100;
   gGridWatchSellRemoveBid = -1.0e100;
   gGridWatchBuyActionAsk = -1.0e100;
   gGridWatchSellActionBid = 1.0e100;
   for(int i=1; i<=GridOrdersPerSide(); i++)
   {
      if(gGridPendBuy[i])
      {
         double removeAt = gGridPendBuyPrice[i]+InpMaxSlippage;
         if(removeAt < gGridWatchBuyRemoveAsk) gGridWatchBuyRemoveAsk = removeAt;
         if(GridStopLot(true, i) > gGridPendBuyVol[i]+1e-8)
         {
            double upgradeAt = gGridPendBuyPrice[i]-buffer;
            if(upgradeAt > gGridWatchBuyActionAsk) gGridWatchBuyActionAsk = upgradeAt;
         }
      }
      if(gGridPendSell[i])
      {
         double removeAt = gGridPendSellPrice[i]-InpMaxSlippage;
         if(removeAt > gGridWatchSellRemoveBid) gGridWatchSellRemoveBid = removeAt;
         if(GridStopLot(false, i) > gGridPendSellVol[i]+1e-8)
         {
            double upgradeAt = gGridPendSellPrice[i]+buffer;
            if(upgradeAt < gGridWatchSellActionBid) gGridWatchSellActionBid = upgradeAt;
         }
      }

      if(!gGridPosBuy[i] && !gGridPendBuy[i] && GridLotFitsExposureCap(i, true))
      {
         double placeAt = gGridLevelBuyPrice[i]-buffer;
         if(placeAt > gGridWatchBuyActionAsk) gGridWatchBuyActionAsk = placeAt;
      }
      if(!gGridPosSell[i] && !gGridPendSell[i] && GridLotFitsExposureCap(i, false))
      {
         double placeAt = gGridLevelSellPrice[i]+buffer;
         if(placeAt < gGridWatchSellActionBid) gGridWatchSellActionBid = placeAt;
      }
   }
   gGridWatchValid = true;
}

bool GridMaintenanceDue(double bid, double ask)
{
   if(!gGridWatchValid) return true;
   if(ask > gGridWatchBuyRemoveAsk) return true;
   if(bid < gGridWatchSellRemoveBid) return true;
   if(ask <= gGridWatchBuyActionAsk) return true;
   if(bid >= gGridWatchSellActionBid) return true;
   return false;
}

void MaintainGrid(double bid, double ask)
{
   double minStop = StopsMin();
   double buf     = MathMax(minStop, InpRefillBuffer);   // never place closer than this
   int    N       = GridOrdersPerSide();
   EnsureGridCacheSize();
   if(!gGridDirty && !GridMaintenanceDue(bid, ask)) return;
   if(gGridDirty) RebuildGridCache();
   EnsureGridLevelPriceCache();
   UpdateInitialGridFormation();

   // Upgrade existing pending stops in controlled batches. Open positions are
   // never resized; future missing levels use the side-aware GridStopLot below.
   int upgraded = 0;
   for(int i=1; i<=N; i++)
   {
      if(gGridPendBuy[i])
      {
         double orderPrice = gGridPendBuyPrice[i];
         bool remove = (ask > orderPrice + InpMaxSlippage);
         double want = GridStopLot(true, i);
         bool upgrade = (want > gGridPendBuyVol[i]+1e-8);
         if(!remove && upgrade && upgraded < InpMaxPlacePerTick && orderPrice >= ask+buf) remove=true;
         if(remove && DeleteOrderSafe(gGridPendBuyTk[i]))
         {
            if(upgrade)
            {
               if(InpEnableJournalLogs) PrintFormat((InpUseCenterReversalMultiplier ? "Grid multiplier replacement upgrade: %s %.2f -> %.2f lots." : "Depth doubled replacement upgrade: %s %.2f -> %.2f lots."),
                           LevelTag(true,i), gGridPendBuyVol[i], want);
               upgraded++;
            }
            gGridPendBuy[i]=false; gGridPendBuyTk[i]=0;
            gGridPendBuyVol[i]=0.0; gGridPendBuyPrice[i]=0.0;
            gGridDirty=true;
         }
      }

      if(gGridPendSell[i])
      {
         double orderPrice = gGridPendSellPrice[i];
         bool remove = (bid < orderPrice - InpMaxSlippage);
         double want = GridStopLot(false, i);
         bool upgrade = (want > gGridPendSellVol[i]+1e-8);
         if(!remove && upgrade && upgraded < InpMaxPlacePerTick && orderPrice <= bid-buf) remove=true;
         if(remove && DeleteOrderSafe(gGridPendSellTk[i]))
         {
            if(upgrade)
            {
               if(InpEnableJournalLogs) PrintFormat((InpUseCenterReversalMultiplier ? "Grid multiplier replacement upgrade: %s %.2f -> %.2f lots." : "Depth doubled replacement upgrade: %s %.2f -> %.2f lots."),
                           LevelTag(false,i), gGridPendSellVol[i], want);
               upgraded++;
            }
            gGridPendSell[i]=false; gGridPendSellTk[i]=0;
            gGridPendSellVol[i]=0.0; gGridPendSellPrice[i]=0.0;
            gGridDirty=true;
         }
      }
   }
 
   if(gGridDirty) RebuildGridCache(); // a cancelled stop may already have become a position

   // First-time levels use the startup budget. Replacements retain the smaller
   // refill budget even if some distant initial levels are still safety-blocked.
   bool initialFormation = gInitialGridForming;
   int limit = InpMaxPlacePerTick;
   if(initialFormation && InpInitialPlacePerTick > 0) limit = InpInitialPlacePerTick;
   bool batchStarted = false;
   int placed = 0, refilled = 0;
   for(int i=1; i<=N && placed < limit; i++)
   {
      bool firstBuy = (initialFormation && !gGridInitialBuySeen[i]);
      bool buyAllowed = (!initialFormation || firstBuy || refilled < InpMaxPlacePerTick);
      double bp = gGridLevelBuyPrice[i];
      if(buyAllowed && !gGridPosBuy[i] && !gGridPendBuy[i] && bp >= ask + buf)
      {
         if(!batchStarted){ BeginExposureBatch(); batchStarted=true; }
         double dsl = (InpDisasterSL > 0 ? NormPrice(bp - InpDisasterSL) : 0.0);
         double lot = GridStopLot(true, i);
         if(PlaceBuyStop(lot, bp, dsl, LevelTag(true,i)))
         {
            gGridPendBuy[i]=true; gGridPendBuyTk[i]=trade.ResultOrder();
            gGridPendBuyVol[i]=lot; gGridPendBuyPrice[i]=bp;
            if(UseDepthDoubling() && gDblArmed && lot > TierLot(i)+1e-8 && InpEnableJournalLogs)
               PrintFormat("Depth doubled STOP placed: %s %.2f lots (base %.2f).",
                           LevelTag(true,i), lot, TierLot(i));
            if(initialFormation) gGridInitialBuySeen[i] = true;
            if(!firstBuy) refilled++;
            placed++;
         }
      }
 
      bool firstSell = (initialFormation && !gGridInitialSellSeen[i]);
      bool sellAllowed = (placed < limit &&
                          (!initialFormation || firstSell || refilled < InpMaxPlacePerTick));
      double sp = gGridLevelSellPrice[i];
      if(sellAllowed && !gGridPosSell[i] && !gGridPendSell[i] && sp <= bid - buf)
      {
         if(!batchStarted){ BeginExposureBatch(); batchStarted=true; }
         double dsl = (InpDisasterSL > 0 ? NormPrice(sp + InpDisasterSL) : 0.0);
         double lot = GridStopLot(false, i);
         if(PlaceSellStop(lot, sp, dsl, LevelTag(false,i)))
         {
            gGridPendSell[i]=true; gGridPendSellTk[i]=trade.ResultOrder();
            gGridPendSellVol[i]=lot; gGridPendSellPrice[i]=sp;
            if(UseDepthDoubling() && gDblArmed && lot > TierLot(i)+1e-8 && InpEnableJournalLogs)
               PrintFormat("Depth doubled STOP placed: %s %.2f lots (base %.2f).",
                           LevelTag(false,i), lot, TierLot(i));
            if(initialFormation) gGridInitialSellSeen[i] = true;
            if(!firstSell) refilled++;
            placed++;
         }
      }
   }
   if(batchStarted) EndExposureBatch();
   UpdateInitialGridFormation();
   if(gGridDirty) gGridWatchValid = false;
   else RefreshGridMaintenanceWatch(buf);
}
 
//--- FORM THE WHOLE GRID NOW, immediately from the locked center. Level 1 is
//--- Cycle-frozen center/side gaps (or the original fixed inputs). There is no
//--- near-price buffer or per-tick throttle here. Levels on the wrong side of
//--- price are rejected by the broker; MaintainGrid places them later when
//--- price is positioned correctly.
void FormGridNow()
{
   int    N   = GridOrdersPerSide();
   EnsureGridLevelPriceCache();
   trade.SetAsyncMode(InpAsyncPlacement);
   BeginExposureBatch();
   for(int i=1; i<=N; i++)
   {
      double bp = gGridLevelBuyPrice[i];
      double dslB = (InpDisasterSL > 0 ? NormPrice(bp - InpDisasterSL) : 0.0);
      double buyLot = GridStopLot(true, i);
      PlaceBuyStop(buyLot, bp, dslB, LevelTag(true,i));

      double sp = gGridLevelSellPrice[i];
      double dslS = (InpDisasterSL > 0 ? NormPrice(sp + InpDisasterSL) : 0.0);
      double sellLot = GridStopLot(false, i);
      PlaceSellStop(sellLot, sp, dslS, LevelTag(false,i));
   }
   EndExposureBatch();
   trade.SetAsyncMode(false);
   gGridDirty = true;
}
 

//+------------------------------------------------------------------+
//| Per-side fill depth (high-water; drives depth doubling)          |
//+------------------------------------------------------------------+
void UpdateFillDepthFromDeal(ulong dealTk)
{
   if(!IsMine(HistoryDealGetInteger(dealTk,DEAL_MAGIC),HistoryDealGetString(dealTk,DEAL_SYMBOL))) return;
   if(!IsCurrentCycleDeal(dealTk)) return;
   if(HistoryDealGetInteger(dealTk, DEAL_ENTRY) != DEAL_ENTRY_IN) return;
   string cmt = DealTag(dealTk);
   if(IsSubEngineCmt(cmt)) return;

   long type = HistoryDealGetInteger(dealTk, DEAL_TYPE);
   double price = HistoryDealGetDouble(dealTk, DEAL_PRICE);
   if(type == DEAL_TYPE_BUY)
   {
      int idx = ParseLevelTag(cmt, true);
      if(idx < 0) idx = GridLevelIndexFromPrice(true, price);
      if(idx >= 1 && idx <= GridOrdersPerSide())
      {
         if(idx > gBuyDepth) gBuyDepth = idx;
         if(InpUseCenterReversalMultiplier)
            RecordCenterReversalFill(true, idx, HistoryDealGetInteger(dealTk, DEAL_TIME_MSC));
      }
   }
   else if(type == DEAL_TYPE_SELL)
   {
      int idx = ParseLevelTag(cmt, false);
      if(idx < 0) idx = GridLevelIndexFromPrice(false, price);
      if(idx >= 1 && idx <= GridOrdersPerSide())
      {
         if(idx > gSellDepth) gSellDepth = idx;
         if(InpUseCenterReversalMultiplier)
            RecordCenterReversalFill(false, idx, HistoryDealGetInteger(dealTk, DEAL_TIME_MSC));
      }
   }
}

void UpdateFillDepths()
{
   int nb = 0, ns = 0;
   if(HistorySelect(gCycleStart, TimeCurrent()+1))
   {
      int td = HistoryDealsTotal();
      for(int i=0; i<td; i++)
      {
         ulong t = HistoryDealGetTicket(i);
         if(t == 0) continue;
         if(HistoryDealGetInteger(t,DEAL_MAGIC)  != InpMagic) continue;
         if(HistoryDealGetString(t,DEAL_SYMBOL)  != _Symbol)  continue;
         if(!IsCurrentCycleDeal(t)) continue;
         if(HistoryDealGetInteger(t,DEAL_ENTRY)  != DEAL_ENTRY_IN) continue;
         string cmt = DealTag(t);
         if(IsSubEngineCmt(cmt)) continue;  // sub-engine fills aren't grid depth
         long   dt = HistoryDealGetInteger(t,DEAL_TYPE);
         double p  = HistoryDealGetDouble(t,DEAL_PRICE);
         if(dt == DEAL_TYPE_BUY)
         {
            int idx = ParseLevelTag(cmt, true);
            if(idx < 0) idx = GridLevelIndexFromPrice(true, p);
            if(idx >= 1 && idx <= GridOrdersPerSide())
            {
               if(idx > nb) nb = idx;
            }
         }
         else if(dt == DEAL_TYPE_SELL)
         {
            int idx = ParseLevelTag(cmt, false);
            if(idx < 0) idx = GridLevelIndexFromPrice(false, p);
            if(idx >= 1 && idx <= GridOrdersPerSide())
            {
               if(idx > ns) ns = idx;
            }
         }
      }
   }
   if(nb > gBuyDepth)  gBuyDepth  = nb;   // high-water: never decreases mid-cycle
   if(ns > gSellDepth) gSellDepth = ns;
}
 
//+------------------------------------------------------------------+
//| TREND-ADAPTIVE EXIT                                              |
//|  Trend from 1-min candles (net close-to-close over N candles).    |
//|  The cycle's live exit target depends on trend, which side of     |
//|  center price is on, and whether the trend-side has open legs.    |
//+------------------------------------------------------------------+
//--- re-evaluate the 1-min trend (called once per new M1 bar)
void UpdateTrend()
{
   if(!InpUseTrend){ gTrendDir = 0; return; }
   double recent = iClose(_Symbol, PERIOD_M1, 1);                  // last closed candle
   double past   = iClose(_Symbol, PERIOD_M1, 1 + InpTrendCandles);// N candles before it
   if(recent <= 0 || past <= 0) return;                            // not enough history yet
   double move = recent - past;
   if(move >=  InpTrendPoints)      gTrendDir = +1;                // up
   else if(move <= -InpTrendPoints) gTrendDir = -1;                // down
   else                             gTrendDir =  0;                // no trend
}
 
//+------------------------------------------------------------------+
//| High-impact news lock                                           |
//+------------------------------------------------------------------+
bool LoadTesterNewsFile()
{
   ArrayResize(gNewsTimes, 0);
   ArrayResize(gNewsNames, 0);
   gNewsNextIndex = 0;
   gNewsFileReady = false;

   if(StringLen(InpNewsTesterFile) == 0)
   {
      if(InpEnableJournalLogs) Print("NEWS FILTER TESTER WARNING: no InpNewsTesterFile was supplied; news blocking is disabled in this test.");
      return false;
   }

   int handle = FileOpen(InpNewsTesterFile,
                         FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
   if(handle == INVALID_HANDLE)
   {
      if(InpEnableJournalLogs) PrintFormat("NEWS FILTER TESTER WARNING: cannot open Common Files\\%s (error %d); news blocking is disabled in this test.",
                  InpNewsTesterFile, GetLastError());
      return false;
   }

   datetime lastTime = 0;
   while(!FileIsEnding(handle))
   {
      string stamp = FileReadString(handle);
      string currency = FileReadString(handle);
      string name = FileReadString(handle);
      StringTrimLeft(stamp); StringTrimRight(stamp);
      StringTrimLeft(currency); StringTrimRight(currency);
      StringTrimLeft(name); StringTrimRight(name);
      datetime eventTime = StringToTime(stamp);
      if(eventTime <= 0 || currency != InpNewsCurrency) continue; // also skips a header row
      if(lastTime > 0 && eventTime < lastTime)
      {
         if(InpEnableJournalLogs) Print("NEWS FILTER TESTER WARNING: CSV rows are not chronological; news blocking is disabled in this test.");
         FileClose(handle);
         ArrayResize(gNewsTimes, 0);
         ArrayResize(gNewsNames, 0);
         return false;
      }
      int n = ArraySize(gNewsTimes);
      ArrayResize(gNewsTimes, n+1);
      ArrayResize(gNewsNames, n+1);
      gNewsTimes[n] = eventTime;
      gNewsNames[n] = (name == "" ? InpNewsCurrency+" high-impact event" : name);
      lastTime = eventTime;
   }
   FileClose(handle);
   gNewsFileReady = (ArraySize(gNewsTimes) > 0);
   if(gNewsFileReady)
   {
      if(InpEnableJournalLogs) PrintFormat("News tester file loaded: %d %s high-impact event(s).",
                  ArraySize(gNewsTimes), InpNewsCurrency);
   }
   else
   {
      if(InpEnableJournalLogs) PrintFormat("NEWS FILTER TESTER WARNING: no %s events found in %s; news blocking is disabled in this test.",
                  InpNewsCurrency, InpNewsTesterFile);
   }
   return gNewsFileReady;
}

bool FindTesterNewsWindow(datetime now, datetime &lockUntil, string &eventName)
{
   if(!gNewsFileReady) return false;
   int n = ArraySize(gNewsTimes);
   int afterSec = InpNewsMinutesAfter*60;
   int beforeSec = InpNewsMinutesBefore*60;
   while(gNewsNextIndex < n && gNewsTimes[gNewsNextIndex]+afterSec < now)
      gNewsNextIndex++;

   bool active = false;
   lockUntil = 0;
   for(int i=gNewsNextIndex; i<n; i++)
   {
      datetime start = gNewsTimes[i]-beforeSec;
      if(start > now) break;
      datetime finish = gNewsTimes[i]+afterSec;
      if(now <= finish)
      {
         active = true;
         if(finish >= lockUntil)
         {
            lockUntil = finish;
            eventName = gNewsNames[i];
         }
      }
   }
   return active;
}

bool FindLiveNewsWindow(datetime now, datetime &lockUntil, string &eventName, bool &queryOK)
{
   queryOK = false;
   MqlCalendarValue values[];
   datetime from = now-InpNewsMinutesAfter*60;
   datetime to = now+InpNewsMinutesBefore*60+1; // API right boundary is exclusive
   ResetLastError();
   int count = CalendarValueHistory(values, from, to, NULL, InpNewsCurrency);
   if(count < 0)
   {
      if(gNewsLastErrorLog == 0 || now-gNewsLastErrorLog >= 3600)
      {
         gNewsLastErrorLog = now;
         if(InpEnableJournalLogs) PrintFormat("NEWS FILTER WARNING: CalendarValueHistory failed (error %d); keeping the last known lock only.",
                     GetLastError());
      }
      return false;
   }
   queryOK = true;
   bool active = false;
   lockUntil = 0;
   for(int i=0; i<count; i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event)) continue;
      if(event.importance != CALENDAR_IMPORTANCE_HIGH) continue;
      datetime start = values[i].time-InpNewsMinutesBefore*60;
      datetime finish = values[i].time+InpNewsMinutesAfter*60;
      if(now < start || now > finish) continue;
      active = true;
      if(finish >= lockUntil)
      {
         lockUntil = finish;
         eventName = event.name;
      }
   }
   return active;
}

void UpdateNewsGuard()
{
   if(!InpUseNewsFilter)
   {
      gNewsLock = false;
      gNewsLockUntil = 0;
      gNewsEventName = "";
      return;
   }

   datetime now = TimeCurrent(); // MT5 calendar and tester CSV both use trade-server time
   int refreshSec = (gIsTester ? 1 : 15);
   if(gNewsLastRefresh > 0 && now-gNewsLastRefresh < refreshSec) return;
   gNewsLastRefresh = now;

   bool wasLocked = gNewsLock;
   bool active = false;
   bool queryOK = true;
   datetime until = 0;
   string name = "";
   if(gIsTester)
   {
      if(gNewsFileReady) active = FindTesterNewsWindow(now, until, name);
      else queryOK = false;
   }
   else
      active = FindLiveNewsWindow(now, until, name, queryOK);

   if(!queryOK)
   {
      if(now > gNewsLockUntil)
      {
         gNewsLock = false;
         gNewsEventName = "";
      }
      return;
   }

   gNewsLock = active;
   gNewsLockUntil = (active ? until : 0);
   gNewsEventName = (active ? name : "");
   if(active && !wasLocked)
   {
      string policy = (InpNewsCloseOpenCycle
                       ? "active cycle will be flattened"
                       : (InpNewsCancelPending
                          ? "active cycle positions continue; pending/refills are frozen"
                          : "active cycle continues normally; only a new cycle is blocked"));
      if(InpEnableJournalLogs) PrintFormat("HIGH-IMPACT NEWS LOCK: %s %s; %s until %s server time.",
                  InpNewsCurrency, gNewsEventName, policy,
                  TimeToString(gNewsLockUntil, TIME_DATE|TIME_MINUTES));
   }
   else if(!active && wasLocked && InpEnableJournalLogs)
      Print("High-impact news lock released.");
}

bool EntryRiskLocked()
{
   return (gBankHistoryDirty || (InpUseNewsFilter && gNewsLock));
}

bool ActiveCycleRiskLocked()
{
   if(gBankHistoryDirty) return true;
   if(InpUseBankProfitLock && InpBankLockFreezeAdds && gBankLockArmed) return true;
   if(!InpUseNewsFilter || !gNewsLock) return false;
   return (InpNewsCloseOpenCycle || InpNewsCancelPending);
}

bool EnforceEntryRiskLock(double cycleNet, bool cycleActive)
{
   bool news = (InpUseNewsFilter && gNewsLock);
   if(!news || !cycleActive) return false;
   if(InpNewsCancelPending) CancelAllPending();
   if(!InpNewsCloseOpenCycle) return false;

   if(InpEnableJournalLogs) PrintFormat("Emergency cycle exit (high-impact news): NET %.2f", cycleNet);
   CloseAllAndReset(cycleNet < 0.0);
   return true;
}

//--- does the basket currently hold open legs on the trend side?
//--- down-trend (dir -1) trend-side = SELL; up-trend (dir +1) = BUY.
bool TrendSideHasLegs(int dir)
{
   EnsureGridCacheSize();
   if(gGridDirty) RebuildGridCache();
   for(int i=1; i<=GridOrdersPerSide(); i++)
      if(dir > 0 ? gGridPosBuy[i] : gGridPosSell[i]) return true;
   RefreshPositionSnapshot();
   return(dir > 0 ? gPositionSnapshotManualBuyCount > 0 : gPositionSnapshotManualSellCount > 0);
}

double CostAdjustedTarget(double baseTarget)
{
   if(InpExitCostPerLot <= 0.0) return baseTarget;
   EnsureGridCacheSize();
   if(gGridDirty) RebuildGridCache();
   return baseTarget + gGridOpenVolume * InpExitCostPerLot;
}
 
//--- the live cycle exit target ($) given trend, price side, trend-side legs.
double CurrentTarget(double mid)
{
   int side = (mid >= gCenter ? +1 : -1);               // +1 above center, -1 below
 
   // ABSOLUTE priority: the previous cycle exited AGAINST the trend -> this whole
   // cycle uses the quick target, overriding every other rule below.
   if(InpUseAgainstTrend && gNextCycleQuick)
      return CostAdjustedTarget(InpAgainstTrendTgt);
 
   // next: if the previous cycle exited on a side and this cycle's price is on
   // that same side, take the quick +profit - overrides the trend.
   if(InpUseLastSide && gLastExitSide != 0 && side == gLastExitSide)
      return CostAdjustedTarget(InpTrendQuickProfit);

   if(!InpUseTrend)        return CostAdjustedTarget(InpNetBankTarget); // feature off -> normal +target
   if(gTrendDir == 0)      return CostAdjustedTarget(InpNoTrendTarget); // no trend -> configurable target
   if(side == gTrendDir)   return CostAdjustedTarget(InpNetBankTarget); // price on trend side -> full target
   // price on the opposite side of the trend:
   if(TrendSideHasLegs(gTrendDir)) return CostAdjustedTarget(InpBreakevenTarget);
   return CostAdjustedTarget(InpTrendQuickProfit);       // trend-side untouched -> quick +profit
}

bool UseBankLockCloseOpposite()
{
   return(InpUseBankProfitLock && InpBankLockFreezeAdds && InpBankLockCloseOpposite);
}

//--- Keep the arming-time direction through reversals and retry only eligible closes.
bool CloseBankLockOppositePositions()
{
   if(!UseBankLockCloseOpposite() || !gBankLockArmed || gBankLockRetainSide == 0 ||
      gAwaitFlat || gRecoveryBlocked) return false;
   SweepClosePending();
   ulong tickets[];
   int n=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket == 0 || !IsManagedPositionSelected()) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      if((gBankLockRetainSide > 0 && type != POSITION_TYPE_SELL) ||
         (gBankLockRetainSide < 0 && type != POSITION_TYPE_BUY) || IsClosePending(ticket)) continue;
      if(ArrayResize(tickets,n+1,32) != n+1) return false;
      tickets[n++]=ticket;
   }
   if(n == 0) return false;
   // Reconcile before evaluating another floor: asynchronous/partial closes
   // transfer floating P/L into the bank and their callbacks may still be queued.
   gBankHistoryDirty=true;
   BulkClosePositions(tickets,n);
   return true;
}

double CycleProfitValue(double cycleNet, double floating)
{
   return(InpUseTrailingStop ? cycleNet : floating);
}

//--- Optional cycle-level profit trailing. The normal fixed/trend target arms
//--- the lock instead of closing immediately. The floor can only move upward.
bool ManageBankProfitLock(double cycleNet, bool cycleActive, int openPositions, double mid)
{
   if(gBankHistoryDirty) return false; // do not act on an unconfirmed realized bank
   if(!cycleActive) return false;
   if(!InpUseTrailingStop && !gBankLockArmed && openPositions <= 0) return false;
   double profitValue=CycleProfitValue(cycleNet, (InpUseTrailingStop ? 0.0 : FloatingPnL()));

   if(!InpUseBankProfitLock)
   {
      double target = CurrentTarget(mid);
      if(profitValue < target) return false;
      CloseAllAndReset(!InpUseTrailingStop && cycleNet < 0.0);
      return true;
   }

   if(!gBankLockArmed)
   {
      double target = MathMax(CurrentTarget(mid), InpBankLockArmProfit);
      target = MathMax(target, InpBankLockMinProfit);
      if(profitValue < target) return false;

      gBankLockArmed = true;
      gBankLockPeak = profitValue;
      // Reaching the cycle target must protect that target. Giveback applies
      // only to additional profit: the floor never moves below this arm value.
      gBankLockFloor = MathMin(profitValue, target);
      if(UseBankLockCloseOpposite())
      {
         double price=NormPrice(mid), center=NormPrice(gCenter);
         gBankLockRetainSide=(price > center ? 1 : (price < center ? -1 : 0));
         if(InpEnableJournalLogs) Print("Profit-lock direction latched: ",
            (gBankLockRetainSide > 0 ? "keep BUY, close SELL" : (gBankLockRetainSide < 0 ? "keep SELL, close BUY" : "at center; retain both sides")),
            "; cancel pending orders on both sides and freeze new entries. Existing broker SLs remain unchanged.");
      }
      if(InpEnableJournalLogs) PrintFormat((InpUseTrailingStop ?
                  "Cycle bank lock armed: NET %.2f, protected target %.2f, locked floor %.2f." :
                  "Cycle floating lock armed: floating %.2f, protected target %.2f, locked floor %.2f."),
                  profitValue, target, gBankLockFloor);
      if(InpBankLockFreezeAdds) CancelAllPending(UseBankLockCloseOpposite());
      SavePersistentState(true);

      // With no live position there is nothing left to trail; bank the cycle.
      if(openPositions <= 0)
      {
         CloseAllAndReset(cycleNet < 0.0);
         return true;
      }
      return CloseBankLockOppositePositions();
   }

   if(InpBankLockFreezeAdds && CountMyPendings() > 0)
      CancelAllPending(UseBankLockCloseOpposite());

   if(profitValue > gBankLockPeak)
   {
      double oldFloor = gBankLockFloor;
      gBankLockPeak = profitValue;
      double candidate = MathMax(InpBankLockMinProfit,
                                 gBankLockPeak-InpBankLockGiveback);
      if(candidate > gBankLockFloor) gBankLockFloor = candidate;
      if(gBankLockFloor > gBankLockPeak) gBankLockFloor = gBankLockPeak;
      if(gBankLockFloor > oldFloor+0.01 && InpEnableJournalLogs)
         PrintFormat((InpUseTrailingStop ? "Cycle bank lock raised: peak %.2f, locked floor %.2f." :
                                          "Cycle floating lock raised: peak %.2f, locked floor %.2f."),
                     gBankLockPeak, gBankLockFloor);
      SavePersistentState(false);
   }

   // Require an actual retreat below the floor. This avoids an unchanged quote
   // closing immediately when the lock armed exactly at the protected target.
   if(openPositions <= 0 || profitValue < gBankLockFloor-0.01)
   {
      if(InpEnableJournalLogs) PrintFormat((InpUseTrailingStop ?
                  "Cycle bank lock exit: NET %.2f, peak %.2f, locked floor %.2f%s." :
                  "Cycle floating lock exit: floating %.2f, peak %.2f, locked floor %.2f%s."),
                  profitValue, gBankLockPeak, gBankLockFloor,
                  (profitValue < gBankLockFloor ? " (floor crossed)" : ""));
      CloseAllAndReset(cycleNet < 0.0);
      return true;
   }
   return CloseBankLockOppositePositions();
}

//--- deepest currently-OPEN grid level on a side (0 if none). Self-resetting:
//--- after a thin, the deep legs are gone so this drops, and the side must
//--- re-stretch to the trigger depth before it can thin again.
int DeepestOpenLevel(bool buySide)
{
   long want = (buySide ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
   int d = 0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(!IsMine(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue;
      if(PositionGetInteger(POSITION_TYPE)!=want) continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      string cmt  = PositionGetString(POSITION_COMMENT);
      if(IsSubEngineCmt(cmt)) continue;
      int idx = ParseLevelTag(cmt, buySide);
      if(idx < 0) idx = GridLevelIndexFromPrice(buySide, open);
      if(idx > d) d = idx;
   }
   return d;
}
 
//--- alternate-exit: close every other open position on the given side by rank
//--- (farthest from center first: close, skip, close, skip ...). Refill re-arms
//--- the vacated levels.
void AltExitSide(bool buySide)
{
   long want = (buySide ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
   ulong tks[]; int lvls[]; int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(!IsMine(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue;
      if(PositionGetInteger(POSITION_TYPE)!=want) continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      string cmt  = PositionGetString(POSITION_COMMENT);
      if(IsSubEngineCmt(cmt)) continue;
      int idx = ParseLevelTag(cmt, buySide);
      if(idx < 0) idx = GridLevelIndexFromPrice(buySide, open);
      ArrayResize(tks,n+1); ArrayResize(lvls,n+1); tks[n]=t; lvls[n]=idx; n++;
   }
   if(n==0) return;
   // sort by level descending (farthest from center first)
   for(int a=0;a<n-1;a++)
      for(int b=a+1;b<n;b++)
         if(lvls[b] > lvls[a])
         {
            int lt=lvls[a]; lvls[a]=lvls[b]; lvls[b]=lt;
            ulong tt=tks[a]; tks[a]=tks[b]; tks[b]=tt;
         }
   // close ranks 0,2,4,... (close, skip, close, skip)
   ulong cl[]; int m=0;
   for(int r=0;r<n;r+=2){ ArrayResize(cl,m+1); cl[m]=tks[r]; m++; }
   BulkClosePositions(cl,m);
}
 
//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
#define UIPFX "STRUI_"
 
string MoneyStr(double v){ string s=DoubleToString(v,2); return (v>0? "+"+s : s); }
color  PnLClr(double v){ return (v>=0 ? clrLime : clrTomato); }
 
int UILabelIndex(string key)
{
   for(int i=0; i<ArraySize(gUILabelCache); i++)
      if(gUILabelCache[i].key == key) return i;
   int n=ArraySize(gUILabelCache);
   if(ArrayResize(gUILabelCache,n+1,64) < 0) return -1;
   ZeroMemory(gUILabelCache[n]);
   gUILabelCache[n].key=key;
   gUILabelCache[n].x=-1; gUILabelCache[n].y=-1; gUILabelCache[n].size=-1;
   gUILabelCache[n].width=-1; gUILabelCache[n].height=-1;
   return n;
}

void ResetDashboardDisplay()
{
   ArrayResize(gUILabelCache,0);
   gUIChanged=false;
   gDashboardLastDraw=0;
   gDashboardLastDrawRevision=0;
   gDashboardHistoryDirty=true;
   gDashboardDetailsReady=false;
   gDashboardPaintPending=true;
   gDashboardChartWidth=0; gDashboardChartHeight=0;
   ArrayResize(gDashboardDetails,0);
   InvalidatePositionSnapshot();
}

void UILabel(string key,int x,int y,string text,color clr,int fs=9)
{
   int k=UILabelIndex(key);
   if(k < 0) return;
   string name = UIPFX+key;
   bool fresh=!gUILabelCache[k].created;
   if(fresh)
   {
      if(ObjectFind(0,name) < 0 && !ObjectCreate(0,name,OBJ_LABEL,0,0,0)) return;
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetString (0,name,OBJPROP_FONT,"Consolas");
      gUILabelCache[k].created=true;
   }
   if(fresh || gUILabelCache[k].x != x)
      if(ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x)) { gUILabelCache[k].x=x; gUIChanged=true; }
   if(fresh || gUILabelCache[k].y != y)
      if(ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y)) { gUILabelCache[k].y=y; gUIChanged=true; }
   if(fresh || gUILabelCache[k].size != fs)
      if(ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fs)) { gUILabelCache[k].size=fs; gUIChanged=true; }
   if(fresh || gUILabelCache[k].clr != clr)
      if(ObjectSetInteger(0,name,OBJPROP_COLOR,clr)) { gUILabelCache[k].clr=clr; gUIChanged=true; }
   if(fresh || gUILabelCache[k].text != text)
      if(ObjectSetString(0,name,OBJPROP_TEXT,text)) { gUILabelCache[k].text=text; gUIChanged=true; }
}
 
void UIPanelBG(int x,int y,int w,int h)
{
   int k=UILabelIndex("BG");
   if(k < 0) return;
   string name = UIPFX+"BG";
   bool fresh=!gUILabelCache[k].created;
   if(fresh)
   {
      if(ObjectFind(0,name) < 0 && !ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0)) return;
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,name,OBJPROP_BGCOLOR,C'20,24,32');
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrDimGray);
      gUILabelCache[k].created=true;
   }
   if(fresh || gUILabelCache[k].x != x)
      if(ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x)) { gUILabelCache[k].x=x; gUIChanged=true; }
   if(fresh || gUILabelCache[k].y != y)
      if(ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y)) { gUILabelCache[k].y=y; gUIChanged=true; }
   if(fresh || gUILabelCache[k].width != w)
      if(ObjectSetInteger(0,name,OBJPROP_XSIZE,w)) { gUILabelCache[k].width=w; gUIChanged=true; }
   if(fresh || gUILabelCache[k].height != h)
      if(ObjectSetInteger(0,name,OBJPROP_YSIZE,h)) { gUILabelCache[k].height=h; gUIChanged=true; }
}

int DashboardPositionIndex(long id)
{
   int size=ArraySize(gDashboardPositions), lo=0, hi=size;
   while(lo < hi)
   {
      int mid=lo+(hi-lo)/2;
      if(gDashboardPositions[mid].id < id) lo=mid+1; else hi=mid;
   }
   if(lo < size && gDashboardPositions[lo].id == id) return lo;
   if(ArrayResize(gDashboardPositions,size+1,128) < 0) return -1;
   for(int i=size; i>lo; i--) gDashboardPositions[i]=gDashboardPositions[i-1];
   ZeroMemory(gDashboardPositions[lo]);
   gDashboardPositions[lo].id=id;
   return lo;
}

bool RefreshDashboardHistory()
{
   if(gDashboardRevision != gCycleAccountingRevision)
   {
      gDashboardRevision=gCycleAccountingRevision;
      gDashboardHistoryDirty=true;
      ArrayResize(gDashboardPositions,0); ArrayResize(gDashboardRows,0);
      gDashboardSum=0.0; gDashboardBuy=0.0; gDashboardSell=0.0; gDashboardExited=0;
   }
   if(!gDashboardHistoryDirty) return gDashboardHistoryReady;
   gDashboardHistoryReady=false;
   if(!HistorySelect(gCycleStart,TimeCurrent()+1)) return false;
   ArrayResize(gDashboardPositions,0); ArrayResize(gDashboardRows,0);
   int total=HistoryDealsTotal();
   for(int i=0; i<total; i++)
   {
      ulong t=HistoryDealGetTicket(i);
      if(t == 0 || !IsAccountingDeal(t)) continue;
      if(!IsCurrentCycleDeal(t)) continue;
      int k=DashboardPositionIndex(HistoryDealGetInteger(t,DEAL_POSITION_ID));
      if(k < 0) return false;
      long entry=HistoryDealGetInteger(t,DEAL_ENTRY);
      gDashboardPositions[k].net += DealNet(t);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
         gDashboardPositions[k].side=(HistoryDealGetInteger(t,DEAL_TYPE) == DEAL_TYPE_BUY ? 0 : 1);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
      {
         gDashboardPositions[k].exited=true;
         long ms=HistoryDealGetInteger(t,DEAL_TIME_MSC);
         if(ms <= 0) ms=HistoryDealGetInteger(t,DEAL_TIME)*1000;
         if(ms > gDashboardPositions[k].closeMsc) gDashboardPositions[k].closeMsc=ms;
      }
   }
   gDashboardSum=0.0; gDashboardBuy=0.0; gDashboardSell=0.0; gDashboardExited=0;
   for(int k=0; k<ArraySize(gDashboardPositions); k++)
   {
      gDashboardSum += gDashboardPositions[k].net;
      if(gDashboardPositions[k].side == 0) gDashboardBuy += gDashboardPositions[k].net;
      else gDashboardSell += gDashboardPositions[k].net;
      if(!gDashboardPositions[k].exited) continue;
      gDashboardExited++;
      // Keep only the displayed newest rows; never sort the full closed basket.
      int n=ArraySize(gDashboardRows), insert=0;
      while(insert < n && gDashboardPositions[gDashboardRows[insert]].closeMsc >= gDashboardPositions[k].closeMsc) insert++;
      if(insert >= InpMaxRows) continue;
      int next=(int)MathMin(n+1,InpMaxRows);
      if(ArrayResize(gDashboardRows,next,32) < 0) return false;
      for(int j=next-1; j>insert; j--) gDashboardRows[j]=gDashboardRows[j-1];
      gDashboardRows[insert]=k;
   }
   if(gBankScanFailed) return false;
   gDashboardHistoryDirty=false;
   gDashboardHistoryReady=true;
   return true;
}
 
void DrawLegacyDashboard(double bid,double ask)
{
   if(!InpShowPanel || (gIsTester && !gIsVisualTester)) return;
   if(gIsTester && gIsVisualTester)
      for(int k=0; k<ArraySize(gUILabelCache); k++)
         if(gUILabelCache[k].created && gUILabelCache[k].key == "M_reset" &&
            ObjectGetInteger(0,UIPFX+"M_reset",OBJPROP_STATE)) DashboardHandleClick(UIPFX+"M_reset");
   datetime updated = TimeCurrent();
   if(updated == gDashboardLastDraw && gDashboardLastDrawRevision == gCycleAccountingRevision) return;
   gDashboardLastDraw = updated;
   gDashboardLastDrawRevision = gCycleAccountingRevision;
 
   bool historyReady=RefreshDashboardHistory();
   double listSum=gDashboardSum, realBuy=gDashboardBuy, realSell=gDashboardSell;
   int exited=gDashboardExited;
   RefreshPositionSnapshot();
   double floatBuy=gPositionSnapshotBuy, floatSell=gPositionSnapshotSell;
 
   double realizedBank = CycleRealized();
   double floatTotal   = floatBuy + floatSell;
   double net          = realizedBank + floatTotal;
 
   // ---- draw ----
   int x=InpPanelX, y=InpPanelY, lh=15, pad=8;
   int shown = ArraySize(gDashboardRows);
   int headLines = 21;                       // title..column-header, including snapshot time
   int h = pad*2 + (headLines + shown)*lh;
   UIPanelBG(x-4, y-4, 250, h);
 
   int xx=x, yy=y;
   UILabel("t0", xx,yy, "STRADDLE NET-BANK ("+AccountInfoString(ACCOUNT_CURRENCY)+")", clrWhite, 10); yy+=lh+2;
   string cycleStartText = TimeToString(gCycleStart,TIME_DATE|TIME_SECONDS);
   if(gCycleStartMsc > 0) cycleStartText += StringFormat(".%03d", (int)(gCycleStartMsc%1000));
   UILabel("t1", xx,yy, "Cycle: "+cycleStartText, clrSilver,8); yy+=lh;
   UILabel("t2", xx,yy, (InpUseTrailingStop ? "Target : " : "Float target : ")+DoubleToString(InpNetBankTarget,2), clrSilver,9); yy+=lh;
   string netText="NET    : "+MoneyStr(net);
   if(InpUseTrailingStop) netText += "  ("+DoubleToString(100.0*net/(InpNetBankTarget==0?1:InpNetBankTarget),0)+"%)";
   UILabel("t3", xx,yy, netText, PnLClr(net),10); yy+=lh+2;
   UILabel("t4", xx,yy, "Realized(bank): "+MoneyStr(realizedBank), PnLClr(realizedBank),9); yy+=lh;
   UILabel("t5", xx,yy, "   B "+MoneyStr(realBuy)+"   S "+MoneyStr(realSell), clrSilver,8); yy+=lh;
   UILabel("t6", xx,yy, "Floating(open): "+MoneyStr(floatTotal), PnLClr(floatTotal),9); yy+=lh;
   UILabel("t7", xx,yy, "   B "+MoneyStr(floatBuy)+"   S "+MoneyStr(floatSell), clrSilver,8); yy+=lh;
   color chk = (MathAbs(listSum-realizedBank)<0.01 ? clrLime : clrOrange);
   string historyText = (historyReady ? "Exits: "+IntegerToString(exited)+"  History NET: "+MoneyStr(listSum)
                                      : "History unavailable (bank retained)");
   UILabel("t8", xx,yy, historyText, (historyReady ? chk : clrOrange),9); yy+=lh;
   UILabel("t8u", xx,yy, "Updated: "+TimeToString(updated,TIME_SECONDS), clrSilver,8); yy+=lh;
   string dstr = "Daily : "+MoneyStr(gDailyPnL)+(InpUseDailyTarget ? " / "+DoubleToString(InpDailyTarget,2) : "  (target off)");
   if(InpUseDailyTarget && gCycleOpen && gDailyPnL >= InpDailyTarget)
      dstr += "  [finish cycle]";
   UILabel("t8b", xx,yy, dstr, PnLClr(gDailyPnL),9); yy+=lh;
   double monthNet = gMonthlyPnL + floatTotal;
   string mstr;
   if(InpUseMonthlyCapitalTarget)
      mstr = "Month cap: "+DoubleToString(InpMonthlyCapital+monthNet,2)+
             " / "+DoubleToString(InpMonthlyCapital*InpMonthlyCapitalMultiple,2);
   else
      mstr = "Month P/L: "+MoneyStr(monthNet)+"  (target off)";
   UILabel("t8m", xx,yy, mstr, PnLClr(monthNet),9); yy+=lh;
   string haltText = "";
   if(gHaltedMonth && gCycleOpen) haltText = ">> MONTH TARGET: finish current cycle";
   else if(gHaltedMonth) haltText = ">> HALTED: monthly target until next month";
   else if(gHaltedToday) haltText = ">> HALTED: flat until next day";
   UILabel("t8c", xx,yy, haltText, clrOrange,9); yy+=lh;
   string wtag = "  [waiting]";
   if(!gCycleOpen && gCooldownUntil > TimeCurrent())
      wtag = StringFormat("  [cooldown %ds]", (int)(gCooldownUntil - TimeCurrent()));
   string sst = "Session: "+gSessTxt+(gCycleOpen ? "  [cycle running]" : wtag);
   if(IsFridayCutoff()) sst += "  [FRI STOP]";
   UILabel("t8d", xx,yy, sst, (IsFridayCutoff() ? clrOrange : (gCycleOpen || StringFind(gSessTxt,"OPEN")>=0 ? clrSilver : clrOrange)),8); yy+=lh;
   string gridText = StringFormat("Fixed geo: C %.2f  G %.2f  T %.2f",
                                 InpCenterSideGap, InpGridGap, InpArmDistance);
   if(!InpUseTrailingStop) gridText=StringFormat("Fixed geo: C %.2f  G %.2f  T off", InpCenterSideGap, InpGridGap);
   UILabel("t8a", xx,yy, gridText, clrSilver,8); yy+=lh;
   string riskText = "Risk lock: clear";
   if(gBankHistoryDirty) riskText = "Risk lock: BANK HISTORY PENDING";
   else if(InpUseBankProfitLock && InpBankLockFreezeAdds && gBankLockArmed)
      riskText = (InpUseTrailingStop ? "Risk lock: BANK PROFIT (adds frozen)" : "Risk lock: FLOAT PROFIT (adds frozen)");
   else if(gNewsLock) riskText = "Risk lock: NEWS until "+TimeToString(gNewsLockUntil,TIME_MINUTES);
   UILabel("t8r", xx,yy, riskText, (ActiveCycleRiskLocked() || EntryRiskLocked() ? clrTomato : clrSilver),8); yy+=lh;
   string tr;
   if(!InpUseTrend)        tr = "Trend: off";
   else if(gTrendDir > 0)  tr = "Trend: UP";
   else if(gTrendDir < 0)  tr = "Trend: DOWN";
   else                    tr = "Trend: none";
   if(InpUseAltExit)
   {
      string ax="";
      if(gAltBuyDone) ax+=" Bdone"; else if(DeepestOpenLevel(true)>=InpAltDepthTrigger) ax+=" Brdy";
      if(gAltSellDone) ax+=" Sdone"; else if(DeepestOpenLevel(false)>=InpAltDepthTrigger) ax+=" Srdy";
      if(StringLen(ax)>0) tr += "  altX:"+ax;
   }
   else if(InpUseAltExit && (gBuyDepth>=InpAltDepthTrigger || gSellDepth>=InpAltDepthTrigger)) tr += "  altX:armed";
   if(UseDepthDoubling() && gDblArmed) tr += "  2x:ON";
   if(InpUseCenterReversalMultiplier) tr += "  "+ReversalMultiplierStatus();
   if(InpUseLastSide && gLastExitSide!=0) tr += (gLastExitSide>0? "  last:BUY" : "  last:SELL");
   if(InpUseAgainstTrend && gNextCycleQuick) tr += "  vsTrend:+"+DoubleToString(InpAgainstTrendTgt,0);
   if(InpUseDepthDD && gDDArmed) tr += StringFormat("  DD@%.0f->%.0f", gDDMarkNet, gDDMarkNet*InpDDFraction);
   else if(InpUseDepthDD && gDDEligible) tr += "  DD:wait-center";
   color trc = (gTrendDir!=0 ? clrGold : clrSilver);
   UILabel("t8e", xx,yy, tr, trc,8); yy+=lh;
   double tgt = CurrentTarget((bid+ask)/2.0);
   if(InpUseBankProfitLock && !gBankLockArmed)
   {
      tgt = MathMax(tgt, InpBankLockArmProfit);
      tgt = MathMax(tgt, InpBankLockMinProfit);
   }
   string tgtxt;
   color tgtColor = clrSilver;
   if(InpUseBankProfitLock)
   {
      if(gBankLockArmed)
      {
         tgtxt = StringFormat((InpUseTrailingStop ? "Bank lock: peak %+.2f  floor %+.2f" : "Float lock: peak %+.2f  floor %+.2f"),
                              gBankLockPeak, gBankLockFloor);
         tgtColor = clrLime;
      }
      else
         tgtxt = StringFormat((InpUseTrailingStop ? "Bank lock: waiting for %+.2f" : "Float lock: waiting for %+.2f"), tgt);
   }
   else
      tgtxt = StringFormat((InpUseTrailingStop ? "Target: %+.0f" : "Float target: %+.0f"), tgt);
   UILabel("t8f", xx,yy, tgtxt, tgtColor,8); yy+=lh;
   double effectiveLoss = EffectiveCycleLossLimit();
   string ls = (effectiveLoss > 0.0 ? "Loss cutout: -"+DoubleToString(effectiveLoss,0)
                                    : "Loss cutout: off");
   if(InpUseFloatingLoss) ls += "  Float: -"+DoubleToString(InpFloatingLossLimit,0);
   bool lossWarning=(effectiveLoss > 0.0 && net <= -effectiveLoss*0.5);
   if(InpUseFloatingLoss && floatTotal <= -InpFloatingLossLimit*0.5) lossWarning=true;
   color lsc=(lossWarning ? clrTomato : clrSilver);
   UILabel("t8g", xx,yy, ls, lsc,8); yy+=lh;
   UILabel("t9", xx,yy, "-- exited orders (ticket/side/pnl) --", clrGray,8); yy+=lh;
 
   for(int r=0; r<InpMaxRows; r++)
   {
      string key="r"+IntegerToString(r);
      if(r < shown)
      {
         int k = gDashboardRows[r];
         string sd = (gDashboardPositions[k].side==0 ? "BUY " : "SELL");
         UILabel(key, xx,yy, "#"+IntegerToString(gDashboardPositions[k].id)+"  "+sd+"  "+MoneyStr(gDashboardPositions[k].net), PnLClr(gDashboardPositions[k].net),8);
         yy+=lh;
      }
      else UILabel(key, xx,yy, "", clrNONE,8);   // blank unused row slots
   }
 
   gDashboardScale=1.0;
   DrawCycleResetButton(xx,yy+6,88,22);
   UIPanelBG(x-4,y-4,250,yy-y+36);
   if(gUIChanged) { ChartRedraw(0); gUIChanged=false; }
}
 
//+------------------------------------------------------------------+
//| Responsive dashboard: display-only objects and cached history   |
//+------------------------------------------------------------------+
#define UI_BG      C'7,17,28'
#define UI_PANEL   C'10,27,43'
#define UI_BORDER  C'34,70,95'
#define UI_BLUE    C'64,181,242'
#define UI_TEXT    C'231,240,247'
#define UI_MUTED   C'146,169,188'
#define UI_GREEN   C'48,222,152'
#define UI_RED     C'255,100,115'
#define UI_AMBER   C'255,199,88'

int DashboardPixel(int value)
{
   return (int)MathRound(value*gDashboardScale);
}

int DashboardTextWidth(string text,int fs,string font="Arial")
{
   uint width=0,height=0;
   if(TextSetFont(font,-fs*10,0) && TextGetSize(text,width,height))
      return (int)MathCeil(width/gDashboardScale);
   return (int)MathCeil(StringLen(text)*fs*0.85);
}

string DashboardFitText(string text,int width,int fs,string font)
{
   if(width <= 0) return "";
   if(DashboardTextWidth(text,fs,font) <= width) return text;
   if(DashboardTextWidth("...",fs,font) > width) return "";
   int lo=0,hi=StringLen(text);
   while(lo < hi)
   {
      int mid=(lo+hi+1)/2;
      if(DashboardTextWidth(StringSubstr(text,0,mid)+"...",fs,font) <= width) lo=mid;
      else hi=mid-1;
   }
   return StringSubstr(text,0,lo)+"...";
}

int DashboardObject(string key,int kind,int x,int y,int w,int h,color ink,color fill,string tip="")
{
   int k=UILabelIndex("M_"+key);
   if(k < 0) return -1;
   gUILabelCache[k].touched=true;
   string name=UIPFX+gUILabelCache[k].key;
   bool fresh=!gUILabelCache[k].created;
   if(fresh)
   {
      if(ObjectFind(0,name) < 0 && !ObjectCreate(0,name,(ENUM_OBJECT)kind,0,0,0)) return -1;
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_ZORDER,(kind == OBJ_BUTTON ? 10 : 0));
      if(kind == OBJ_RECTANGLE_LABEL) ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      gUILabelCache[k].created=true;
      gUILabelCache[k].kind=kind;
   }
   int px=DashboardPixel(x),py=DashboardPixel(y),pw=DashboardPixel(w),ph=DashboardPixel(h);
   if(fresh || gUILabelCache[k].x != px)
      if(ObjectSetInteger(0,name,OBJPROP_XDISTANCE,px)) { gUILabelCache[k].x=px; gUIChanged=true; }
   if(fresh || gUILabelCache[k].y != py)
      if(ObjectSetInteger(0,name,OBJPROP_YDISTANCE,py)) { gUILabelCache[k].y=py; gUIChanged=true; }
   if(kind != OBJ_LABEL)
   {
      if(fresh || gUILabelCache[k].width != pw)
         if(ObjectSetInteger(0,name,OBJPROP_XSIZE,pw)) { gUILabelCache[k].width=pw; gUIChanged=true; }
      if(fresh || gUILabelCache[k].height != ph)
         if(ObjectSetInteger(0,name,OBJPROP_YSIZE,ph)) { gUILabelCache[k].height=ph; gUIChanged=true; }
      if(fresh || gUILabelCache[k].fill != fill)
         if(ObjectSetInteger(0,name,OBJPROP_BGCOLOR,fill)) { gUILabelCache[k].fill=fill; gUIChanged=true; }
   }
   if(fresh || gUILabelCache[k].clr != ink)
      if(ObjectSetInteger(0,name,OBJPROP_COLOR,ink)) { gUILabelCache[k].clr=ink; gUIChanged=true; }
   if(fresh || gUILabelCache[k].tip != tip)
      if(ObjectSetString(0,name,OBJPROP_TOOLTIP,(tip == "" ? "\n" : tip))) { gUILabelCache[k].tip=tip; gUIChanged=true; }
   return k;
}

void DashboardBox(string key,int x,int y,int w,int h,color fill,color border)
{
   if(w > 0 && h > 0) DashboardObject(key,OBJ_RECTANGLE_LABEL,x,y,w,h,border,fill);
}

void DashboardText(string key,int x,int y,int w,string text,color ink,int fs=10,bool bold=false,bool right=false,string tip="")
{
   string font=(bold ? "Arial Bold" : "Arial");
   int k=UILabelIndex("M_"+key);
   if(k < 0) return;
   bool fresh=!gUILabelCache[k].created;
   string fitted=gUILabelCache[k].text;
   if(fresh || gUILabelCache[k].raw != text || gUILabelCache[k].fitWidth != w ||
      gUILabelCache[k].size != fs || gUILabelCache[k].font != font)
      fitted=DashboardFitText(text,w,fs,font);
   int dx=(right ? (int)MathMax(0,w-DashboardTextWidth(fitted,fs,font)) : 0);
   if(DashboardObject(key,OBJ_LABEL,x+dx,y,w,0,ink,UI_BG,(tip == "" ? text : tip)) < 0) return;
   string name=UIPFX+gUILabelCache[k].key;
   if(fresh || gUILabelCache[k].font != font)
      if(ObjectSetString(0,name,OBJPROP_FONT,font)) { gUILabelCache[k].font=font; gUIChanged=true; }
   if(fresh || gUILabelCache[k].size != fs)
      if(ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fs)) { gUILabelCache[k].size=fs; gUIChanged=true; }
   if(fresh || gUILabelCache[k].text != fitted)
      if(ObjectSetString(0,name,OBJPROP_TEXT,fitted)) { gUILabelCache[k].text=fitted; gUIChanged=true; }
   gUILabelCache[k].raw=text; gUILabelCache[k].fitWidth=w;
}

void DashboardButton(string key,int x,int y,int w,int h,string text,string tip,bool selected=false,bool enabled=true)
{
   int cached=UILabelIndex("M_"+key);
   if(cached < 0) return;
   bool fresh=!gUILabelCache[cached].created;
   int k=DashboardObject(key,OBJ_BUTTON,x,y,w,h,(enabled ? (selected ? UI_BLUE : UI_TEXT) : UI_MUTED),
                         (enabled ? (selected ? C'18,48,70' : UI_PANEL) : UI_BG),tip);
   if(k < 0) return;
   string name=UIPFX+gUILabelCache[k].key;
   if(gUILabelCache[k].font != "Arial")
      if(ObjectSetString(0,name,OBJPROP_FONT,"Arial")) { gUILabelCache[k].font="Arial"; gUIChanged=true; }
   if(gUILabelCache[k].size != 9)
      if(ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9)) { gUILabelCache[k].size=9; gUIChanged=true; }
   string fitted=DashboardFitText(text,w-8,9,"Arial");
   if(fresh || gUILabelCache[k].text != fitted)
      if(ObjectSetString(0,name,OBJPROP_TEXT,fitted)) { gUILabelCache[k].text=fitted; gUIChanged=true; }
   if(fresh) ObjectSetInteger(0,name,OBJPROP_STATE,false);
}

void DrawCycleResetButton(int x,int y,int w,int h)
{
   string reason=DashboardResetBlockReason();
   string tip=(reason == "" ? "Cancel pending cycle orders and rebuild at a fresh center; open positions block reset." : reason);
   DashboardButton("reset",x,y,w,h,(gDashboardResetPending ? "Resetting" : "Reset"),tip,false,reason == "");
}

void DashboardEndFrame()
{
   for(int k=0; k<ArraySize(gUILabelCache); k++)
   {
      if(!gUILabelCache[k].created || gUILabelCache[k].touched || StringFind(gUILabelCache[k].key,"M_") != 0) continue;
      if(ObjectDelete(0,UIPFX+gUILabelCache[k].key))
      {
         gUILabelCache[k].created=false;
         gUIChanged=true;
      }
   }
   if(gUIChanged) { ChartRedraw(0); gUIChanged=false; }
}

color DashboardPnLColor(double value)
{
   return (value > 0.005 ? UI_GREEN : (value < -0.005 ? UI_RED : UI_TEXT));
}

string DashboardLots(double value)
{
   int digits=2;
   for(int i=2; i<8 && gSymbolVolumeStep > 0.0 && NormalizeDouble(gSymbolVolumeStep,i) != gSymbolVolumeStep; i++) digits=i+1;
   return DoubleToString(value,digits);
}

bool DashboardLoadDetails()
{
   int count=ArraySize(gDashboardPositions);
   if(ArrayResize(gDashboardDetails,count) < 0) return false;
   for(int i=0; i<count; i++) ZeroMemory(gDashboardDetails[i]);
   // RefreshDashboardHistory has already selected and filtered this cycle.
   // Keep its position-level NET (including entry costs), and add exit VWAP/volume.
   for(int i=0; i<HistoryDealsTotal(); i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(ticket == 0 || !IsAccountingDeal(ticket)) continue;
      if(!IsCurrentCycleDeal(ticket)) continue;
      long entry=HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT) continue;
      long id=HistoryDealGetInteger(ticket,DEAL_POSITION_ID);
      int lo=0,hi=count;
      while(lo < hi)
      {
         int mid=lo+(hi-lo)/2;
         if(gDashboardPositions[mid].id < id) lo=mid+1; else hi=mid;
      }
      if(lo >= count || gDashboardPositions[lo].id != id) continue;
      double volume=HistoryDealGetDouble(ticket,DEAL_VOLUME);
      gDashboardDetails[lo].closedVolume += volume;
      gDashboardDetails[lo].priceVolume += volume*HistoryDealGetDouble(ticket,DEAL_PRICE);
   }
   return true;
}

void DashboardActivity(int x,int y,int w,int h,double floatBuy,double floatSell,bool historyReady,bool performance=false)
{
   DashboardBox("activity",x,y,w,h,UI_PANEL,UI_BORDER);
   bool shortPanel=(h < 190);
   DashboardText("activity_title",x+16,y+8,w-32,(performance ? "TRADE ACTIVITY / PERFORMANCE" : "TRADE ACTIVITY"),UI_BLUE,(shortPanel ? 9 : 11),true);
   DashboardBox("activity_line",x+16,y+(shortPanel ? 24 : 38),w-32,1,UI_BORDER,UI_BORDER);
   int buys=0,sells=0,pendingBuy=0,pendingSell=0;
   double buyLots=0.0,sellLots=0.0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket == 0 || !IsCyclePositionSelected()) continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) { buys++; buyLots+=PositionGetDouble(POSITION_VOLUME); }
      else { sells++; sellLots+=PositionGetDouble(POSITION_VOLUME); }
   }
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket == 0 || !IsCycleOrderSelected()) continue;
      ENUM_ORDER_TYPE kind=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(kind == ORDER_TYPE_BUY_STOP || kind == ORDER_TYPE_BUY_LIMIT || kind == ORDER_TYPE_BUY_STOP_LIMIT) pendingBuy++;
      else if(kind == ORDER_TYPE_SELL_STOP || kind == ORDER_TYPE_SELL_LIMIT || kind == ORDER_TYPE_SELL_STOP_LIMIT) pendingSell++;
   }
   int row=y+(shortPanel ? 30 : 50),step=(int)MathMax(16,MathMin(32,(h-(shortPanel ? 48 : 68))/4));
   int labelWidth=(int)MathMin(102,w*0.32),valueWidth=w-32-labelWidth;
   DashboardText("buy_label",x+16,row,labelWidth,"BUY OPEN",UI_GREEN,9,true);
   DashboardText("buy_value",x+16+labelWidth,row,valueWidth,IntegerToString(buys)+" | "+DashboardLots(buyLots)+" lots | "+MoneyStr(floatBuy),DashboardPnLColor(floatBuy),10,false,true);
   row+=step;
   DashboardText("sell_label",x+16,row,labelWidth,"SELL OPEN",UI_RED,9,true);
   DashboardText("sell_value",x+16+labelWidth,row,valueWidth,IntegerToString(sells)+" | "+DashboardLots(sellLots)+" lots | "+MoneyStr(floatSell),DashboardPnLColor(floatSell),10,false,true);
   row+=step;
   DashboardText("pending_label",x+16,row,labelWidth,"PENDING",UI_MUTED,9);
   DashboardText("pending_value",x+16+labelWidth,row,valueWidth,"BUY "+IntegerToString(pendingBuy)+" / SELL "+IntegerToString(pendingSell),UI_TEXT,10,false,true);
   row+=step;
   DashboardText("exits_label",x+16,row,labelWidth,"WITH EXITS",UI_MUTED,9);
   DashboardText("exits_value",x+16+labelWidth,row,valueWidth,(historyReady ? IntegerToString(gDashboardExited)+" positions" : "History pending"),(historyReady ? UI_TEXT : UI_AMBER),10,false,true);
   row+=step;
   DashboardText("history_label",x+16,row,labelWidth,"HISTORY NET",UI_MUTED,9);
   DashboardText("history_value",x+16+labelWidth,row,valueWidth,(historyReady ? MoneyStr(gDashboardSum) : "Unavailable"),(historyReady ? DashboardPnLColor(gDashboardSum) : UI_AMBER),11,true,true);
   if(performance && row+68 < y+h)
   {
      row+=step;
      DashboardText("compact_daily",x+16,row,w-32,"Daily realized  "+MoneyStr(gDailyPnL),DashboardPnLColor(gDailyPnL),10);
      row+=step;
      double monthNet=gMonthlyPnL+floatBuy+floatSell;
      DashboardText("compact_month",x+16,row,w-32,"Month NET  "+MoneyStr(monthNet),DashboardPnLColor(monthNet),10);
   }
}

void DashboardPerformance(int x,int y,int w,int h,double floating,double target)
{
   DashboardBox("performance",x,y,w,h,UI_PANEL,UI_BORDER);
   if(h < 230)
   {
      DashboardText("performance_title",x+16,y+8,w-32,"PERFORMANCE",UI_BLUE,9,true);
      string labels[]={"Daily realized","Daily target","Month NET","Month capital","Active target"};
      string values[5];
      values[0]=MoneyStr(gDailyPnL);
      values[1]=(InpUseDailyTarget ? DoubleToString(InpDailyTarget,2) : "OFF");
      values[2]=MoneyStr(gMonthlyPnL+floating);
      values[3]=(InpUseMonthlyCapitalTarget ? DoubleToString(InpMonthlyCapital+gMonthlyPnL+floating,2)+" / "+DoubleToString(InpMonthlyCapital*InpMonthlyCapitalMultiple,2) : "Target OFF");
      values[4]=DoubleToString(target,2)+(InpUseTrailingStop ? " NET" : " floating");
      int step=(int)MathMax(16,MathMin(30,(h-48)/4)),labelWidth=(int)(w*0.40);
      for(int i=0; i<5; i++)
      {
         DashboardText("perf_key"+IntegerToString(i),x+16,y+30+i*step,labelWidth-20,labels[i],UI_MUTED,8);
         DashboardText("perf_value"+IntegerToString(i),x+labelWidth,y+30+i*step,w-labelWidth-16,values[i],(i==0 ? DashboardPnLColor(gDailyPnL) : (i==2 ? DashboardPnLColor(gMonthlyPnL+floating) : UI_TEXT)),9,false,true);
      }
      return;
   }
   DashboardText("performance_title",x+16,y+12,w-32,"PERFORMANCE",UI_BLUE,11,true);
   DashboardBox("performance_line",x+16,y+38,w-32,1,UI_BORDER,UI_BORDER);
   DashboardText("daily_label",x+16,y+48,w-32,"DAILY REALIZED",UI_MUTED,9);
   DashboardText("daily_value",x+16,y+66,w-32,MoneyStr(gDailyPnL),DashboardPnLColor(gDailyPnL),20,true);
   string daily=(InpUseDailyTarget ? "Target "+DoubleToString(InpDailyTarget,2) : "Target OFF");
   if(InpUseDailyTarget && gCycleOpen && gDailyPnL >= InpDailyTarget) daily+=" | finish cycle";
   DashboardText("daily_target",x+16,y+98,w-32,daily,UI_MUTED,9);
   double monthNet=gMonthlyPnL+floating;
   DashboardText("month_label",x+16,y+126,w-32,"MONTH NET",UI_MUTED,9);
   DashboardText("month_value",x+16,y+144,w-32,MoneyStr(monthNet),DashboardPnLColor(monthNet),20,true);
   string month=(InpUseMonthlyCapitalTarget ? "Capital "+DoubleToString(InpMonthlyCapital+monthNet,2)+" / "+DoubleToString(InpMonthlyCapital*InpMonthlyCapitalMultiple,2) : "Target OFF");
   DashboardText("month_target",x+16,y+176,w-32,month,UI_MUTED,9);
   DashboardText("active_target",x+16,y+206,w-32,(InpUseTrailingStop ? "NET target  " : "Floating target  ")+DoubleToString(target,2),UI_TEXT,10,true);
}

void DashboardStatus(int x,int y,int w,int h,double net,double floating,double target)
{
   DashboardBox("status",x,y,w,h,UI_PANEL,UI_BORDER);
   bool shortPanel=(h < 230);
   DashboardText("status_title",x+16,y+8,w-32,"SYSTEM STATUS",UI_BLUE,(shortPanel ? 9 : 11),true);
   DashboardBox("status_line",x+16,y+(shortPanel ? 24 : 38),w-32,1,UI_BORDER,UI_BORDER);
   string labels[]={"Session","Fixed geometry","Risk lock","Trend / multipliers","Profit lock","Loss cutout"};
   string values[6]; color inks[6];
   for(int i=0; i<6; i++) inks[i]=UI_TEXT;
   values[0]=(InpUseSessionFilter ? gSessTxt : "OFF");
   if(gCycleOpen) values[0]+=" | cycle running";
   if(IsFridayCutoff()) values[0]+=" | Friday stop";
   else if(IsMondayStartDelay()) values[0]+=" | Monday delay";
   values[1]="C "+DoubleToString(InpCenterSideGap,2)+"  G "+DoubleToString(InpGridGap,2)+
             (InpUseTrailingStop ? "  T "+DoubleToString(InpArmDistance,2) : "  T OFF");
   values[2]="Clear";
   if(gBankHistoryDirty) values[2]="Bank history pending";
   else if(InpUseBankProfitLock && InpBankLockFreezeAdds && gBankLockArmed) values[2]="Profit lock: adds frozen";
   else if(InpUseNewsFilter && gNewsLock) values[2]="NEWS until "+TimeToString(gNewsLockUntil,TIME_MINUTES);
   if(ActiveCycleRiskLocked() || EntryRiskLocked()) inks[2]=UI_AMBER;
   values[3]=(!InpUseTrend ? "OFF" : (gTrendDir > 0 ? "UP" : (gTrendDir < 0 ? "DOWN" : "NEUTRAL")));
   if(UseDepthDoubling() && gDblArmed) values[3]+=" | double ON";
   if(InpUseCenterReversalMultiplier) values[3]+=" | "+ReversalMultiplierStatus();
   if(InpUseAltExit) values[3]+=" | alternate ON";
   if(InpUseDepthDD && gDDArmed) values[3]+=" | DD "+MoneyStr(gDDMarkNet*InpDDFraction);
   else if(InpUseDepthDD && gDDEligible) values[3]+=" | DD wait center";
   values[4]=(!InpUseBankProfitLock ? "OFF" : (gBankLockArmed ? "Peak "+MoneyStr(gBankLockPeak)+" | floor "+MoneyStr(gBankLockFloor) : "Waiting for "+MoneyStr(target)));
   if(InpUseBankProfitLock && gBankLockArmed) inks[4]=UI_GREEN;
   double limit=EffectiveCycleLossLimit();
   values[5]=(limit > 0.0 ? "NET -"+DoubleToString(limit,2) : "NET OFF");
   if(InpUseFloatingLoss) values[5]+=" | Float -"+DoubleToString(InpFloatingLossLimit,2);
   if((limit > 0.0 && net <= -limit*0.5) || (InpUseFloatingLoss && floating <= -InpFloatingLossLimit*0.5)) inks[5]=UI_RED;
   int labelWidth=(int)MathMin(118,w*0.36);
   int start=(shortPanel ? 30 : 49),step=(int)MathMax(14,MathMin(30,(h-start-14)/5));
   for(int i=0; i<6; i++)
   {
      int row=y+start+i*step;
      if(row+12 > y+h) break;
      DashboardText("status_key"+IntegerToString(i),x+16,row,labelWidth,labels[i],UI_MUTED,(shortPanel ? 8 : 9));
      DashboardText("status_value"+IntegerToString(i),x+20+labelWidth,row,w-labelWidth-36,values[i],inks[i],(shortPanel ? 8 : 9));
      if(i < 5 && step >= 24) DashboardBox("status_rule"+IntegerToString(i),x+16,row+step-7,w-32,1,UI_BORDER,UI_BORDER);
   }
}

void DashboardHistory(int x,int y,int w,int h,bool ready)
{
   DashboardBox("history",x,y,w,h,UI_PANEL,UI_BORDER);
   DashboardText("history_title",x+16,y+12,(int)(w*0.53),"CYCLE EXIT HISTORY",UI_BLUE,11,true);
   DashboardText("history_count",x+(int)(w*0.55),y+14,(int)(w*0.45)-16,
                  (ready ? IntegerToString(gDashboardExited)+" positions with exits" : "History pending"),(ready ? UI_MUTED : UI_AMBER),9,false,true);
   int rows=(int)MathMax(0,(h-94)/28),total=(ready ? ArraySize(gDashboardRows) : 0);
   int pages=(rows > 0 ? (int)MathMax(1,(total+rows-1)/rows) : 1);
   gDashboardPage=(int)MathMax(0,MathMin(gDashboardPage,pages-1));
   bool full=(w >= 740);
   int inner=w-32;
   double weights[]={0.20,0.10,0.12,0.18,0.16,0.24};
   if(!full) { weights[0]=0.30; weights[1]=0.14; weights[2]=0; weights[3]=0; weights[4]=0.22; weights[5]=0.34; }
   string titles[]={"POSITION","SIDE","CLOSED LOTS","AVG EXIT","NET","LAST EXIT"};
   int col[6],widths[6],left=x+16;
   DashboardBox("history_head",x+8,y+38,w-16,26,C'15,36,54',UI_BORDER);
   for(int c=0; c<6; c++)
   {
      col[c]=left; widths[c]=(int)MathFloor(inner*weights[c]); left+=widths[c];
      if(widths[c] > 0) DashboardText("history_col"+IntegerToString(c),col[c]+4,y+44,widths[c]-8,titles[c],UI_MUTED,8,true,c==2 || c==3 || c==4);
   }
   int first=gDashboardPage*rows,shown=(int)MathMin(rows,total-first);
   for(int r=0; r<shown; r++)
   {
      int k=gDashboardRows[first+r],row=y+68+r*28;
      string key="history_row"+IntegerToString(r);
      DashboardBox(key+"_bg",x+8,row-2,w-16,28,(r%2 == 0 ? UI_PANEL : C'12,31,48'),UI_PANEL);
      double volume=(k < ArraySize(gDashboardDetails) ? gDashboardDetails[k].closedVolume : 0.0);
      double price=(volume > 0.0 ? gDashboardDetails[k].priceVolume/volume : 0.0);
      string values[6];
      values[0]=IntegerToString(gDashboardPositions[k].id);
      values[1]=(gDashboardPositions[k].side == 0 ? "BUY" : "SELL");
      values[2]=DashboardLots(volume);
      values[3]=(volume > 0.0 ? DoubleToString(price,_Digits) : "--");
      values[4]=MoneyStr(gDashboardPositions[k].net);
      values[5]=TimeToString((datetime)(gDashboardPositions[k].closeMsc/1000),TIME_DATE|TIME_SECONDS);
      string detail="Position "+values[0]+" | "+values[1]+" | closed "+values[2]+" lots | avg exit "+values[3]+" | NET "+values[4]+" | "+values[5];
      for(int c=0; c<6; c++)
      {
         if(widths[c] <= 0) continue;
         color ink=(c == 1 ? (gDashboardPositions[k].side == 0 ? UI_GREEN : UI_RED) : (c == 4 ? DashboardPnLColor(gDashboardPositions[k].net) : UI_TEXT));
         DashboardText(key+"_"+IntegerToString(c),col[c]+4,row+3,widths[c]-8,values[c],ink,9,c==1 || c==4,c==2 || c==3 || c==4,detail);
      }
   }
   if(shown == 0 && rows > 0)
      DashboardText("history_empty",x+20,y+76,w-40,(ready ? "No exits in this cycle" : "History unavailable - realized bank retained"),UI_MUTED,10);
   string footer=(ready ? "Latest "+IntegerToString(total)+" / "+IntegerToString(gDashboardExited)+" positions with exits" : "History pending");
   DashboardText("history_footer",x+16,y+h-24,w-150,footer,UI_MUTED,8);
   if(pages > 1)
   {
      DashboardButton("prev",x+w-124,y+h-29,26,22,"<","Previous exit-history page");
      DashboardText("page",x+w-92,y+h-25,48,IntegerToString(gDashboardPage+1)+" / "+IntegerToString(pages),UI_TEXT,8,false,true);
      DashboardButton("next",x+w-38,y+h-29,26,22,">","Next exit-history page");
   }
}

void DashboardMetric(string key,int x,int y,int w,int h,string label,string value,string detail,color accent)
{
   DashboardBox(key,x,y,w,h,UI_PANEL,UI_BORDER);
   DashboardBox(key+"_accent",x,y,3,h,accent,accent);
   DashboardText(key+"_label",x+16,y+12,w-32,label,UI_MUTED,9,true);
   int fs=24;
   while(fs > 14 && DashboardTextWidth(value,fs,"Arial Bold") > w-32) fs-=2;
   DashboardText(key+"_value",x+16,y+32,w-32,value,accent,fs,true);
   DashboardText(key+"_detail",x+16,y+h-20,w-32,detail,UI_MUTED,8);
}

bool DashboardHandleClick(string name)
{
   bool handled=true;
   if(name == UIPFX+"M_reset") RequestDashboardCycleReset();
   else if(name == UIPFX+"M_min") gDashboardCollapsed=!gDashboardCollapsed;
   else if(name == UIPFX+"M_prev") gDashboardPage=(int)MathMax(0,gDashboardPage-1);
   else if(name == UIPFX+"M_next") gDashboardPage++;
   else
   {
      handled=false;
      for(int i=0; i<5; i++)
         if(name == UIPFX+"M_tab"+IntegerToString(i)) { gDashboardView=i; handled=true; break; }
   }
   if(handled)
   {
      ObjectSetInteger(0,name,OBJPROP_STATE,false);
      gDashboardPaintPending=true;
      gUIChanged=true;
   }
   return handled;
}

void DrawModernDashboard(double bid,double ask)
{
   if(!InpShowPanel || (gIsTester && !gIsVisualTester)) return;
   // Visual tester mouse events are not delivered like live chart events.
   // Poll only this dashboard's existing buttons; never alter trading state.
   if(gIsTester && gIsVisualTester)
      for(int k=0; k<ArraySize(gUILabelCache); k++)
         if(gUILabelCache[k].created && gUILabelCache[k].kind == OBJ_BUTTON &&
            ObjectGetInteger(0,UIPFX+gUILabelCache[k].key,OBJPROP_STATE))
            DashboardHandleClick(UIPFX+gUILabelCache[k].key);
   // Resize/click events set PaintPending. Skip synchronous chart queries on
   // ordinary ticks that cannot produce a new display frame.
   datetime updated=TimeCurrent();
   if(!gDashboardPaintPending && updated == gDashboardLastDraw &&
      gDashboardLastDrawRevision == gCycleAccountingRevision) return;
   int cw=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS,0);
   int ch=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0);
   if(cw <= 0 || ch <= 0) return;
   gDashboardLastDraw=updated; gDashboardLastDrawRevision=gCycleAccountingRevision;
   gDashboardChartWidth=cw; gDashboardChartHeight=ch; gDashboardPaintPending=false;
   int dpi=(int)TerminalInfoInteger(TERMINAL_SCREEN_DPI);
   gDashboardScale=(dpi > 0 ? MathMax(0.75,MathMin(3.0,dpi/96.0)) : 1.0);
   gDashboardQuoteBid=bid; gDashboardQuoteAsk=ask;
   for(int k=0; k<ArraySize(gUILabelCache); k++) gUILabelCache[k].touched=false;
   int chartWidth=(int)MathFloor(cw/gDashboardScale),chartHeight=(int)MathFloor(ch/gDashboardScale);
   int x=(int)MathMax(0,MathMin(InpPanelX,chartWidth-320));
   int y=(int)MathMax(0,MathMin(InpPanelY,chartHeight-180));
   int w=(int)MathMax(0,chartWidth-x-12),available=(int)MathMax(0,chartHeight-y-12);
   if(InpDashboardWidth > 0) w=(int)MathMin(w,MathMax(320,InpDashboardWidth));
   if(w < 180 || available < 60) { DashboardEndFrame(); return; }
   int header=(w >= 900 ? 68 : 84),gap=10,columns=(w >= 900 ? 4 : 2);
   if(available < 260) header=48;
   int metricRows=4/columns,metricHeight=92,bodyHeight=(w >= 1000 ? 238 : 272);
   int required=header+gap+metricRows*(metricHeight+gap)+bodyHeight+gap+122+22;
   bool compact=(available < required);
   int h=(gDashboardCollapsed ? 48 : available);
   int cachedRows=ArraySize(gDashboardRows);
   if(!compact && !gDashboardCollapsed)
      h=(int)MathMin(available,required+(int)MathMax(0,MathMin(InpMaxRows,cachedRows)-1)*28);
   DashboardBox("frame",x,y,w,h,UI_BG,UI_BORDER);
   DashboardBox("top_accent",x,y,w,2,UI_BLUE,UI_BLUE);
   string currency=AccountInfoString(ACCOUNT_CURRENCY);
   int titleWidth=(int)(w >= 900 ? w*0.40 : w-188);
   DashboardText("title",x+16,y+12,titleWidth,(w >= 900 ? "STRADDLE NET-BANK (" : "STRADDLE (")+currency+")",UI_TEXT,14,true);
   string state="WAITING"; color stateColor=UI_AMBER;
   if(gRecoveryBlocked) { state="RECOVERY BLOCK"; stateColor=UI_RED; }
   else if(gDashboardResetPending) state="RESETTING";
   else if(gAwaitFlat) state=(gFlatSettling ? "SETTLING" : "CLOSING");
   else if(!gIsTester && (!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))) state="AUTO OFF";
   else if(gHaltedToday || gHaltedMonth) state=(gCycleOpen ? "FINISH CYCLE" : "HALTED");
   else if(gCycleOpen) { state=(gIsTester ? "TEST RUNNING" : "EA RUNNING"); stateColor=UI_GREEN; }
   else if(IsFridayCutoff()) state="FRIDAY STOP";
   else if(IsMondayStartDelay()) state="MONDAY DELAY";
   else if(TimeCurrent() < gCooldownUntil) state="COOLDOWN";
   else if(EntryRiskLocked()) state="ENTRY LOCKED";
   DashboardBox("badge",x+w-166,y+12,116,26,UI_PANEL,stateColor);
   DashboardText("badge_text",x+w-158,y+18,100,state,stateColor,8,true);
   DashboardButton("min",x+w-40,y+12,26,26,(gDashboardCollapsed ? "+" : "-"),(gDashboardCollapsed ? "Expand dashboard" : "Collapse dashboard"));
   if(gDashboardCollapsed) { DashboardEndFrame(); return; }
   string cycle=(gCycleOpen || gAwaitFlat ? TimeToString(gCycleStart,TIME_DATE|TIME_SECONDS) : "Waiting for new cycle");
   if((gCycleOpen || gAwaitFlat) && gCycleStartMsc > 0) cycle+=StringFormat(".%03d",(int)(gCycleStartMsc%1000));
   if(header == 48)
      DashboardText("short_symbol",x+16,y+34,w-32,_Symbol,UI_BLUE,8);
   else if(w >= 900)
   {
      DashboardText("symbol",x+16+(int)(w*0.40),y+12,(int)(w*0.25),_Symbol,UI_BLUE,12,true);
      DashboardText("cycle",x+16,y+44,w-260,"Cycle: "+cycle,UI_MUTED,9);
      DashboardText("clock",x+w-234,y+44,218,TimeToString(updated,TIME_SECONDS)+" server",UI_MUTED,9,false,true);
   }
   else
   {
      DashboardText("symbol",x+16,y+40,w-164,_Symbol,UI_BLUE,12,true);
      DashboardText("clock",x+w-148,y+42,132,TimeToString(updated,TIME_SECONDS),UI_MUTED,9,false,true);
      DashboardText("cycle",x+16,y+64,w-32,"Cycle: "+cycle,UI_MUTED,8);
   }
   bool needsDetails=(gDashboardHistoryDirty || gDashboardRevision != gCycleAccountingRevision || !gDashboardDetailsReady);
   bool historyReady=RefreshDashboardHistory();
   if(historyReady && needsDetails) gDashboardDetailsReady=DashboardLoadDetails();
   historyReady=(historyReady && gDashboardDetailsReady);
   if(gDashboardPageRevision != gCycleAccountingRevision) { gDashboardPage=0; gDashboardPageRevision=gCycleAccountingRevision; }
   RefreshPositionSnapshot();
   double floating=gPositionSnapshotBuy+gPositionSnapshotSell,bank=CycleRealized(),net=bank+floating;
   double target=CurrentTarget((bid+ask)/2.0);
   if(InpUseBankProfitLock && !gBankLockArmed) target=MathMax(target,MathMax(InpBankLockArmProfit,InpBankLockMinProfit));
   string metricLabels[]={"ACTIVE TARGET","CYCLE NET","REALIZED / BANK","FLOATING / OPEN"};
   string metricValues[4],metricDetails[4]; color accents[4];
   metricValues[0]=DoubleToString(target,2); metricValues[1]=MoneyStr(net);
   metricValues[2]=MoneyStr(bank); metricValues[3]=MoneyStr(floating);
   metricDetails[0]=(InpUseTrailingStop ? "NET / BANK basis" : "FLOATING ONLY basis");
   metricDetails[1]=(InpUseTrailingStop && target > 0.0 ? DoubleToString(100.0*net/target,0)+"% of active target" : "Realized bank + open P/L");
   metricDetails[2]="BUY "+MoneyStr(gDashboardBuy)+" / SELL "+MoneyStr(gDashboardSell);
   metricDetails[3]="BUY "+MoneyStr(gPositionSnapshotBuy)+" / SELL "+MoneyStr(gPositionSnapshotSell);
   accents[0]=UI_BLUE; accents[1]=DashboardPnLColor(net); accents[2]=DashboardPnLColor(bank); accents[3]=DashboardPnLColor(floating);
   int yy=y+header+gap;
   if(compact)
   {
      string views[]={"Summary","Activity","P/L","Status","History"};
      int tabWidth=(w-32)/5;
      for(int i=0; i<5; i++) DashboardButton("tab"+IntegerToString(i),x+16+i*tabWidth,yy,tabWidth-4,26,views[i],views[i],gDashboardView==i);
      yy+=36;
      int contentHeight=y+h-yy-28;
      if(contentHeight >= 112)
      {
         if(gDashboardView == 0)
         {
            if(contentHeight >= 190)
            {
               int mh=(int)MathMin(metricHeight,(contentHeight-gap)/2),mw=(w-gap)/2;
               for(int i=0; i<4; i++) DashboardMetric("metric"+IntegerToString(i),x+(i%2)*(mw+gap),yy+(i/2)*(mh+gap),mw,mh,metricLabels[i],metricValues[i],metricDetails[i],accents[i]);
               int performanceY=yy+2*(mh+gap),remaining=contentHeight-2*(mh+gap);
               if(remaining >= 112) DashboardPerformance(x,performanceY,w,remaining,floating,target);
            }
            else
            {
               int rowHeight=contentHeight/4;
               for(int i=0; i<4; i++)
               {
                  DashboardText("summary_key"+IntegerToString(i),x+16,yy+i*rowHeight+3,(int)(w*0.48)-20,metricLabels[i],UI_MUTED,8,true);
                  DashboardText("summary_value"+IntegerToString(i),x+(int)(w*0.48),yy+i*rowHeight,w-(int)(w*0.48)-16,metricValues[i],accents[i],14,true,true,metricDetails[i]);
               }
            }
         }
         else if(gDashboardView == 1) DashboardActivity(x,yy,w,contentHeight,gPositionSnapshotBuy,gPositionSnapshotSell,historyReady,true);
         else if(gDashboardView == 2) DashboardPerformance(x,yy,w,contentHeight,floating,target);
         else if(gDashboardView == 3) DashboardStatus(x,yy,w,contentHeight,net,floating,target);
         else DashboardHistory(x,yy,w,contentHeight,historyReady);
      }
   }
   else
   {
      int mw=(w-(columns-1)*gap)/columns;
      for(int i=0; i<4; i++) DashboardMetric("metric"+IntegerToString(i),x+(i%columns)*(mw+gap),yy+(i/columns)*(metricHeight+gap),mw,metricHeight,metricLabels[i],metricValues[i],metricDetails[i],accents[i]);
      yy+=metricRows*(metricHeight+gap);
      if(w >= 1000)
      {
         int third=(w-2*gap)/3;
         DashboardActivity(x,yy,third,bodyHeight,gPositionSnapshotBuy,gPositionSnapshotSell,historyReady);
         DashboardPerformance(x+third+gap,yy,third,bodyHeight,floating,target);
         DashboardStatus(x+2*(third+gap),yy,w-2*(third+gap),bodyHeight,net,floating,target);
      }
      else
      {
         string views[]={"Activity","Performance","Status"};
         int tabWidth=(w-32)/3,view=(gDashboardView==2 ? 2 : (gDashboardView==3 ? 3 : 1));
         for(int i=0; i<3; i++) DashboardButton("tab"+IntegerToString(i+1),x+16+i*tabWidth,yy,tabWidth-4,26,views[i],views[i],view==i+1);
         if(view == 1) DashboardActivity(x,yy+34,w,bodyHeight-34,gPositionSnapshotBuy,gPositionSnapshotSell,historyReady);
         else if(view == 2) DashboardPerformance(x,yy+34,w,bodyHeight-34,floating,target);
         else DashboardStatus(x,yy+34,w,bodyHeight-34,net,floating,target);
      }
      yy+=bodyHeight+gap;
      DashboardHistory(x,yy,w,y+h-yy-22,historyReady);
   }
   string footer="Magic "+IntegerToString(InpMagic)+" | "+(InpUseTrailingStop ? "NET profit basis" : "Floating-only profit basis");
   if(gHaltedMonth || gHaltedToday) footer+=" | "+(gCycleOpen ? "Target reached: finish cycle" : "New cycles halted");
   DashboardText("footer",x+16,y+h-18,w-124,footer,UI_MUTED,8);
   DrawCycleResetButton(x+w-100,y+h-23,84,20);
   DashboardEndFrame();
}

void DrawDashboard(double bid,double ask)
{
   if(InpDashboardDesign == DASHBOARD_OLD) DrawLegacyDashboard(bid,ask);
   else DrawModernDashboard(bid,ask);
}

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(!InpShowPanel || (gIsTester && !gIsVisualTester)) return;
   if(InpDashboardDesign == DASHBOARD_OLD && !(id == CHARTEVENT_OBJECT_CLICK && sparam == UIPFX+"M_reset")) return;
   bool repaint=(id == CHARTEVENT_CHART_CHANGE);
   if(id == CHARTEVENT_OBJECT_CLICK) repaint=DashboardHandleClick(sparam);
   if(!repaint) return;
   gDashboardPaintPending=true;
   gDashboardLastDraw=0;
   double bid,ask;
   if(!FreshPrice(bid,ask)) { bid=gDashboardQuoteBid; ask=gDashboardQuoteAsk; }
   if(bid > 0.0 && ask > 0.0) DrawDashboard(bid,ask);
}

//--- Read-only reporting scan: do not reset the EA's day/halts or bank ledger.
bool PushDailyRealized(double &profit)
{
   datetime now = TimeCurrent();
   MqlDateTime parts;
   TimeToStruct(now, parts);
   parts.hour=0; parts.min=0; parts.sec=0;
   datetime start = StructToTime(parts);
   if(!HistorySelect(start, now+1)) return false;

   profit = 0.0;
   int total = HistoryDealsTotal();
   for(int i=0; i<total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) return false;
      if(!IsAccountingDeal(ticket)) continue;
      if(HistoryDealGetInteger(ticket, DEAL_TIME) < start) continue;
      profit += DealNet(ticket);
   }
   return(!gBankScanFailed && MathIsValidNumber(profit));
}

string PushNotificationHeader()
{
   string message = "Straddle v1.60 | "+StringSubstr(_Symbol,0,32)+" | "+
                    StringSubstr(AccountInfoString(ACCOUNT_CURRENCY),0,8);
   message += "\nAccount "+IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))+
              " / Magic "+IntegerToString(InpMagic);
   return message;
}

string BuildPushNotification(double netBank, double realizedBank, double dailyProfit)
{
   if(!InpPushNetBank && !InpPushRealizedBank && !InpPushDailyProfit) return "";
   string message = PushNotificationHeader();
   message += "\nSUMMARY "+TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES)+" server";
   if(InpPushNetBank)      message += "\nNet Bank: "+MoneyStr(netBank);
   if(InpPushRealizedBank) message += "\nRealized Bank: "+MoneyStr(realizedBank);
   if(InpPushDailyProfit)  message += "\nDaily Profit: "+MoneyStr(dailyProfit);
   return message;
}

//--- Preserve the cycle boundary before ResetCycleAccounting clears its bank.
void CapturePushCycleExit()
{
   if(!InpUsePushNotifications || !InpPushCycleExit || gIsTester || !gCycleOpen || gCycleStart <= 0) return;
   gPushExitCycleStart = gCycleStart;
   gPushExitCycleStartMsc = (gCycleStartMsc > 0 ? gCycleStartMsc : (long)gCycleStart*1000);
}

bool PushCompletedCycleProfit(double &profit)
{
   return ReadFlatCycleHistory(gPushExitCycleStart,gPushExitCycleStartMsc,profit,false);
}

bool ReadFlatCycleHistory(datetime start,long startMsc,double &profit,bool verifyUnmanaged)
{
   if(!HistorySelect(start, TimeCurrent()+1)) return false;
   profit = 0.0;
   double entered = 0.0, exited = 0.0;
   int resetCount = ArraySize(gResetPositionIds);
   double resetBalance[];
   bool resetSeen[];
   if(ArrayResize(resetBalance,resetCount) != resetCount || ArrayResize(resetSeen,resetCount) != resetCount) return false;
   ArrayInitialize(resetBalance,0.0);
   ArrayInitialize(resetSeen,false);
   int total = HistoryDealsTotal();
   for(int i=0; i<total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) return false;
      if(!IsAccountingDeal(ticket)) continue;
      long time = HistoryDealGetInteger(ticket,DEAL_TIME_MSC);
      if(time <= 0) time = HistoryDealGetInteger(ticket,DEAL_TIME)*1000;
      if(time < startMsc) continue;
      long id = HistoryDealGetInteger(ticket,DEAL_POSITION_ID);
      long manualCycle=ManualTradeCycle(id);
      if(manualCycle > 0 && manualCycle != startMsc) continue;
      int lo=0, hi=ArraySize(gCycleExcludedPositions);
      while(lo < hi)
      {
         int mid=lo+(hi-lo)/2;
         if(gCycleExcludedPositions[mid] < id) lo=mid+1; else hi=mid;
      }
      if(id > 0 && lo < ArraySize(gCycleExcludedPositions) && gCycleExcludedPositions[lo] == id) continue;
      bool excluded=false;
      for(int j=0; j<ArraySize(gCycleExcludedDeals); j++)
         if(gCycleExcludedDeals[j] == ticket) { excluded=true; break; }
      if(excluded) continue;

      profit += DealNet(ticket);
      if(manualCycle > 0 && !verifyUnmanaged && !(InpIncludeManualTradesInCycle && InpManageManualTrades)) continue;
      long type = HistoryDealGetInteger(ticket,DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
      long entry = HistoryDealGetInteger(ticket,DEAL_ENTRY);
      double volume = HistoryDealGetDouble(ticket,DEAL_VOLUME);
      if(entry == DEAL_ENTRY_INOUT || !MathIsValidNumber(volume) || volume < 0.0) return false;
      double delta=0.0;
      if(entry == DEAL_ENTRY_IN) { entered += volume; delta=volume; }
      else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) { exited += volume; delta=-volume; }
      lo=0; hi=resetCount;
      while(lo < hi)
      {
         int mid=lo+(hi-lo)/2;
         if(gResetPositionIds[mid] < id) lo=mid+1; else hi=mid;
      }
      if(id > 0 && lo < resetCount && gResetPositionIds[lo] == id)
      {
         resetSeen[lo]=true;
         resetBalance[lo] += delta;
      }
   }
   for(int i=0; i<resetCount; i++)
      if(!resetSeen[i] || MathAbs(resetBalance[i]) > 1e-8) return false;
   return(MathIsValidNumber(profit) && MathAbs(entered-exited) <= 1e-8);
}

void QueuePushCycleExit()
{
   if(!InpUsePushNotifications || !InpPushCycleExit || gIsTester || gPushExitCycleStart <= 0) return;
   double profit=0.0;
   bool ready=PushCompletedCycleProfit(profit);
   datetime started=gPushExitCycleStart;
   long cycleId=gPushExitCycleStartMsc;
   gPushExitCycleStart=0;
   gPushExitCycleStartMsc=0;
   if(!ready)
   {
      if(InpEnableJournalLogs) Print("Cycle-exit push skipped: complete cycle deal history could not be confirmed; trading is not delayed.");
      return;
   }
   string message=PushNotificationHeader()+"\nCYCLE CLOSED";
   message += "\nStarted: "+TimeToString(started,TIME_DATE|TIME_SECONDS);
   message += "\nClosed: "+TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)+" server";
   message += "\nCycle NET: "+MoneyStr(MathAbs(profit) < 0.005 ? 0.0 : profit);
   int n=ArraySize(gPushExitMessages);
   if(n >= 64 || StringLen(message) > 255 || ArrayResize(gPushExitMessages,n+1) != n+1)
   {
      if(InpEnableJournalLogs) Print("Cycle-exit push skipped: notification queue is full, unavailable or message is too long.");
      return;
   }
   if(ArrayResize(gPushExitIds,n+1) != n+1)
   { ArrayResize(gPushExitMessages,n); return; }
   gPushExitMessages[n]=message;
   gPushExitIds[n]=cycleId;
}

//--- Version/chart-independent reporting scope; never reuse the trading-state keys.
string PushScopeKey()
{
   string server=AccountInfoString(ACCOUNT_SERVER);
   string identity=IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))+"/"+IntegerToString(InpMagic)+"/"+
                   IntegerToString(StringLen(server))+":"+server+"/"+_Symbol;
   ulong hash=0xCBF29CE484222325;
   for(int i=0; i<StringLen(identity); i++)
   {
      hash ^= (ulong)StringGetCharacter(identity,i);
      hash *= 0x100000001B3;
   }
   return "STPush1."+IntegerToString((long)hash);
}

//--- Atomic, non-blocking claims shared by upgraded EAs in this terminal session.
//--- Return 2 for an already claimed report, 0 to defer, 1 for permission to send.
int ClaimPushNotification(long cycleId, ulong now)
{
   string eventKey=PushScopeKey()+(cycleId > 0 ? ".Cycle" : ".Summary");
   string budgetKey="STPush1.SendAfter";
   double previous=0.0, sendAfter=0.0;
   // Creating an existing temporary variable returns false (4502). Reuse it,
   // including when another chart creates it between the check and creation.
   if((!GlobalVariableCheck(eventKey) && !GlobalVariableTemp(eventKey) && !GlobalVariableCheck(eventKey)) ||
      (!GlobalVariableCheck(budgetKey) && !GlobalVariableTemp(budgetKey) && !GlobalVariableCheck(budgetKey)) ||
      !GlobalVariableGet(eventKey,previous) || !GlobalVariableGet(budgetKey,sendAfter) ||
      !MathIsValidNumber(previous) || !MathIsValidNumber(sendAfter))
   {
      gPushSendAfterMs=now+60000;
      if(InpEnableJournalLogs) Print("Mobile push deferred: terminal-wide duplicate guard is unavailable.");
      return 0;
   }
   if((cycleId > 0 && (double)cycleId <= previous) ||
      (cycleId <= 0 && (double)now < previous))
   {
      if(InpEnableJournalLogs) Print("Mobile push suppressed: this cycle or summary interval was already claimed in this terminal.");
      return 2;
   }
   if((double)now < sendAfter)
   {
      gPushSendAfterMs=(ulong)sendAfter;
      return 0;
   }
   // Claim the terminal transport first, then the event, before touching the network.
   if(!GlobalVariableSetOnCondition(budgetKey,(double)(now+10000),sendAfter)) return 0;
   gPushSendAfterMs=now+10000;
   double next=(cycleId > 0 ? (double)cycleId : (double)(now+(ulong)InpPushIntervalMin*60000));
   if(!GlobalVariableSetOnCondition(eventKey,next,previous)) return 0;
   return 1;
}

//--- One transport budget for both report types; this is not a trade-request limiter.
int SendPushMessage(string message, ulong now, long cycleId=0)
{
   if(now < gPushSendAfterMs) return 0;
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) || !TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED) ||
      !TerminalInfoInteger(TERMINAL_MQID))
   {
      gPushSendAfterMs=now+60000;
      if(InpEnableJournalLogs) Print("Mobile push deferred: check connection, Notifications permission and mobile MetaQuotes ID.");
      return 0;
   }
   if(StringLen(message) == 0 || StringLen(message) > 255)
   {
      if(InpEnableJournalLogs) Print("Mobile push skipped: summary must fit within 255 characters.");
      return -2;
   }
   int claim=ClaimPushNotification(cycleId,now);
   if(claim != 1) return claim;
   ResetLastError();
   if(SendNotification(message)) return 1;
   gPushSendAfterMs=now+60000;
   if(InpEnableJournalLogs) PrintFormat("Mobile push failed (error %d); this report will not be resent to avoid duplicates. Local push transport paused for 60 seconds.",GetLastError());
   return -1;
}

//+------------------------------------------------------------------+
//| HTTP Dashboard Push                                              |
//+------------------------------------------------------------------+
void HttpPushDashboardData()
{
   if(gIsTester || !gInit) return;
   if(StringLen(InpApiUrl) == 0 || StringLen(InpApiKey) == 0) return;

   datetime now = TimeCurrent();
   if(now - gHttpPushLastSend < InpPushSeconds) return;

   gHttpPushLastSend = now;

   // Calculate metrics
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   string server = AccountInfoString(ACCOUNT_SERVER);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   string currency = AccountInfoString(ACCOUNT_CURRENCY);

   // Calculate running PnL (sum of profit + swap for open positions)
   double runningPnl = 0.0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(PositionGetTicket(i) != 0)
      {
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

         // Filter by magic if specified
         if(InpMagicFilter > 0 && PositionGetInteger(POSITION_MAGIC) != InpMagicFilter) continue;

         runningPnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   }

   // Calculate EA-specific metrics
   double cycleRealized = CycleRealized();
   double floatingPnl = FloatingPnL();
   double cycleNet = cycleRealized + floatingPnl;

   // Build JSON payload with EA metrics
   string json = StringFormat(
      "{\"login\":%I64d,\"server\":\"%s\",\"balance\":%.2f,\"equity\":%.2f,\"cycle_net\":%.2f,\"realized_bank\":%.2f,\"floating_pnl\":%.2f,\"currency\":\"%s\",\"ts\":%d}",
      login,
      server,
      balance,
      equity,
      cycleNet,
      cycleRealized,
      floatingPnl,
      currency,
      (int)now
   );

   // Prepare headers
   string headers = "Content-Type: application/json\r\nX-API-Key: " + InpApiKey + "\r\n";

   // Send HTTP request
   char post[];
   char result[];
   string resultHeaders;

   StringToCharArray(json, post, 0, StringLen(json));

   ResetLastError();
   int timeout = 5000; // 5 second timeout
   int res = WebRequest(
      "POST",
      InpApiUrl,
      headers,
      timeout,
      post,
      result,
      resultHeaders
   );

   // Log result
   if(res == -1)
   {
      int error = GetLastError();
      if(InpEnableJournalLogs)
      {
         if(error == 4060)
            Print("HTTP Push Error: URL not allowed. Add ", InpApiUrl, " to WebRequest whitelist in Tools > Options > Expert Advisors");
         else
            PrintFormat("HTTP Push Error: WebRequest failed with error %d", error);
      }
   }
   else if(res != 200 && res != 202)
   {
      if(InpEnableJournalLogs)
         PrintFormat("HTTP Push Warning: Server returned status %d", res);
   }
}

void ManagePushNotifications()
{
   if(!InpUsePushNotifications || gIsTester || !gInit) return;
   bool periodic=(InpPushNetBank || InpPushRealizedBank || InpPushDailyProfit);
   int queued=ArraySize(gPushExitMessages);
   if(!periodic && (!InpPushCycleExit || queued == 0)) return;
   ulong now = GetTickCount64();
   if(InpPushCycleExit && queued > 0)
   {
      int result=SendPushMessage(gPushExitMessages[0],now,gPushExitIds[0]);
      if(result != 0)
      {
         for(int i=1; i<queued; i++)
         { gPushExitMessages[i-1]=gPushExitMessages[i]; gPushExitIds[i-1]=gPushExitIds[i]; }
         ArrayResize(gPushExitMessages,queued-1);
         ArrayResize(gPushExitIds,queued-1);
      }
      return; // Cycle reports have priority; never send two pushes in this callback.
   }
   if(!periodic) return;
   if(InpPushIntervalMin < 1) return;

   ulong interval = (ulong)InpPushIntervalMin*60000;
   if(!gPushScheduleStarted)
   {
      gPushScheduleStarted = true;
      gPushNextAttemptMs = now+interval;
      return;
   }
   if(now < gPushNextAttemptMs) return;
   // A failed/skipped report waits a full interval; never catch up with a burst.
   gPushNextAttemptMs = now+interval;
   if(gRecoveryBlocked || gBankHistoryDirty || gBankScanFailed ||
      !TerminalInfoInteger(TERMINAL_CONNECTED)) return;
   if(now < gPushSendAfterMs) return;

   double realizedBank = 0.0, floating = 0.0, dailyProfit = 0.0;
   if(InpPushNetBank || InpPushRealizedBank) realizedBank = CycleRealized();
   if(InpPushNetBank)
   {
      int positions = 0;
      PositionSummary(floating, positions);
      if(!gPositionSnapshotValid) return;
   }
   if(InpPushDailyProfit && !PushDailyRealized(dailyProfit))
   {
      if(InpEnableJournalLogs) Print("Mobile push skipped: daily deal history is unavailable.");
      return;
   }
   double netBank = realizedBank+floating;
   if(!MathIsValidNumber(realizedBank) || !MathIsValidNumber(netBank) || !MathIsValidNumber(dailyProfit)) return;
   string message = BuildPushNotification(netBank, realizedBank, dailyProfit);
   SendPushMessage(message,now);
}

//+------------------------------------------------------------------+
//| Fast path: virtual trailing on the freshest quote                |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(gIsTester || !gInit) return;
   double bid, ask;
   if(!FreshPrice(bid, ask)) return;
   RefreshManualTradeIntegration();
   RefreshBankAccounting();
   if(gDashboardResetPending)
   {
      ManageDashboardCycleReset(bid,ask);
      if(!gRecoveryBlocked) DrawDashboard(bid,ask);
      ManagePushNotifications();
      HttpPushDashboardData();
      return;
   }
   ManageTrailing(bid, ask);
   if(!gRecoveryBlocked) DrawDashboard(bid, ask);
   ManagePushNotifications();
   HttpPushDashboardData();
}
 
//--- Tester-only idle path. Never skip unresolved cleanup, accounting or a new day.
bool TesterDailyHaltIdle(datetime now, double bid, double ask)
{
   if(!gIsTester || !gInit || !gHaltedToday || gRecoveryBlocked ||
      gCycleOpen || gAwaitFlat || gDashboardResetPending || gFlatSettling || gInitialGridForming ||
      gBankHistoryDirty || gBankScanFailed || gExposureBatchActive ||
      ArraySize(gClosingTk) > 0 || ArraySize(gDelTk) > 0 ||
      gDayStart <= 0 || now < gDayStart || now >= gDayStart+86400 ||
      PositionsTotal() > 0 || OrdersTotal() > 0) return false;
   if(InpUseMonthlyCapitalTarget && !gHaltedMonth && gMonthlyPnL >= MonthlyProfitTarget())
      return false; // Let the existing monthly-target latch run, even while flat.

   // Display only: trade decisions never depend on this refresh interval.
   static datetime lastDraw = 0;
   static ulong lastRevision = 0;
   if(InpShowPanel && gIsVisualTester &&
      (lastDraw == 0 || now < lastDraw || now-lastDraw >= 5 ||
       lastRevision != gCycleAccountingRevision ||
       (InpDashboardDesign == DASHBOARD_NEW && gDashboardPaintPending && now != lastDraw)))
   {
      lastDraw = now;
      lastRevision = gCycleAccountingRevision;
      DrawDashboard(bid, ask);
   }
   return true;
}

//+------------------------------------------------------------------+
void OnTick()
{
   double bid, ask;
   if(!FreshPrice(bid, ask)) return;
   datetime now = TimeCurrent();
   if(gRecoveryBlocked)
   {
      if(!gRecoveryCommentShown)
      {
         Comment("STRADDLE RECOVERY BLOCK\n", gRecoveryMessage,
                 "\nNo orders or positions are being changed.");
         gRecoveryCommentShown = true;
      }
      return;
   }
   if(gRecoveryCommentShown)
   {
      Comment("");
      gRecoveryCommentShown = false;
   }
   gLastMid = (bid + ask) / 2.0;      // keep latest mid for exit-side recording
   if(TesterDailyHaltIdle(now, bid, ask)) return;
 
   if(!gInit)
   {
      gCenter     = NormPrice((bid+ask)/2.0);
      gGridDirty  = true;
      gCycleStart = now;
      ResetCycleAccounting();
      gInit       = true;
      gCycleOpen  = false;          // wait for the session window to start
      SavePersistentState(true);
   }

   // Month boundaries can only change once per minute. Avoid date conversion
   // and persistence checks on every tick in a high-density real-tick test.
   static long lastMonthMinute = -1;
   long currentMinute = (long)now/60;
   if(currentMinute != lastMonthMinute)
   {
      lastMonthMinute = currentMinute;
      datetime activeMonth = CurrentMonthStart();
      if(activeMonth != gMonthStart)
      {
         gMonthlyPnL = MonthlyRealized();
         if(InpEnableJournalLogs) PrintFormat("New server month started at %s: monthly capital halt reset; current month P/L %.2f.",
                     TimeToString(gMonthStart, TIME_DATE), gMonthlyPnL);
         SaveMonthlyHaltState();
         SavePersistentState(true);
      }
   }

   // Refresh the cached news lock before any grid entry path (15 seconds live).
   if(InpUseNewsFilter) UpdateNewsGuard();
   else if(gNewsLock || gNewsLockUntil != 0 || gNewsEventName != "") UpdateNewsGuard();
 
   // 1) trail and collect the per-tick inventory/PnL snapshot in one position
   // scan. This runs even while new entries are halted.
   RefreshManualTradeIntegration();
   if(gDashboardResetPending)
   {
      RefreshBankAccounting();
      ManageDashboardCycleReset(bid,ask);
      DrawDashboard(bid,ask);
      return;
   }
   double floatingTick=0.0;
   int positionsTick=0;
   ManageTrailingAndSnapshot(bid, ask, floatingTick, positionsTick);
   RefreshBankAccounting();
   if(!gPositionSnapshotValid) PositionSummary(floatingTick,positionsTick); // a history retry may just have adopted a manual position

   // A manual full-basket close must complete the old cycle before refilling.
   if(ReconcileExternallyFlatCycle(positionsTick) && !gAwaitFlat)
   {
      DrawDashboard(bid,ask);
      return;
   }

   // A reset or hard risk floor always has priority over adding grid exposure.
   if(gAwaitFlat)
   {
      TryFinalizeReset(bid, ask);
      DrawDashboard(bid, ask);
      if(gAwaitFlat) return;
      if(!FreshPrice(bid, ask)) return;
      now = TimeCurrent();
      gLastMid = (bid+ask)/2.0;
      if(InpUseNewsFilter) UpdateNewsGuard();
      // Cleanup may have closed inventory represented by the pre-reset snapshot.
      floatingTick=0.0; positionsTick=0;
   }
   double tickNet=gCycleRealized;
   bool tickActive=false;
   if(gCycleOpen)
   {
      tickNet = gCycleRealized + floatingTick;
      tickActive = (positionsTick > 0 || MathAbs(gCycleRealized) > 0.0001);
   }

   double monthlyProfitGoal = MonthlyProfitTarget();
   double monthlyNet = gMonthlyPnL + floatingTick;
   if(InpUseMonthlyCapitalTarget && !gHaltedMonth &&
      monthlyNet >= CostAdjustedTarget(monthlyProfitGoal))
   {
      gHaltedMonth = true;
      if(InpEnableJournalLogs) PrintFormat("Monthly capital target reached: base %.2f + month NET %.2f = %.2f; target %.2f (x%.2f). %s",
                  InpMonthlyCapital, monthlyNet, InpMonthlyCapital+monthlyNet,
                  InpMonthlyCapital*InpMonthlyCapitalMultiple, InpMonthlyCapitalMultiple,
                  (gCycleOpen ? "The active cycle will finish normally; no next cycle this month."
                              : "No new cycle will start this month."));
      SaveMonthlyHaltState();
      SavePersistentState(true);
      if(!gCycleOpen) return;
   }

   if(gCycleOpen)
   {
      if(ManageBankProfitLock(tickNet, tickActive, positionsTick, (bid+ask)/2.0)) return;
      if(tickActive && CycleLossHit(tickNet))
      {
         CloseAllAndReset(true);
         return;
      }
      if(positionsTick > 0 && InpUseFloatingLoss && floatingTick <= -InpFloatingLossLimit)
      {
         if(InpEnableJournalLogs) PrintFormat("Floating-loss cutout: open PnL %.2f reached -%.2f; cycle NET %.2f.",
                     floatingTick, InpFloatingLossLimit, tickNet);
         CloseAllAndReset(tickNet < 0.0);
         return;
      }
      double fastDailyLimit = DailyLossLimit();
      if(tickActive && fastDailyLimit > 0.0 && gDailyPnL+floatingTick <= -fastDailyLimit)
      {
         gHaltedToday = true;
         SavePersistentState(true);
         CloseAllAndReset(true);
         return;
      }
   }

   // A lock may close the active cycle or freeze its pending/refill activity.
   // With both news action inputs false, the running cycle continues normally;
   // EntryRiskLocked still prevents a new cycle until the news window ends.
   if(EnforceEntryRiskLock(tickNet, gCycleOpen)) return;

   // 2) grid: refill normally, or enforce a flat-only daily/monthly halt
   if(gHaltedToday || (gHaltedMonth && !gCycleOpen))
   {
      // A monthly target reached during a cycle is only enforced after that
      // cycle settles. This branch also protects restart/inconsistent states.
      // Once flat, checking once per server second avoids wasting tester time.
      static datetime lastHaltSweep = 0;
      datetime haltNow = TimeCurrent();
      if(gCycleOpen || haltNow != lastHaltSweep)
      {
         lastHaltSweep = haltNow;
         double haltedFloating=0.0; int haltedPositions=0;
         PositionSummary(haltedFloating, haltedPositions);
         int haltedPendings = CountMyPendings();
         if(gCycleOpen || haltedPositions > 0 || haltedPendings > 0)
         {
            if(InpEnableJournalLogs) PrintFormat("%s halt flatten: positions=%d pending=%d cycle NET=%.2f",
                        (gHaltedMonth ? "Monthly" : "Daily"), haltedPositions,
                        haltedPendings, gCycleRealized+haltedFloating);
            CloseAllAndReset((gCycleRealized+haltedFloating) < 0.0);
            return;
         }
      }
   }
   else
   {
      bool initialGridSent = false;
      bool allowed = (gCycleOpen && !InpCloseAtCutoff ? true : SessionAllowsNewCycle());
 
      if(!gCycleOpen)
      {
         // Final guard for initial attachment/restart while already above the
         // daily target. During an active cycle this check is never evaluated.
         if(InpUseDailyTarget && gDailyPnL >= InpDailyTarget)
         {
            gHaltedToday = true;
            if(InpEnableJournalLogs) PrintFormat("Daily target already reached: realized %.2f >= %.2f. New cycle blocked.",
                        gDailyPnL, InpDailyTarget);
            SavePersistentState(true);
         }
         double entryDailyLimit = DailyLossLimit();
         if(!gHaltedToday && entryDailyLimit > 0.0 && gDailyPnL <= -entryDailyLimit)
         {
            gHaltedToday = true;
            if(InpEnableJournalLogs) PrintFormat("Completed-cycle daily loss limit reached: realized %.2f <= -%.2f. New cycle blocked.",
                        gDailyPnL, entryDailyLimit);
            SavePersistentState(true);
         }
         // only start inside the session window, once cooldown has elapsed, and
         // NOT after the Friday cutoff; re-center at the moment we actually start
         if(!gHaltedToday && !gHaltedMonth && allowed && TimeCurrent() >= gCooldownUntil &&
            !IsFridayCutoff() && !IsMondayStartDelay() && !EntryRiskLocked() && BeginCycleAccounting())
         {
            gCycleStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
            gCenter     = NormPrice((bid+ask)/2.0);
            gGridDirty  = true;
            gCycleOpen  = true;
            ResetInitialGridFormation();
            gBankLockArmed = false;
            gBankLockPeak = 0.0;
            gBankLockFloor = 0.0;
            gBankLockRetainSide = 0;
            gLossExitPending = false;
            gAltBuyDone      = false;
            gAltSellDone     = false;
            gBuyDepth  = 0;             // new straddle -> depth doubling resets
            gSellDepth = 0;
            gDblArmed  = false;
            ResetCenterReversalMultiplier();
            gDDArmed = false; gDDEligible = false; gDDMarkNet = 0.0;
            SavePersistentState(true); // commit cycle identity before sending any orders
            if(InpInstantGrid)
            {
               FormGridNow();
               initialGridSent = true;
            }
         }
      }
      else if(!allowed && InpCloseAtCutoff)
      {
         CloseAllAndReset((CycleRealized()+FloatingPnL()) < 0.0); // optional cutoff flatten
         return;
      }
 
      // Do not refill in the same callback that dispatched a whole initial grid.
      if(gCycleOpen && InpUseCenterReversalMultiplier && !initialGridSent)
         UpdateCenterReversalMultiplier(bid, ask);
      if(gCycleOpen && !ActiveCycleRiskLocked() && !initialGridSent)
      {
         // Arm before maintenance so pending upgrades and every new refill use
         // the multiplied lot from the first eligible tick.
         UpdateDepthDoubleArming(bid, ask);
         MaintainGrid(bid, ask);
      }
   }

   // 3) heavy work (history scans) throttled to ~once per second
   static datetime lastHeavy = 0;
   if(now != lastHeavy)
   {
      lastHeavy = now;
 
      // Live-only safety reconcile. Tester deal events are deterministic, so a
      // full history scan there is unnecessary and very expensive.
      static datetime lastRecon = 0;
      if(!gIsTester && gCycleOpen && now - lastRecon >= 300)
      {
         lastRecon = now;
         gCycleRealized = CycleRealizedScan();
      }
 
      MqlDateTime dayParts;
      TimeToStruct(now, dayParts);
      dayParts.hour=0; dayParts.min=0; dayParts.sec=0;
      datetime today = StructToTime(dayParts);
      static datetime lastDailyRecon = 0;
      if(today != gDayStart || (!gIsTester && now-lastDailyRecon >= 300))
      {
         gDailyPnL = DailyRealized();          // also clears the halt on a new day
         lastDailyRecon = now;
      }
      static datetime lastMonthlyRecon = 0;
      if(!gIsTester && now-lastMonthlyRecon >= 300)
      {
         gMonthlyPnL = MonthlyRealized();
         lastMonthlyRecon = now;
      }
      double dailyLimit = DailyLossLimit();
      double dailyNet = gDailyPnL + floatingTick;
      if(dailyLimit > 0.0 && dailyNet <= -dailyLimit)
      {
         gHaltedToday = true;
         SavePersistentState(true);
         if(gCycleOpen && (positionsTick > 0 || CountMyPendings() > 0))
         {
            if(InpEnableJournalLogs) PrintFormat("Daily loss guard: NET %.2f reached limit -%.2f", dailyNet, dailyLimit);
            CloseAllAndReset(true);
            return;
         }
      }
 
      // Fill depth is updated per deal. Keep an occasional live reconcile only
      // for the features that consume it; restart recovery also scans once.
      static datetime lastDepthRecon = 0;
      bool needDepth = (UseDepthDoubling() || InpUseAltExit || InpUseDepthDD);
      if(!gIsTester && needDepth && gCycleOpen && !gHaltedToday && now-lastDepthRecon >= 300)
      {
         lastDepthRecon = now;
         UpdateFillDepths();
      }
 
      // re-evaluate the 1-min trend on each new M1 candle (live)
      datetime m1 = iTime(_Symbol, PERIOD_M1, 0);
      if(m1 != gTrendLastBar)
      {
         gTrendLastBar = m1;
         UpdateTrend();
      }
 
      // While price is at center: alternate-close each side ONCE per cycle when
      // its currently-open depth has reached InpAltDepthTrigger (independent per
      // side). Depth doubling is armed before grid maintenance on every tick.
      if(gCycleOpen)
      {
         double mid = (bid + ask) / 2.0;
         bool atCenter = (MathAbs(mid - gCenter) <= MathMin(InpCenterSideGap, InpGridGap)*0.5);
 
         if(atCenter)
         {
            // (1) alternate-close, one-shot PER SIDE
            if(InpUseAltExit)
            {
               if(!gAltBuyDone  && DeepestOpenLevel(true)  >= InpAltDepthTrigger){ AltExitSide(true);  gAltBuyDone  = true; }
               if(!gAltSellDone && DeepestOpenLevel(false) >= InpAltDepthTrigger){ AltExitSide(false); gAltSellDone = true; }
            }
         }
      }
 
      // --- cycle exit ---
      // WIN : fixed/trend profit target and lock use NET when trailing is on,
      //       floating-only when off. Risk/recovery rules always retain actual NET.
      // LOSS: BOTH cutouts trigger on NET (realized + floating) so they catch
      //       open floating drawdown - the thing that actually wipes the account.
      double finalFloating=0.0; int finalPositions=0;
      PositionSummary(finalFloating, finalPositions);
      double total    = CycleRealized() + finalFloating;        // realized + floating (NET)
      double mid    = (bid + ask) / 2.0;
      bool   active = (finalPositions > 0 || MathAbs(CycleRealized()) > 0.0001);
 
      // --- OPTIONAL FRIDAY LOSS WIND-DOWN (after cutoff, running cycle only) ---
      // Zero disables each loss rule. With both values at zero the active
      // cycle follows its normal exit, while IsFridayCutoff blocks its successor.
      if(active && gCycleOpen && IsFridayCutoff())
      {
         double weekly = CachedWeeklyRealized();
         bool cutWeekly = (InpFridayWeeklyFrac > 0.0 && weekly > 0.0 &&
                           total <= -InpFridayWeeklyFrac*weekly);
         bool cutSmall  = (InpFridayMinLoss > 0.0 && total < 0.0 &&
                           total > -InpFridayMinLoss);
         if(cutWeekly || cutSmall)
         {
            if(InpEnableJournalLogs) PrintFormat("Friday loss wind-down: cycle NET %.2f, weekly realized %.2f (%s).",
                        total, weekly, (cutWeekly ? "weekly-fraction rule" : "small-loss rule"));
            CloseAllAndReset(true);
            return;
         }
      }
 
      // two-stage depth-drawdown exit: one side reached Trig1 AND the opposite
      // side reached Trig2. Once both met, snapshot the cycle NET the first time
      // price returns to CENTER (only if it's a loss). Then exit ONLY when that
      // loss has reduced to InpDDFraction of the marked loss (e.g. -100 -> -50).
      // If the loss instead deepens, do nothing (no exit).
      if(InpUseDepthDD && active)
      {
         if(!gDDEligible)
         {
            bool a = (gBuyDepth  >= InpDDTrig1 && gSellDepth >= InpDDTrig2);
            bool b = (gSellDepth >= InpDDTrig1 && gBuyDepth  >= InpDDTrig2);
            if(a || b) gDDEligible = true;
         }
         else if(!gDDArmed)
         {
            bool atCenter = (MathAbs(mid - gCenter) <= MathMin(InpCenterSideGap, InpGridGap)*0.5);
            if(atCenter && total <= -InpDDMinLoss)      // only a meaningful loss arms it
            {
               gDDArmed   = true;
               gDDMarkNet = total;                 // marked loss at center (negative)
               if(InpEnableJournalLogs) PrintFormat("DD armed at center: marked NET=%.2f, exit level=%.2f", gDDMarkNet, gDDMarkNet*InpDDFraction);
            }
         }
         else
         {
            // exit level = half the marked loss (less negative). Fire only when
            // NET has climbed to/above it AND is still a loss (so we exit on a
            // genuine recovery of the marked loss, not on the mark tick).
            double exitLevel = gDDMarkNet * InpDDFraction;   // e.g. -100 * 0.5 = -50
            if(total >= exitLevel && total < 0.0)
            {
               if(InpEnableJournalLogs) PrintFormat("DD exit: marked=%.2f, exitLevel=%.2f, NET now=%.2f", gDDMarkNet, exitLevel, total);
               CloseAllAndReset(true);             // marked loss halved -> exit
               return;
            }
         }
      }
 
      if(CycleLossHit(total))
      {
         CloseAllAndReset(true);                                 // hard loss cutout (NET) -> restart
         return;
      }

      SavePersistentState(false);
      DrawDashboard(bid, ask);
   }
   DrawDashboard(bid, ask); // revision changes redraw even if another cycle ended this server second
}
//+------------------------------------------------------------------+
