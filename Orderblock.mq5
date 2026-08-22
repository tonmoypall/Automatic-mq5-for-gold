//+------------------------------------------------------------------+
//|                  Swing_OB_FVG_Touch_Confirm.mq5                  |
//|                    Fixed by ChatGPT for copy-paste               |
//+------------------------------------------------------------------+
#property copyright "OpenAI"
#property link      "https://openai.com"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//-------------------------------------------------------------------
// ENUMS
//-------------------------------------------------------------------
enum ENUM_ZONE_TYPE
{
   ZONE_NONE = 0,
   ZONE_OB   = 1,
   ZONE_FVG  = 2
};

enum ENUM_ZONE_DIR
{
   DIR_NONE = 0,
   DIR_BUY  = 1,
   DIR_SELL = 2
};

//-------------------------------------------------------------------
// INPUTS
//-------------------------------------------------------------------
input group "Timeframe Settings"
input ENUM_TIMEFRAMES InpDetectionTF      = PERIOD_M5;   // Swing / Zone Detection TF
input ENUM_TIMEFRAMES InpConfirmTF        = PERIOD_M1;   // Confirmation TF

input group "Swing Settings"
input int      InpSwingLeft               = 2;           // Swing left bars
input int      InpSwingRight              = 2;           // Swing right bars
input int      InpLookback                = 300;         // Search lookback bars
input int      InpZoneSearchDepth         = 25;          // Search depth after swing

input group "Zone Settings"
input double   InpSLBufferPoints          = 100.0;       // SL buffer in points
input int      InpMinZoneSizePoints       = 30;          // Minimum zone size in points
input int      InpZoneExpiryBars          = 80;          // Expire zone after N detection bars
input bool     InpUseOrderBlock           = true;        // Use Order Block
input bool     InpUseFVG                  = true;        // Use Fair Value Gap

input group "Risk Management"
input double   InpRiskAmount              = 100.0;       // Risk per trade (account currency)
input bool     InpUseTP                   = true;        // Use Take Profit
input double   InpRR                      = 2.0;         // Risk:Reward
input double   InpBE_RR                   = 1.0;         // Break-even trigger RR
input int      InpProfitLockPoints        = 50;          // Profit lock points after BE
input bool     InpOneTrade                = true;        // One trade at a time (same symbol + magic)

input group "System"
input long     InpMagic                   = 123456;      // Magic Number
input int      InpMaxSpreadPoints         = 30;          // Max spread in points
input int      InpSlippagePoints          = 10;          // Slippage in points

//-------------------------------------------------------------------
// GLOBALS
//-------------------------------------------------------------------
CTrade      trade;
CSymbolInfo sym;

datetime    lastConfirmBarTime = 0;

//-------------------------------------------------------------------
// ZONE STRUCT
//-------------------------------------------------------------------
struct ST_Zone
{
   ENUM_ZONE_TYPE type;
   ENUM_ZONE_DIR  dir;

   double         high;
   double         low;
   double         slLevel;
   double         swingPrice;

   datetime       formedTime;
   datetime       touchedTime;

   bool           isValid;
   bool           touched;
};

ST_Zone activeZone;

//+------------------------------------------------------------------+
//| Utility                                                          |
//+------------------------------------------------------------------+
void ResetZone()
{
   activeZone.type       = ZONE_NONE;
   activeZone.dir        = DIR_NONE;
   activeZone.high       = 0.0;
   activeZone.low        = 0.0;
   activeZone.slLevel    = 0.0;
   activeZone.swingPrice = 0.0;
   activeZone.formedTime = 0;
   activeZone.touchedTime= 0;
   activeZone.isValid    = false;
   activeZone.touched    = false;
}

//+------------------------------------------------------------------+
//| Count my positions only                                          |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
      {
         count++;
      }
   }

   return count;
}

//+------------------------------------------------------------------+
//| Normalize lot                                                    |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      return minLot;

   lot = MathFloor(lot / step) * step;
   lot = MathMax(minLot, MathMin(maxLot, lot));

   int volDigits = 2;
   if(step == 1.0)        volDigits = 0;
   else if(step == 0.1)   volDigits = 1;
   else if(step == 0.01)  volDigits = 2;
   else if(step == 0.001) volDigits = 3;

   return NormalizeDouble(lot, volDigits);
}

