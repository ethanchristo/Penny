# Penny

**Penny is a private, on-device personal finance app for iPhone.** Track your income and expenses, set budgets, save toward goals, and understand your financial health — all while keeping your data on your own device.

Penny is built entirely with SwiftUI and SwiftData, uses Apple's on-device AI for smart categorization, and optionally syncs privately through your own iCloud account. Your financial data is never sent to Penny's servers — because Penny doesn't have any.

---

## Features

### 💰 Net Total & Financial Health
- See your net worth at a glance, color-coded green / yellow / red so you always know where you stand.
- Choose the time window that matters to you: **Daily, Weekly, Monthly, Yearly, All Time, or Pay Period** (a window anchored to your actual payday).
- Set a custom "yellow" warning threshold to know when your balance is getting low.
- Optionally fold upcoming recurring expenses into the total so you can see what's really left.

### 🧾 Transactions
- Add, edit, and delete income and expenses with merchant names and notes.
- Set up **recurring transactions** — daily, weekly, biweekly, monthly, quarterly, semi-annual, or yearly — with optional end dates.
- Assign each transaction to a **Category** or a **Fund**.
- Sort, filter, and group by date, account, category, or income/expense type.

### 📊 Budgets
- Set spending limits per category, or one overall budget across everything.
- Track your progress against each limit with clear visual insights.
- Match budget windows to your spending rhythm (daily through yearly).

### 🎯 Funds (Savings Goals)
- Create named savings goals with target amounts and dates.
- Watch your progress, contributions, and remaining balance grow.
- Personalize each fund with its own symbol and color.

### 🏦 Accounts & Cards
- Track checking, savings, and credit card accounts.
- Flexible credit card handling — count the full balance, the statement amount due, or transactions in a given window.
- Store billing closing and due dates.

### 📈 Insights
- **Spending** trends over time.
- **Category** breakdowns with charts.
- **Cash Flow** — income versus expenses at a glance.
- **Recurring** — an upcoming calendar of your repeating transactions.

### 🤖 Smart, On-Device Categorization
Penny uses Apple's **on-device Foundation Models** to automatically categorize imported transactions and read transaction emails. All of this happens locally on your iPhone — nothing is sent to the cloud for processing.

### 🔗 Data Import
- **SimpleFIN** — securely sync transactions and balances from your bank and credit cards via the open [SimpleFIN Bridge](https://www.simplefin.org) service. (SimpleFIN is a separate third-party service, ~$1.50/month or $15/year.)
- Duplicate detection keeps re-syncs clean.

### 📱 Shortcuts
- "Log a transaction," "Add an expense," "Record income."
- "What's my net total?" — answered right in Spotlight.
- Open a specific budget, fund, or transaction by voice.
- Funds, categories, and budgets are indexed in Spotlight search.

### 📱 Home Screen Widget
- A **Net Total widget** shows your current standing without opening the app.

### ☁️ Private iCloud Sync
- Your data optionally syncs across your devices through **your own private iCloud account** using CloudKit. If you're not signed into iCloud, Penny works fully offline.

---

## Privacy First

Penny is designed so that **your financial data stays yours**:

- All data is stored **locally on your device** using SwiftData.
- Optional sync goes only to **your private iCloud account** — never to a Penny server.
- **Penny operates no servers and collects no analytics.**
- Bank connection credentials (SimpleFIN) are stored securely in the **iOS Keychain**.
- Transaction categorization and email parsing run **on-device** with Apple's Foundation Models.

See the full [Privacy Policy](PRIVACY.md).

---

## Requirements

- iPhone running **iOS 26.2 or later**
- (Optional) An iCloud account for cross-device sync
- (Optional) A [SimpleFIN](https://www.simplefin.org) subscription for automatic bank syncing
- (Optional) A Gmail account for email-based transaction import

---

## Tech Stack

- **SwiftUI** — user interface
- **SwiftData** — local persistence (with CloudKit for private sync)
- **WidgetKit** — home screen widget
- **App Intents** — Siri Shortcuts and Spotlight
- **Foundation Models** — on-device AI categorization
- **SimpleFIN** — optional bank data import

---

## Support

Need help or have a question?

- **Email:** pennybudgetapp@gmail.com
- **Issues:** Please open an issue in this repository.

---

## App Store Information

- **App name:** Penny
- **Bundle identifier:** `com.ethanchristo.Penny`
- **Category:** Finance
- **Version:** 1.0
- **Developer:** Ethan Christo

> **Note for publishing:** When submitting to App Store Connect, you'll need to host the
> [Privacy Policy](PRIVACY.md) and this support page at public URLs. The easiest option is to
> enable **GitHub Pages** on this repository (Settings → Pages), which will publish these
> Markdown files as a website you can link to in App Store Connect's **Privacy Policy URL**
> and **Support URL** fields.
