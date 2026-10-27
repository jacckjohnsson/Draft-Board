# Draft Board

A native iPhone stock screener built on a multi-factor model (value, quality, momentum, low volatility, and an optional size tilt). It runs entirely on-device with no backend. Draft Board is the stock-selection companion to [Shock Lab](https://shocklab.streamlit.app/): you decide **what** to invest in here, then export the basket to Shock Lab to stress test it.

> For educational purposes only. This is not investment advice.

## Requirements

- Xcode 16 or later (the project uses folder-synchronized groups)
- iOS 17 or later (iPhone)
- A free [Massive](https://massive.com) API key (prices)
- A free [Financial Modeling Prep](https://site.financialmodelingprep.com) API key (fundamentals)

## Xcode setup

1. Open `App/DraftBoard.xcodeproj`. Xcode resolves the local `FactorKit` package (in the `FactorKit/` folder) automatically.
2. Select the **DraftBoard** target, then **Signing & Capabilities**:
   - Choose your **Team**.
   - Change the **Bundle Identifier** from `com.example.draftboard` to something unique, such as `com.yourname.draftboard`.
   - No extra capabilities are needed. Keychain access for a single app works without the Keychain Sharing capability.
3. Pick an iPhone simulator or your phone and press **Run** (⌘R).
4. On a physical iPhone, the first time:
   - Enable **Developer Mode** (Settings › Privacy & Security › Developer Mode).
   - Trust your developer certificate (Settings › General › VPN & Device Management).
5. In the app, open **Settings**, paste both API keys, and tap **Save keys**. Loading starts immediately.

If the project file ever refuses to open, create a new iOS App project named `DraftBoard` (SwiftUI, SwiftData), delete its template Swift files, drag in the `App/DraftBoard` folder, and add the `FactorKit` folder as a local package (File › Add Package Dependencies › Add Local…), linking `FactorEngine` and `FactorData`.

### Running the tests

The engine and data layers are a Swift package (`FactorKit`) with XCTest suites that run anywhere Swift runs:

- In Xcode, open `FactorKit/Package.swift` and press ⌘U.
- From a terminal: `cd FactorKit && swift test`
- Without a local toolchain: `docker run --rm -v "$PWD/FactorKit":/w -w /w swift:6.1-noble swift test`

GitHub Actions runs the same tests on every push (`.github/workflows/tests.yml`).

## Getting API keys

**Massive (formerly Polygon.io).** Sign up at [massive.com](https://massive.com) and copy your key from the [dashboard](https://massive.com/dashboard/keys). The free Stocks Basic plan includes end-of-day grouped daily bars with 2 years of history, at 5 requests per minute.

**Financial Modeling Prep.** Register at [financialmodelingprep.com](https://site.financialmodelingprep.com/developer/docs) and copy your key from the dashboard. The free plan allows 250 requests per day.

Keys are entered in Settings and stored in the iOS Keychain. They never appear in the source code or in UserDefaults.

## Data sources and their roles

| Source | Used by | What | Refresh |
|---|---|---|---|
| **Massive** `GET /v2/aggs/grouped/locale/us/market/stocks/{date}` | Screener, Stock Detail, Watchlist, Export | Daily closes for all US stocks, one request per trading day | Backfill ~13 months, then 1 call per day |
| **Massive** `GET /stocks/v1/splits` | Same | Split events, applied to the cached closes | Daily |
| **Massive** `GET /v2/aggs/ticker/{t}/range/1/day/{from}/{to}` | First load of small universes, new or custom tickers | ~13 months for one ticker, used when it takes fewer calls than grouped days | Once per ticker |
| **FMP** `/stable/profile`, `/stable/ratios-ttm` | Screener, Detail, filters | Sector, market cap, P/E, P/B, EV/EBITDA, ROE, margins, D/E, dividend yield | Weekly |
| **Yahoo Finance** `v8/finance/chart/{t}?range=10y&interval=1d` | Backtest only | 10 years of adjusted closes | Monthly |

Rules the app enforces:

- **Price sources are never mixed.** The live tabs use only Massive and the backtest uses only Yahoo. Each tab shows a source badge.
- **Split handling.** Grouped bars are stored *unadjusted*, and splits are applied when data is read. A new split never leaves stale prices in the cache, and nothing needs re-downloading.
- **Consistency check.** Settings › Data consistency compares recent Massive closes with Yahoo's split-adjusted closes and flags tickers that differ by more than 1%.
- **Only missing or stale data is fetched.** All downloads are cached in SwiftData. Changing weights, filters, or the watchlist rescores instantly from the cache and never makes a network call.
- **Rate limiting.** Each provider has its own scheduler with a calls-per-minute limit (Massive defaults to 5, editable in Settings), FMP also has a daily cap, and rate-limit or server errors are retried with exponential backoff (honoring `Retry-After`). The UI shows "X of N loaded".
- **Resume.** Every sync diffs against the cache, so an interrupted backfill resumes where it stopped on the next launch.
- **Yahoo is unofficial.** If it fails, only the Backtest tab is affected.

### First-load timing on free plans

- **Prices:** the app picks whichever download needs fewer calls. One grouped call returns every US stock for one day (about 275 calls for ~13 months), and one per-ticker call returns ~13 months for one stock. At 5 calls per minute that means about 6 minutes for the Dow 30, about 20 minutes for the Top 100 (both per ticker), and about 55 minutes for the full S&P 500 (grouped). After the first load, a daily update is 1 grouped call. Keep the app open in the foreground. Partial results appear as the download runs, but momentum stays blank until 253 trading days are cached.
- **Fundamentals:** 2 calls per stock. Top 100 uses about 200 calls (one day). The full S&P 500 needs about 1,000 calls, so on the free plan it loads over 4 days and resumes automatically each day.
- **Backtest history:** 1 call per ticker, the first time you run a backtest.

## Architecture

```
FactorKit/                    Swift package (builds and tests on Linux)
 Package.swift
 Sources/FactorEngine/         Engine: pure Swift, no UI or network
  Statistics.swift            winsorize, z-score (sector / cross-sectional), ranks, Spearman, Pearson
  Returns.swift               12-1 momentum, realized vol, beta, moving averages, drawdown, Sharpe
  FactorModel.swift           metrics, factors, weights, presets, ScoringEngine
  Backtest.swift              quintile formation, monthly backtest, IC
  Clustering.swift            hierarchical clustering on correlations
  Portfolio.swift             weights → shares, Shock Lab CSV, basket warnings, consistency check
  VectorMath.swift            Accelerate (vDSP) with a plain-Swift fallback off Apple platforms
 Sources/FactorData/           Services: networking, rate limiting, sync (Foundation only)
  Models.swift                DailyBars, SplitEvent, Fundamentals, HistorySeries
  Providers.swift             PriceProvider / HistoryProvider / FundamentalsProvider protocols
  MassiveProvider.swift, YahooProvider.swift, FMPProvider.swift
  RequestScheduler.swift      per-provider rate limiter with backoff and daily cap
  Sync.swift                  PriceSync, FundamentalsSync, HistorySync (resume by diffing the cache)
  TradingCalendar.swift       NYSE trading days and holidays
  Resources/                  dow30.json, top100.json, sp500.json (ticker, name, GICS sector)
 Tests/                       XCTest suites (81 tests)
App/DraftBoard/               iOS app (MVVM)
  Models/                     SwiftData cache models, AppSettings
  Services/                   DataStore (@ModelActor), DataCoordinator, Keychain, LiveDataset
  ViewModels/                 ScoringModel, BacktestModel, WatchlistAnalysis
  Views/                      Screener, Detail, Backtest, Watchlist, Export, Settings, Components
```

Heavy work (scoring, panel building, backtests, correlations) runs on background tasks. SwiftData access goes through a `@ModelActor`, which is created off the main thread so its work doesn't run there.

## Methodology

### Factors

| Factor | Metrics (higher is better after orientation) |
|---|---|
| Value | Earnings yield (1 / P/E), EBITDA/EV (inverted EV/EBITDA), book-to-market (1 / P/B) |
| Quality | Return on equity, gross margin, debt-to-equity (inverted) |
| Momentum | 12-1 month return: `p[t−21] / p[t−252] − 1` |
| Low volatility | 1-year annualized realized volatility (inverted), 1-year beta vs SPY (inverted) |
| Size (optional) | log market cap (inverted, small-cap tilt) |

EV/EBITDA is inverted as EBITDA/EV, not as −EV/EBITDA, so companies with negative EBITDA rank as expensive rather than cheap. Negative debt-to-equity (negative equity) is treated as missing.

### Scoring

1. **Winsorize** each metric at the 1st and 99th percentile across the universe (linear interpolation).
2. **Z-score** each metric within its GICS sector (sector-neutral, the default) or across the universe. A sector with fewer than 3 stocks for a metric falls back to the universe z-score.
3. **Factor score** = mean of the factor's available metric z-scores.
4. **Composite** = weighted mean of factor scores using the user's weights, normalized to 100%. When a stock lacks a whole factor, the weights are renormalized over the factors it has.
5. Stocks missing more than 40% of the metrics used by active factors are **excluded**, and the Screener shows how many.

Presets: Balanced (25/25/25/25), Value (60/20/10/10), Quality (15/55/15/15), Momentum (10/15/65/10), and Defensive (10/35/5/50), in the order value / quality / momentum / low volatility, with size at 0.

### Backtest

Only price-based factors are used (momentum and low volatility), because using today's fundamentals for past dates would be look-ahead bias. At each month-end after a 12-month warm-up, the engine:

- computes 12-1 momentum from month-end prices and 1-year volatility and beta from daily prices,
- scores with the current momentum and low-volatility weights,
- forms 5 equal-weight quintiles (position `i` of `n` goes to quintile `⌊i·5/n⌋`),
- and holds them for one month.

Outputs are cumulative returns per quintile, the top-minus-bottom spread, annualized return, volatility, Sharpe (0% risk-free), max drawdown, and the monthly Spearman information coefficient with its mean. Results are cached by parameters and data version. Under 3 years of history, the app shows a "too short" notice.

### Watchlist analytics

Pearson correlations of the past year's daily Massive returns feed a heatmap and average-linkage hierarchical clustering (distance 1 − ρ, merge threshold 0.5). Warnings appear for pairs above 0.8 and for any sector above 40% of the basket.

### Export (Shock Lab)

The CSV has the columns `ticker,shares`. Shares = weight × portfolio value ÷ latest Massive close. Weights are equal or score-weighted (proportional to each stock's composite percentile). Shares can be whole (rounded down, with the leftover shown as cash) or fractional (4 decimals).

### Limitations

- **Survivorship bias.** Universes are today's index members, which flatters backtests.
- **The backtest is price-only.** Value and quality can't be tested without point-in-time fundamentals.
- **Yahoo Finance is unofficial** and may change or break without notice.
- **The bundled Top 100 list** is an approximate ranking by market cap as of October 2026.
- **Custom tickers outside the S&P 500** use FMP's sector names, which differ slightly from GICS.
- **No trading costs, taxes, or slippage** are modeled.
- Factor premia vary over time, and past performance does not predict future results.