//+------------------------------------------------------------------+
//| Calculate lot by risk                                            |
//+------------------------------------------------------------------+
double CalculateLot(double entryPrice, double stopLossPrice)
{
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0.0 || tickValue <= 0.0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double slDistance = MathAbs(entryPrice - stopLossPrice);
   if(slDistance <= 0.0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lossPerLot = (slDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double rawLot = InpRiskAmount / lossPerLot;
   return NormalizeLot(rawLot);
}

//+------------------------------------------------------------------+
//| Spread check                                                     |
//+------------------------------------------------------------------+
bool IsSpreadOK()
{
   if(!sym.RefreshRates())
      return false;

   return (sym.Spread() <= InpMaxSpreadPoints);
}

//+------------------------------------------------------------------+
//| Is swing high                                                    |
//+------------------------------------------------------------------+
bool IsSwingHigh(MqlRates &rates[], int index, int leftBars, int rightBars)
{
   double h = rates[index].high;

   for(int i = 1; i <= leftBars; i++)
   {
      if(rates[index + i].high >= h)
         return false;
   }

   for(int i = 1; i <= rightBars; i++)
   {
      if(rates[index - i].high > h)
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Is swing low                                                     |
//+------------------------------------------------------------------+
bool IsSwingLow(MqlRates &rates[], int index, int leftBars, int rightBars)
{
   double l = rates[index].low;

   for(int i = 1; i <= leftBars; i++)
   {
      if(rates[index + i].low <= l)
         return false;
   }

   for(int i = 1; i <= rightBars; i++)
   {
      if(rates[index - i].low < l)
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Build sell OB above swing                                        |
//+------------------------------------------------------------------+
bool FindSellOBAboveSwing(MqlRates &rates[], int swingIndex, ST_Zone &zone)
{
   int maxJ = MathMin(swingIndex + InpZoneSearchDepth, ArraySize(rates) - 4);

   for(int j = swingIndex + 1; j <= maxJ; j++)
   {
      bool bullishOB = (rates[j].close > rates[j].open);
      bool bearishMove =
         (rates[j-1].close < rates[j-1].open) &&
         (rates[j-2].close < rates[j-2].open);

      if(!bullishOB || !bearishMove)
         continue;

      double zHigh = rates[j].high;
      double zLow  = rates[j].low;

      if(zHigh <= rates[swingIndex].high)
         continue;

      if((zHigh - zLow) < (InpMinZoneSizePoints * _Point))
         continue;

      zone.type       = ZONE_OB;
      zone.dir        = DIR_SELL;
      zone.high       = zHigh;
      zone.low        = zLow;
      zone.slLevel    = zHigh + (InpSLBufferPoints * _Point);
      zone.swingPrice = rates[swingIndex].high;
      zone.formedTime = rates[j].time;
      zone.touchedTime= 0;
      zone.isValid    = true;
      zone.touched    = false;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Build buy OB below swing                                         |
//+------------------------------------------------------------------+
bool FindBuyOBBelowSwing(MqlRates &rates[], int swingIndex, ST_Zone &zone)
{
   int maxJ = MathMin(swingIndex + InpZoneSearchDepth, ArraySize(rates) - 4);

   for(int j = swingIndex + 1; j <= maxJ; j++)
   {
      bool bearishOB = (rates[j].close < rates[j].open);
      bool bullishMove =
         (rates[j-1].close > rates[j-1].open) &&
         (rates[j-2].close > rates[j-2].open);

      if(!bearishOB || !bullishMove)
         continue;

      double zHigh = rates[j].high;
      double zLow  = rates[j].low;

      if(zLow >= rates[swingIndex].low)
         continue;

      if((zHigh - zLow) < (InpMinZoneSizePoints * _Point))
         continue;

      zone.type       = ZONE_OB;
      zone.dir        = DIR_BUY;
      zone.high       = zHigh;
      zone.low        = zLow;
      zone.slLevel    = zLow - (InpSLBufferPoints * _Point);
      zone.swingPrice = rates[swingIndex].low;
      zone.formedTime = rates[j].time;
      zone.touchedTime= 0;
      zone.isValid    = true;
      zone.touched    = false;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Build sell FVG above swing                                       |
//+------------------------------------------------------------------+
bool FindSellFVGAboveSwing(MqlRates &rates[], int swingIndex, ST_Zone &zone)
{
   int maxJ = MathMin(swingIndex + InpZoneSearchDepth, ArraySize(rates) - 3);

   for(int j = swingIndex + 1; j <= maxJ; j++)
   {
      // Bearish FVG idea:
      // older candle low > newer candle high
      double zHigh = rates[j].low;
      double zLow  = rates[j-2].high;

      if(zHigh <= zLow)
         continue;

      if(rates[j].low <= rates[j-2].high)
         continue;

      if(zHigh <= rates[swingIndex].high)
         continue;

      if((zHigh - zLow) < (InpMinZoneSizePoints * _Point))
         continue;

      zone.type       = ZONE_FVG;
      zone.dir        = DIR_SELL;
      zone.high       = zHigh;
      zone.low        = zLow;
      zone.slLevel    = zHigh + (InpSLBufferPoints * _Point);
      zone.swingPrice = rates[swingIndex].high;
      zone.formedTime = rates[j].time;
      zone.touchedTime= 0;
      zone.isValid    = true;
      zone.touched    = false;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Build buy FVG below swing                                        |
//+------------------------------------------------------------------+
bool FindBuyFVGBelowSwing(MqlRates &rates[], int swingIndex, ST_Zone &zone)
{
   int maxJ = MathMin(swingIndex + InpZoneSearchDepth, ArraySize(rates) - 3);

   for(int j = swingIndex + 1; j <= maxJ; j++)
   {
      // Bullish FVG idea:
      // older candle high < newer candle low
      double zHigh = rates[j-2].low;
      double zLow  = rates[j].high;

      if(zHigh <= zLow)
         continue;

      if(rates[j].high >= rates[j-2].low)
         continue;

      if(zLow >= rates[swingIndex].low)
         continue;

      if((zHigh - zLow) < (InpMinZoneSizePoints * _Point))
         continue;

      zone.type       = ZONE_FVG;
      zone.dir        = DIR_BUY;
      zone.high       = zHigh;
      zone.low        = zLow;
      zone.slLevel    = zLow - (InpSLBufferPoints * _Point);
      zone.swingPrice = rates[swingIndex].low;
      zone.formedTime = rates[j].time;
      zone.touchedTime= 0;
      zone.isValid    = true;
      zone.touched    = false;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Find latest valid zone                                           |
//+------------------------------------------------------------------+
bool FindZone()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int copied = CopyRates(_Symbol, InpDetectionTF, 0, InpLookback, rates);
   if(copied < 50)
      return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   ST_Zone candidate;
   ResetZone();

   // Search recent swings first
   for(int i = InpSwingRight + 5; i < copied - InpSwingLeft - 5; i++)
   {
      // SELL setup: swing high with zone above
      if(IsSwingHigh(rates, i, InpSwingLeft, InpSwingRight))
      {
         if(InpUseOrderBlock)
         {
            if(FindSellOBAboveSwing(rates, i, candidate))
            {
               // Zone should still be above current price or near current price
               if(candidate.low >= bid || (bid >= candidate.low && bid <= candidate.high))
               {
                  activeZone = candidate;
                  Print("SELL OB zone found. High=", activeZone.high, " Low=", activeZone.low);
                  return true;
               }
            }
         }

         if(InpUseFVG)
         {
            if(FindSellFVGAboveSwing(rates, i, candidate))
            {
               if(candidate.low >= bid || (bid >= candidate.low && bid <= candidate.high))
               {
                  activeZone = candidate;
                  Print("SELL FVG zone found. High=", activeZone.high, " Low=", activeZone.low);
                  return true;
               }
            }
         }
      }

      // BUY setup: swing low with zone below
      if(IsSwingLow(rates, i, InpSwingLeft, InpSwingRight))
      {
         if(InpUseOrderBlock)
         {
            if(FindBuyOBBelowSwing(rates, i, candidate))
            {
               if(candidate.high <= ask || (ask >= candidate.low && ask <= candidate.high))
               {
                  activeZone = candidate;
                  Print("BUY OB zone found. High=", activeZone.high, " Low=", activeZone.low);
                  return true;
               }
            }
         }

         if(InpUseFVG)
         {
            if(FindBuyFVGBelowSwing(rates, i, candidate))
            {
               if(candidate.high <= ask || (ask >= candidate.low && ask <= candidate.high))
               {
                  activeZone = candidate;
                  Print("BUY FVG zone found. High=", activeZone.high, " Low=", activeZone.low);
                  return true;
               }
            }
         }
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Check if current price touched zone                              |
//+------------------------------------------------------------------+
void UpdateZoneTouch()
{
   if(!activeZone.isValid)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool touched = false;

   if(activeZone.dir == DIR_SELL)
   {
      // sell zone above price -> ask touch is safer
      touched = (ask >= activeZone.low && ask <= activeZone.high);
   }
   else if(activeZone.dir == DIR_BUY)
   {
      // buy zone below price -> bid touch is safer
      touched = (bid >= activeZone.low && bid <= activeZone.high);
   }

   if(touched && !activeZone.touched)
   {
      activeZone.touched = true;
      activeZone.touchedTime = TimeCurrent();
      Print("Zone touched. Direction=", (activeZone.dir == DIR_SELL ? "SELL" : "BUY"));
   }
}

//+------------------------------------------------------------------+
//| Invalidate old zone                                              |
//+------------------------------------------------------------------+
void ValidateZoneAge()
{
   if(!activeZone.isValid)
      return;

   int detSec = PeriodSeconds(InpDetectionTF);
   if(detSec <= 0)
      detSec = 60;

   if((TimeCurrent() - activeZone.formedTime) > (InpZoneExpiryBars * detSec))
   {
      Print("Zone expired.");
      ResetZone();
      return;
   }

   // touched zone too old -> reset
   int confSec = PeriodSeconds(InpConfirmTF);
   if(confSec <= 0)
      confSec = 60;

   if(activeZone.touched && (TimeCurrent() - activeZone.touchedTime) > (5 * confSec))
   {
      Print("Touched zone expired without confirmation.");
      ResetZone();
      return;
   }
}

//+------------------------------------------------------------------+
//| Open trade                                                       |
//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE orderType)
{
   if(!sym.RefreshRates())
      return false;

   double entry = 0.0;
   double sl    = activeZone.slLevel;
   double tp    = 0.0;

   if(orderType == ORDER_TYPE_BUY)
      entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   else
      entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double lot = CalculateLot(entry, sl);
   if(lot <= 0.0)
   {
      Print("Lot calculation failed.");
      return false;
   }

   double risk = MathAbs(entry - sl);
   if(risk <= 0.0)
   {
      Print("Invalid risk distance.");
      return false;
   }

   if(InpUseTP)
   {
      if(orderType == ORDER_TYPE_BUY)
         tp = entry + (risk * InpRR);
      else
         tp = entry - (risk * InpRR);
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   bool ok = false;

   if(orderType == ORDER_TYPE_BUY)
      ok = trade.Buy(lot, _Symbol, entry, sl, tp, "Swing_OB_FVG_Buy");
   else
      ok = trade.Sell(lot, _Symbol, entry, sl, tp, "Swing_OB_FVG_Sell");

   if(!ok)
   {
      Print("OrderSend failed. Retcode=", trade.ResultRetcode(),
            " Desc=", trade.ResultRetcodeDescription());
      return false;
   }

   Print("Trade opened successfully. Ticket=", trade.ResultOrder(),
         " Type=", (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"),
         " Lot=", lot, " Entry=", entry, " SL=", sl, " TP=", tp);

   ResetZone();
   return true;
}

//+------------------------------------------------------------------+
//| Confirm with last closed candle                                  |
//+------------------------------------------------------------------+
void CheckConfirmationAndEnter()
{
   if(!activeZone.isValid || !activeZone.touched)
      return;

   double o[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);

   if(CopyOpen(_Symbol, InpConfirmTF, 1, 1, o) < 1)
      return;
   if(CopyClose(_Symbol, InpConfirmTF, 1, 1, c) < 1)
      return;

   bool redCandle   = (c[0] < o[0]);
   bool greenCandle = (c[0] > o[0]);

   if(InpOneTrade && CountMyPositions() > 0)
      return;

   if(activeZone.dir == DIR_SELL && redCandle)
   {
      OpenTrade(ORDER_TYPE_SELL);
   }
   else if(activeZone.dir == DIR_BUY && greenCandle)
   {
      OpenTrade(ORDER_TYPE_BUY);
   }
}

//+------------------------------------------------------------------+
//| Manage trailing / break-even                                     |
//+------------------------------------------------------------------+
void ManageTrailing()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagic)
      {
         continue;
      }

      long   posType   = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      double curPrice = (posType == POSITION_TYPE_BUY)
                        ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                        : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double risk = MathAbs(openPrice - currentSL);
      if(risk <= 0.0)
         continue;

      // Break even at RR
      if(posType == POSITION_TYPE_BUY)
      {
         if(curPrice >= openPrice + (risk * InpBE_RR))
         {
            double newSL = openPrice + (InpProfitLockPoints * _Point);
            if(newSL > currentSL)
            {
               if(!trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("BUY modify failed. Retcode=", trade.ResultRetcode(),
                        " Desc=", trade.ResultRetcodeDescription());
               }
            }
         }
      }
      else
      {
         if(curPrice <= openPrice - (risk * InpBE_RR))
         {
            double newSL = openPrice - (InpProfitLockPoints * _Point);
            if(currentSL == 0.0 || newSL < currentSL)
            {
               if(!trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("SELL modify failed. Retcode=", trade.ResultRetcode(),
                        " Desc=", trade.ResultRetcodeDescription());
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   sym.Name(_Symbol);

   ResetZone();

   Print("Swing OB/FVG Touch Confirm EA initialized.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsSpreadOK())
      return;

   ManageTrailing();
   ValidateZoneAge();

   // If no open zone, find one
   if(!activeZone.isValid)
   {
      FindZone();
   }

   // Intrabar touch detection (important fix)
   if(activeZone.isValid)
   {
      UpdateZoneTouch();
   }

   // Confirmation only on new closed bar
   datetime currentConfirmBar = iTime(_Symbol, InpConfirmTF, 0);
   if(currentConfirmBar != lastConfirmBarTime)
   {
      lastConfirmBarTime = currentConfirmBar;
      CheckConfirmationAndEnter();
   }
}