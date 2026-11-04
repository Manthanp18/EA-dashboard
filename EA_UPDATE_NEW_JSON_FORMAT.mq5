//+------------------------------------------------------------------+
//| Updated HttpPushAccountState Function for New JSON Format       |
//| Replace the existing function with this updated version          |
//+------------------------------------------------------------------+

// INPUT PARAMETERS (Update these in your EA inputs)
input string   InpApiUrl = "https://ea-dashboard-52xx.onrender.com/api/push";  // Dashboard URL (NO API KEY NEEDED!)
input int      InpPushSeconds = 5;                  // Push interval (seconds)
input bool     InpEnableJournalLogs = true;         // Enable journal logs
input long     InpMagicFilter = 0;                  // Magic number filter (0 = all)
input string   InpEAVersion = "1.60";               // EA Version
input string   InpEAInstanceID = "straddle-main";   // EA Instance ID (unique identifier)

// GLOBAL VARIABLE (Add this to your EA)
datetime gHttpPushLastSend = 0;


//+------------------------------------------------------------------+
//| Updated Push Function - Sends New JSON Format                    |
//+------------------------------------------------------------------+
void HttpPushAccountState()
{
   // Skip if URL not configured
   if(StringLen(InpApiUrl) == 0) return;

   // Rate limiting
   datetime now = TimeCurrent();
   if(now - gHttpPushLastSend < InpPushSeconds) return;
   gHttpPushLastSend = now;

   //--- ACCOUNT DATA ---
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   string accountName = AccountInfoString(ACCOUNT_NAME);
   string server = AccountInfoString(ACCOUNT_SERVER);
   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   //--- EA DATA ---
   string eaName = "Straddle";  // Your EA name
   string eaVersion = InpEAVersion;
   string eaInstanceID = InpEAInstanceID;
   string eaSymbol = _Symbol;
   string eaMagic = IntegerToString(InpMagicFilter > 0 ? InpMagicFilter : 990011);
   string eaStatus = MQLInfoInteger(MQL_TESTER) ? "TESTING" : (MQLInfoInteger(MQL_OPTIMIZATION) ? "OPTIMIZING" : "RUNNING");

   //--- SOURCE MODE ---
   string sourceMode = AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? "demo" : "live";

   //--- CYCLE DATA (Use your existing EA functions) ---
   double cycleRealized = CycleRealized();  // Your function
   double floatingPnl = FloatingPnL();      // Your function
   double cycleNet = cycleRealized + floatingPnl;

   // Count positions and pending orders
   int openPositions = 0;
   int pendingOrders = 0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(PositionGetTicket(i) != 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            if(InpMagicFilter == 0 || PositionGetInteger(POSITION_MAGIC) == InpMagicFilter)
               openPositions++;
         }
      }
   }

   total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      if(OrderGetTicket(i) != 0)
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol)
         {
            if(InpMagicFilter == 0 || OrderGetInteger(ORDER_MAGIC) == InpMagicFilter)
               pendingOrders++;
         }
      }
   }

   // Generate unique snapshot ID
   string snapshotID = GenerateUUID();

   // Format timestamp in UTC ISO 8601 format
   MqlDateTime dt;
   TimeToStruct(now, dt);
   string sampledAtUTC = StringFormat(
      "%04d-%02d-%02dT%02d:%02d:%02dZ",
      dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec
   );

   //--- BUILD NEW JSON FORMAT ---
   string json = StringFormat(
      "{"
      "\"schema_version\":1,"
      "\"snapshot_id\":\"%s\","
      "\"sampled_at_utc\":\"%s\","
      "\"source_mode\":\"%s\","
      "\"account\":{"
         "\"login\":\"%I64d\","
         "\"name\":\"%s\","
         "\"server\":\"%s\","
         "\"currency\":\"%s\","
         "\"balance\":%.2f,"
         "\"equity\":%.2f"
      "},"
      "\"ea\":{"
         "\"name\":\"%s\","
         "\"version\":\"%s\","
         "\"instance_id\":\"%s\","
         "\"symbol\":\"%s\","
         "\"magic\":\"%s\","
         "\"status\":\"%s\""
      "},"
      "\"cycle\":{"
         "\"id\":\"%s\","
         "\"active\":%s,"
         "\"net\":%.2f,"
         "\"realized_bank\":%.2f,"
         "\"floating\":%.2f,"
         "\"active_target\":%.2f,"
         "\"profit_basis\":\"NET\","
         "\"open_positions\":%d,"
         "\"pending_orders\":%d,"
         "\"accounting_confirmed\":true"
      "}"
      "}",
      // Snapshot metadata
      snapshotID,
      sampledAtUTC,
      sourceMode,
      // Account data
      login,
      accountName,
      server,
      currency,
      balance,
      equity,
      // EA data
      eaName,
      eaVersion,
      eaInstanceID,
      eaSymbol,
      eaMagic,
      eaStatus,
      // Cycle data
      "cycle-" + IntegerToString(login) + "-" + TimeToString(now, TIME_DATE|TIME_SECONDS),
      openPositions > 0 ? "true" : "false",
      cycleNet,
      cycleRealized,
      floatingPnl,
      5.0,  // active_target - replace with your target value
      openPositions,
      pendingOrders
   );

   //--- SEND HTTP REQUEST (NO API KEY HEADER!) ---
   string headers = "Content-Type: application/json\r\n";  // NO X-API-Key header!

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

   //--- LOG RESULT ---
   if(res == -1)
   {
      int error = GetLastError();
      if(InpEnableJournalLogs)
      {
         if(error == 4060)
            Print("❌ Dashboard push ERROR: WebRequest not allowed. Add URL to Tools > Options > Expert Advisors > Allow WebRequest for: " + InpApiUrl);
         else
            Print("❌ Dashboard push ERROR: ", error, " - ", ErrorDescription(error));
      }
   }
   else if(res >= 200 && res < 300)
   {
      if(InpEnableJournalLogs)
      {
         string response = CharArrayToString(result);
         Print("✅ Dashboard push OK (", res, "): ", response);
      }
   }
   else
   {
      if(InpEnableJournalLogs)
      {
         string response = CharArrayToString(result);
         Print("⚠️ Dashboard push WARN (", res, "): ", response);
      }
   }
}


