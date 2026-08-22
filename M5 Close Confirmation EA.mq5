//+------------------------------------------------------------------+
//|           H1 Break -> M5 Close Confirmation EA (Filtered)        |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "4.10"
#property strict

#include <Trade\Trade.mqh>

//--- Inputs
input ENUM_TIMEFRAMES BreakTF            = PERIOD_H1;   // Reference timeframe
input ENUM_TIMEFRAMES ConfirmTF          = PERIOD_M5;   // Confirmation timeframe

input double          NormalRiskUSD      = 10.0;        // Normal risk in USD
input double          MaximumRiskUSD     = 15.0;        // Maximum risk in USD
input double          RR_Ratio           = 2.0;         // Risk:Reward

input ulong           MagicNumber        = 20260403;
input bool            UseFixedLots       = false;       // true হলে নিচের lot use করবে
input double          FixedLots          = 0.10;        // fixed lot
input bool            EnableTP           = true;        // TP use করবে কিনা

input int             EntryWindowMinutes = 32;          // নতুন H1 candle start হওয়ার পর কত মিনিট পর্যন্ত entry allow

// বাংলাদেশ session filter
input bool            UseBangladeshSession = true;      // বাংলাদেশ time window use করবে কিনা
input int             SessionStartHourBD   = 13;        // 13 = দুপুর 1টা
input int             SessionEndHourBD     = 22;        // 22 = রাত 10টা

// Break-even
input bool            EnableBreakEven      = true;      // 1:1 হলে SL break-even এ যাবে
input double          BreakEvenOffsetPoints = 0;        // চাইলে BE এর সাথে extra points add করা যাবে

//--- Globals
CTrade   trade;
datetime lastM5BarTime      = 0;
datetime trackedH1OpenTime  = 0;
bool     tradedThisHour     = false;

// breakout levels from previous closed H1 candle
double   prevH1High         = 0.0;
double   prevH1Low          = 0.0;

// direction filter from last closed H1 candle
//  1 = only buy
// -1 = only sell
//  0 = no trade
int      allowedDirection   = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   InitializeHourState();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Initialize current H1 context                                    |
//+------------------------------------------------------------------+
void InitializeHourState()
{
   trackedH1OpenTime = iTime(_Symbol, BreakTF, 0);
   prevH1High        = iHigh(_Symbol, BreakTF, 1);
   prevH1Low         = iLow(_Symbol, BreakTF, 1);

   double lastH1Open  = iOpen(_Symbol, BreakTF, 1);
   double lastH1Close = iClose(_Symbol, BreakTF, 1);

   if(lastH1Close > lastH1Open)
      allowedDirection = 1;   // bullish -> only buy
   else if(lastH1Close < lastH1Open)
      allowedDirection = -1;  // bearish -> only sell
   else
      allowedDirection = 0;   // doji/neutral -> no trade

   tradedThisHour = false;
}

//+------------------------------------------------------------------+
//| Check new bar on confirmation TF                                 |
//+------------------------------------------------------------------+
bool IsNewConfirmBar()
{
   datetime currentBarTime = iTime(_Symbol, ConfirmTF, 0);
   if(currentBarTime != lastM5BarTime)
   {
      lastM5BarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Detect new H1 hour                                               |
//+------------------------------------------------------------------+
bool IsNewH1Hour()
{
   datetime currentH1Open = iTime(_Symbol, BreakTF, 0);
   return (currentH1Open != trackedH1OpenTime);
}

//+------------------------------------------------------------------+
//| Check if entry is still allowed in current H1 window             |
//+------------------------------------------------------------------+
bool IsWithinEntryWindow()
{
   datetime hourStart = iTime(_Symbol, BreakTF, 0);
   if(hourStart <= 0)
      return false;

   int elapsedSeconds = (int)(TimeCurrent() - hourStart);

   if(elapsedSeconds < 0)
      return false;

   return (elapsedSeconds <= EntryWindowMinutes * 60);
}

//+------------------------------------------------------------------+
//| Check if current Bangladesh time is within trading session       |
//| Session: 13:00 to 22:00 BD time                                  |
//+------------------------------------------------------------------+
bool IsWithinBangladeshSession()
{
   if(!UseBangladeshSession)
      return true;

   datetime bdTime = TimeGMT() + (6 * 60 * 60);

   MqlDateTime bdStruct;
   TimeToStruct(bdTime, bdStruct);

   int bdHour = bdStruct.hour;

   // 13:00 <= time < 22:00
   return (bdHour >= SessionStartHourBD && bdHour < SessionEndHourBD);
}

//+------------------------------------------------------------------+
//| Count our open positions                                         |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if((string)PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      count++;
   }

   return count;
}

