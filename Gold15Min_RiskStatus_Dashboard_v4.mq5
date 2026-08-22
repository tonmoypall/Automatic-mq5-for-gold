//+------------------------------------------------------------------+
//|                                     OrderBlock_Visual_Algo.mq5   |
//|                                  Copyright 2026, Trading AI User |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "1.02"
#property strict

#include <Trade\Trade.mqh>

//--- Inputs
input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_CURRENT; // ট্রেড করার টাইমফ্রেম
input int             InpSwingLookback  = 50;             // সুইং লুকব্যাক (১০)
input double          InpRiskAmount     = 10.0;          // কত ডলার রিস্ক নিবেন (USD)
input double          InpRRRatio        = 2.0;
input double          InpBreakEvenUSD   = 0.0;            // রিওয়ার্ড রেশিও (১:২)
input color           InpBullColor      = clrDodgerBlue;  // বুলিশ জোনের রঙ
input color           InpBearColor      = clrTomato;      // বিয়ারিশ জোনের রঙ

//--- Global Variables
CTrade         m_trade;
double         bullOB_High, bullOB_Low;
double         bearOB_High, bearOB_Low;
datetime       lastBarTime;

//+------------------------------------------------------------------+
//| NEW FUNCTION : SAME PAIR CHECK                                   |
//+------------------------------------------------------------------+
bool HasOpenPosition(string symbol)
{
    for(int i = PositionsTotal()-1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);

        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == symbol)
            {
                return true;
            }
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    m_trade.SetExpertMagicNumber(78692);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    ObjectsDeleteAll(0, "OB_"); // চার্ট থেকে জোনগুলো মুছে ফেলবে
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // ১. জোন ক্যালকুলেশন এবং চার্টে ড্রয়িং
    UpdateAndDrawZones();

    // ২. নতুন ক্যান্ডেল ক্লোজ হলে এন্ট্রি চেক
    datetime currentTime = iTime(_Symbol, InpTimeframe, 0);
    if(lastBarTime != currentTime)
    {
        CheckForEntries();
        lastBarTime = currentTime;
    }
    
    // ৩. ১:১ এ স্টপ লস ব্রেক-ইভেনে নেওয়া
    ManageBreakeven();
}

//+------------------------------------------------------------------+
//| জোন ড্রয়িং এবং আপডেট লজিক                                          |
//+------------------------------------------------------------------+
void UpdateAndDrawZones()
{
    int highIdx = iHighest(_Symbol, InpTimeframe, MODE_HIGH, InpSwingLookback, 1);
    int lowIdx  = iLowest(_Symbol, InpTimeframe, MODE_LOW, InpSwingLookback, 1);

    // বুলিশ জোন (সুইং লো এর আগের ক্যান্ডেল)
    bullOB_High = iHigh(_Symbol, InpTimeframe, lowIdx + 1);
    bullOB_Low  = iLow(_Symbol, InpTimeframe, lowIdx);

    // বিয়ারিশ জোন (সুইং হাই এর আগের ক্যান্ডেল)
    bearOB_High = iHigh(_Symbol, InpTimeframe, highIdx);
    bearOB_Low  = iLow(_Symbol, InpTimeframe, highIdx + 1);

    // চার্টে জোন আঁকা (Visual Representation)
    DrawRectangle("OB_Bull", bullOB_High, bullOB_Low, InpBullColor);
    DrawRectangle("OB_Bear", bearOB_High, bearOB_Low, InpBearColor);
}

//+------------------------------------------------------------------+
//| এন্ট্রি লজিক (জোন টাচ + কনফার্মেশন)                                 |
//+------------------------------------------------------------------+
void CheckForEntries()
{
    double close1 = iClose(_Symbol, InpTimeframe, 1);
    double open1  = iOpen(_Symbol, InpTimeframe, 1);
    double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // BUY: বুলিশ জোনে গ্রিন ক্যান্ডেল ক্লোজ
    if(close1 > bullOB_Low && close1 < bullOB_High && close1 > open1)
    {
        // CHANGED PART
        if(!HasOpenPosition(_Symbol))
        {
            double sl = bullOB_Low; // সুইং লো এর মাথায় SL
            double risk = currentAsk - sl;

            if(risk > 0)
            {
                double tp = currentAsk + (risk * InpRRRatio);
                double lots = CalculateLots(risk);

                m_trade.Buy(lots, _Symbol, currentAsk, sl, tp, "OB Buy");
            }
        }
    }

    // SELL: বিয়ারিশ জোনে রেড ক্যান্ডেল ক্লোজ
    if(close1 < bearOB_High && close1 > bearOB_Low && close1 < open1)
    {
        // CHANGED PART
        if(!HasOpenPosition(_Symbol))
        {
            double sl = bearOB_High; // সুইং হাই এর মাথায় SL
            double risk = sl - currentBid;

            if(risk > 0)
            {
                double tp = currentBid - (risk * InpRRRatio);
                double lots = CalculateLots(risk);

                m_trade.Sell(lots, _Symbol, currentBid, sl, tp, "OB Sell");
            }
        }
    }
}

//+------------------------------------------------------------------+
//| লট সাইজ ক্যালকুলেশন (ডলার রিস্ক অনুযায়ী)                             |
//+------------------------------------------------------------------+
double CalculateLots(double riskInPrice)
{
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    // লট = রিস্ক অ্যামাউন্ট / (পয়েন্ট রিস্ক * টিক ভ্যালু / টিক সাইজ)
    double lots = InpRiskAmount / (riskInPrice / tickSize * tickValue);
    
    lots = MathFloor(lots / lotStep) * lotStep; // লট স্টেপ অনুযায়ী রাউন্ড করা

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    return (lots < minLot) ? minLot : lots;
}

//+------------------------------------------------------------------+
//| ১:১ প্রফিটে SL ব্রেক-ইভেনে + $ Profit Lock                       |
//+------------------------------------------------------------------+
void ManageBreakeven()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionSelectByTicket(PositionGetTicket(i)))
        {
            double entry   = PositionGetDouble(POSITION_PRICE_OPEN);
            double sl      = PositionGetDouble(POSITION_SL);
            double tp      = PositionGetDouble(POSITION_TP);
            double current = PositionGetDouble(POSITION_PRICE_CURRENT);
            double volume  = PositionGetDouble(POSITION_VOLUME);

            double risk = MathAbs(entry - sl);

            double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
            double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

            // কত price move হলে $1 profit হবে
            double profitPriceMove =
                (InpBreakEvenUSD / (tickValue * volume)) * tickSize;

            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            {
                // 1:1 পৌঁছালে
                if(current >= entry + risk && sl < entry)
                {
                    double newSL = entry + profitPriceMove;

                    m_trade.PositionModify(
                        PositionGetTicket(i),
                        newSL,
                        tp
                    );
                }
            }
            else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
            {
                // 1:1 পৌঁছালে
                if(current <= entry - risk && sl > entry)
                {
                    double newSL = entry - profitPriceMove;

                    m_trade.PositionModify(
                        PositionGetTicket(i),
                        newSL,
                        tp
                    );
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| চার্টে বক্স আঁকার ফাংশন                                             |
//+------------------------------------------------------------------+
void DrawRectangle(string name, double top, double bottom, color clr)
{
    datetime t1 = iTime(_Symbol, InpTimeframe, InpSwingLookback);
    datetime t2 = iTime(_Symbol, InpTimeframe, 0) + PeriodSeconds(InpTimeframe) * 10;

    ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, top, t2, bottom);

    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_FILL, true);
    ObjectSetInteger(0, name, OBJPROP_BACK, true); // ক্যান্ডেলের পেছনে দেখাবে
}