//+------------------------------------------------------------------+
//| Helper: Generate UUID-like snapshot ID                           |
//+------------------------------------------------------------------+
string GenerateUUID()
{
   string uuid = "";
   long time_part = (long)TimeCurrent();
   long random_part = (long)MathRand() * (long)MathRand();

   uuid = StringFormat(
      "%08x-%04x-%04x-%04x-%012x",
      (int)(time_part & 0xFFFFFFFF),
      (int)((time_part >> 32) & 0xFFFF),
      4000 + (int)(MathRand() % 0x1000),
      8000 + (int)(MathRand() % 0x4000),
      random_part
   );

   return uuid;
}


//+------------------------------------------------------------------+
//| Helper: Get error description                                    |
//+------------------------------------------------------------------+
string ErrorDescription(int error_code)
{
   switch(error_code)
   {
      case 4060: return "WebRequest not allowed for URL";
      case 4014: return "HTTP request failed";
      case 5203: return "Cannot open URL";
      default:   return "Error " + IntegerToString(error_code);
   }
}


//+------------------------------------------------------------------+
//| INSTRUCTIONS:                                                     |
//|                                                                   |
//| 1. Copy the HttpPushAccountState() function above                |
//| 2. Replace your existing HttpPushAccountState() in your EA       |
//| 3. Add the input parameters at the top of your EA                |
//| 4. Add the gHttpPushLastSend global variable                     |
//| 5. Make sure CycleRealized() and FloatingPnL() functions exist   |
//| 6. Add GenerateUUID() and ErrorDescription() helper functions    |
//| 7. In MT5: Tools > Options > Expert Advisors > Allow WebRequest  |
//|    Add: https://ea-dashboard-52xx.onrender.com                   |
//| 8. NO API KEY NEEDED! Just set the URL and run!                  |
//+------------------------------------------------------------------+
