import Foundation
import FactorEngine

/// Plain-English explanations behind every info button.
enum Explain {
    struct Entry: Identifiable, Hashable {
        var id: String { title }
        let title: String
        let body: String
    }

    static func metric(_ m: Metric) -> Entry {
        switch m {
        case .earningsYield:
            return Entry(title: "Earnings yield (E/P)", body: "Yearly profit per share divided by the share price: the flip side of the P/E ratio. A 5% earnings yield means you pay $20 for every $1 of annual profit. Higher means cheaper.")
        case .ebitdaToEV:
            return Entry(title: "EV/EBITDA (inverted)", body: "Enterprise value (market cap plus debt minus cash) divided by operating earnings before interest, taxes and depreciation. It compares companies regardless of how much debt they carry. We flip it so higher is cheaper, which also ranks loss-making companies correctly.")
        case .bookToMarket:
            return Entry(title: "Book-to-market", body: "The accounting value of the company's net assets divided by its market value. A high number means the market values the company close to what it owns on paper. It's a classic value signal.")
        case .roe:
            return Entry(title: "Return on equity (ROE)", body: "Profit as a percentage of shareholders' equity: how much the company earns on the money owners have invested. Higher is better, but very high ROE can come from heavy debt.")
        case .grossMargin:
            return Entry(title: "Gross margin", body: "The share of each sales dollar left after paying the direct cost of the product. High margins often signal pricing power or a strong brand.")
        case .debtToEquity:
            return Entry(title: "Debt-to-equity (inverted)", body: "Total debt divided by shareholders' equity. Lower debt means less financial risk, so lower scores better. Companies with negative equity are treated as missing data rather than as having low debt.")
        case .momentum12_1:
            return Entry(title: "12-1 month momentum", body: "The stock's return from 12 months ago to 1 month ago. The most recent month is skipped because very short-term winners tend to give back gains briefly. Stocks that have risen over the past year have historically kept outperforming for a while.")
        case .volatility:
            return Entry(title: "1-year volatility (inverted)", body: "How much the price has swung day to day over the last year, scaled to a yearly figure. Calmer stocks score higher. Historically, low-volatility stocks have delivered similar returns to riskier ones with smaller swings.")
        case .beta:
            return Entry(title: "Beta vs S&P 500 (inverted)", body: "How much the stock tends to move when the market (SPY) moves. A beta of 1.5 means it has typically moved 1.5% for every 1% market move. Lower beta scores higher in the low-volatility factor.")
        case .marketCap:
            return Entry(title: "Market cap (size tilt)", body: "The total market value of the company's shares. The optional size factor favors smaller companies, which have historically earned a small premium with more risk. It's off by default.")
        }
    }

    static func factor(_ f: Factor) -> Entry {
        switch f {
        case .value: return Entry(title: "Value", body: "Is the stock cheap relative to its earnings, cash flow and assets? Combines earnings yield, EV/EBITDA and book-to-market.")
        case .quality: return Entry(title: "Quality", body: "Is this a profitable, financially sound business? Combines return on equity, gross margin and (low) debt-to-equity.")
        case .momentum: return Entry(title: "Momentum", body: "Has the stock been a winner over the past year? Uses the 12-month return excluding the latest month.")
        case .lowVolatility: return Entry(title: "Low volatility", body: "Is the stock steady? Combines low one-year volatility and low beta to the market.")
        case .size: return Entry(title: "Size", body: "An optional tilt toward smaller companies by market cap.")
        }
    }

    static let composite = Entry(title: "Composite score", body: "Each metric is converted to a z-score: how many standard deviations a stock is above or below its peers. Extreme values are first capped at the 1st and 99th percentiles. Metrics are averaged into factor scores, and the factors are combined using your weights. A score of +1 means about one standard deviation better than the average peer.")
    static let sectorNeutral = Entry(title: "Sector-neutral scoring", body: "When on, each stock is compared only with others in the same GICS sector. A bank is ranked against banks, not against software companies. This stops the screener from simply picking whichever sector looks cheapest or strongest. Turn it off to compare every stock against the whole universe.")
    static let sectorPercentile = Entry(title: "Sector percentile", body: "Where the stock's composite score ranks within its own sector. 90 means it scores better than 90% of its sector peers.")
    static let excluded = Entry(title: "Excluded stocks", body: "Stocks missing more than 40% of the metrics your current weights use aren't scored, so a handful of numbers can't decide their rank. This is usually because fundamentals or price history haven't loaded yet.")
    static let ic = Entry(title: "Information coefficient (IC)", body: "Each month, the rank correlation between the model's scores and the stocks' returns over the next month. +1 would mean perfect ranking and 0 no skill. In practice, an average IC of 0.02–0.05 is considered meaningful.")
    static let spread = Entry(title: "Long/short spread", body: "The return of the top quintile minus the bottom quintile each month. It shows whether the model separates winners from losers, regardless of which way the overall market went.")
    static let sharpe = Entry(title: "Sharpe ratio", body: "Annualized return divided by annualized volatility (assuming a 0% risk-free rate). It measures return per unit of risk. Above 0.5 is decent for a stock portfolio.")
    static let maxDrawdown = Entry(title: "Max drawdown", body: "The largest peak-to-trough fall in the portfolio's value during the test. It answers: what was the worst loss I'd have had to sit through?")
    static let correlation = Entry(title: "Return correlation", body: "How closely two stocks' daily returns move together over the past year, from −1 (opposite) to +1 (in lockstep). Pairs above 0.8 add little diversification.")
    static let clusters = Entry(title: "Clusters", body: "Stocks are grouped by hierarchical clustering on their return correlations, using average linkage and a distance of 1 − correlation. Stocks in the same cluster tend to move together, so owning several of them is closer to owning one bet.")
    static let quintiles = Entry(title: "Quintile portfolios", body: "Every month, stocks are ranked by score and split into five equal groups. Q1 holds the top 20% and Q5 the bottom 20%. Each group is held with equal weights for one month. A working model shows Q1 above Q5.")
    static let dividendYield = Entry(title: "Dividend yield", body: "Annual dividends per share divided by the share price.")
    static let peRatio = Entry(title: "P/E ratio", body: "Share price divided by the last 12 months of earnings per share.")
}