//+------------------------------------------------------------------+
//| Close all our positions for this symbol                          |
//+------------------------------------------------------------------+
void CloseMyPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if((string)PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(!trade.PositionClose(ticket))
      {
         Print("Position close failed. Ticket=", ticket,
               " Retcode=", trade.ResultRetcode(),
               " Desc=", trade.ResultRetcodeDescription());
      }
      else
      {
         Print("Position closed at hour end. Ticket=", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Move SL to break-even at 1:1                                     |
//+------------------------------------------------------------------+
void ManageBreakEven()
{
   if(!EnableBreakEven)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if((string)PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      long   posType      = PositionGetInteger(POSITION_TYPE);
      double openPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl           = PositionGetDouble(POSITION_SL);
      double tp           = PositionGetDouble(POSITION_TP);
      double bid          = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask          = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double point        = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int    digits       = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

      if(sl <= 0 || point <= 0)
         continue;

      double beOffset = BreakEvenOffsetPoints * point;

      // BUY position
      if(posType == POSITION_TYPE_BUY)
      {
         double riskDistance    = openPrice - sl;
         if(riskDistance <= 0)
            continue;

         double triggerPrice    = openPrice + riskDistance;     // 1:1
         double newSL           = NormalizeDouble(openPrice + beOffset, digits);

         // price 1:1 এ গেলে এবং SL এখনও break-even এ না গেলে
         if(bid >= triggerPrice && sl < newSL)
         {
            if(trade.PositionModify(ticket, newSL, tp))
               Print("BUY Break-even set. Ticket=", ticket, " New SL=", newSL);
            else
               Print("BUY Break-even failed. Ticket=", ticket,
                     " Retcode=", trade.ResultRetcode(),
                     " Desc=", trade.ResultRetcodeDescription());
         }
      }

      // SELL position
      else if(posType == POSITION_TYPE_SELL)
      {
         double riskDistance    = sl - openPrice;
         if(riskDistance <= 0)
            continue;

         double triggerPrice    = openPrice - riskDistance;     // 1:1
         double newSL           = NormalizeDouble(openPrice - beOffset, digits);

         // price 1:1 এ গেলে এবং SL এখনও break-even এ না গেলে
         if(ask <= triggerPrice && (sl > newSL || sl == 0.0))
         {
            if(trade.PositionModify(ticket, newSL, tp))
               Print("SELL Break-even set. Ticket=", ticket, " New SL=", newSL);
            else
               Print("SELL Break-even failed. Ticket=", ticket,
                     " Retcode=", trade.ResultRetcode(),
                     " Desc=", trade.ResultRetcodeDescription());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Main tick                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   // আগে break-even manage করবে
   ManageBreakEven();

   // Hour change হলে পুরনো trade close + নতুন hour reset
   if(IsNewH1Hour())
   {
      CloseMyPositions();
      InitializeHourState();

      Print("New H1 hour started. Prev H1 High=", prevH1High,
            " | Prev H1 Low=", prevH1Low,
            " | AllowedDirection=", allowedDirection);
   }

   // signal শুধু new M5 candle close হওয়ার পরে check করবে
   if(!IsNewConfirmBar())
      return;

   // hour-এ already trade নিলে আর trade না
   if(tradedThisHour)
      return;

   // existing position থাকলে নতুন entry না
   if(CountMyPositions() > 0)
      return;

   // বাংলাদেশ time অনুযায়ী session check
   if(!IsWithinBangladeshSession())
   {
      Print("Entry skipped: outside Bangladesh trading session. Allowed = ",
            SessionStartHourBD, ":00 to ", SessionEndHourBD, ":00 (UTC+6)");
      return;
   }

   // নতুন H1 candle start হওয়ার প্রথম 30 মিনিটের বাইরে হলে entry নেবে না
   if(!IsWithinEntryWindow())
   {
      Print("Entry skipped: no valid breakout within first ",
            EntryWindowMinutes, " minutes of current H1 candle.");
      return;
   }

   CheckForEntry();
}

//+------------------------------------------------------------------+
//| Get running H1 low so far                                        |
//+------------------------------------------------------------------+
double GetRunningH1Low()
{
   datetime hourStart = iTime(_Symbol, BreakTF, 0);
   if(hourStart <= 0)
      return 0.0;

   int bars = Bars(_Symbol, ConfirmTF, hourStart, TimeCurrent());
   if(bars <= 0)
      bars = 1;

   int lowestIdx = iLowest(_Symbol, ConfirmTF, MODE_LOW, bars, 0);
   if(lowestIdx < 0)
      return 0.0;

   return iLow(_Symbol, ConfirmTF, lowestIdx);
}

//+------------------------------------------------------------------+
//| Get running H1 high so far                                       |
//+------------------------------------------------------------------+
double GetRunningH1High()
{
   datetime hourStart = iTime(_Symbol, BreakTF, 0);
   if(hourStart <= 0)
      return 0.0;

   int bars = Bars(_Symbol, ConfirmTF, hourStart, TimeCurrent());
   if(bars <= 0)
      bars = 1;

   int highestIdx = iHighest(_Symbol, ConfirmTF, MODE_HIGH, bars, 0);
   if(highestIdx < 0)
      return 0.0;

   return iHigh(_Symbol, ConfirmTF, highestIdx);
}

//+------------------------------------------------------------------+
//| Risk-based lot selection                                         |
//+------------------------------------------------------------------+
double GetTradeLots(double riskInPrice)
{
   if(UseFixedLots)
      return NormalizeVolume(FixedLots);

   double lotsNormal = CalculateLots(NormalRiskUSD, riskInPrice);

   // যদি normal risk এ lot 0.01 এর কম হয়,
   // তখন maximum risk দিয়ে আরেকবার calculate করবে
   if(lotsNormal < 0.01)
   {
      double lotsMax = CalculateLots(MaximumRiskUSD, riskInPrice);

      Print("Normal risk lot < 0.01. Switching to MaximumRiskUSD. ",
            "NormalLots=", lotsNormal, " | MaxLots=", lotsMax);

      return NormalizeVolume(lotsMax);
   }

   return NormalizeVolume(lotsNormal);
}

//+------------------------------------------------------------------+
//| Normalize volume according to symbol settings                    |
//+------------------------------------------------------------------+
double NormalizeVolume(double lots)
{
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(lotStep <= 0)
      return 0.0;

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   int digits = 2;
   if(lotStep == 1.0)    digits = 0;
   if(lotStep == 0.1)    digits = 1;
   if(lotStep == 0.01)   digits = 2;
   if(lotStep == 0.001)  digits = 3;

   return NormalizeDouble(lots, digits);
}

//+------------------------------------------------------------------+
//| Entry logic                                                      |
//+------------------------------------------------------------------+
void CheckForEntry()
{
   // last closed M5 candle
   double m5Close = iClose(_Symbol, ConfirmTF, 1);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // BUY condition:
   // 1) last H1 candle must be bullish
   // 2) M5 candle closes above previous H1 high
   if(allowedDirection == 1 && m5Close > prevH1High)
   {
      double sl = GetRunningH1Low();
      double riskInPrice = ask - sl;

      if(sl > 0 && riskInPrice > 0)
      {
         double lots = GetTradeLots(riskInPrice);
         double tp   = 0.0;

         if(EnableTP)
            tp = ask + (riskInPrice * RR_Ratio);

         if(lots > 0)
         {
            bool ok = trade.Buy(lots, _Symbol, ask, sl, tp, "H1 High Break Buy");
            if(ok)
            {
               tradedThisHour = true;
               Print("BUY opened | Entry=", ask,
                     " SL=", sl,
                     " TP=", tp,
                     " Lots=", lots,
                     " AllowedDirection=BUY");
            }
            else
            {
               Print("BUY failed | Retcode=", trade.ResultRetcode(),
                     " Desc=", trade.ResultRetcodeDescription());
            }
         }
      }
      else
      {
         Print("BUY skipped: invalid SL/risk distance.");
      }

      return;
   }

   // SELL condition:
   // 1) last H1 candle must be bearish
   // 2) M5 candle closes below previous H1 low
   if(allowedDirection == -1 && m5Close < prevH1Low)
   {
      double sl = GetRunningH1High();
      double riskInPrice = sl - bid;

      if(sl > 0 && riskInPrice > 0)
      {
         double lots = GetTradeLots(riskInPrice);
         double tp   = 0.0;

         if(EnableTP)
            tp = bid - (riskInPrice * RR_Ratio);

         if(lots > 0)
         {
            bool ok = trade.Sell(lots, _Symbol, bid, sl, tp, "H1 Low Break Sell");
            if(ok)
            {
               tradedThisHour = true;
               Print("SELL opened | Entry=", bid,
                     " SL=", sl,
                     " TP=", tp,
                     " Lots=", lots,
                     " AllowedDirection=SELL");
            }
            else
            {
               Print("SELL failed | Retcode=", trade.ResultRetcode(),
                     " Desc=", trade.ResultRetcodeDescription());
            }
         }
      }
      else
      {
         Print("SELL skipped: invalid SL/risk distance.");
      }

      return;
   }
}

//+------------------------------------------------------------------+
//| Lot calculation                                                  |
//+------------------------------------------------------------------+
double CalculateLots(double riskCash, double riskInPrice)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0 || riskInPrice <= 0)
      return 0.0;

   double lots = riskCash / ((riskInPrice / tickSize) * tickValue);
   return lots;
}