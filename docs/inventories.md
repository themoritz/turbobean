# How Inventories Work in Turbobean

Inventories in Turbobean are handled a little bit different from Beancount,
with the following two goals in mind:

* Follow the [Booking Rules
  Redesign](https://docs.google.com/document/d/1H0UDD1cKenraIMe40PbdMgnqJdeqI6yKv0og51mXk-0/view?tab=t.0#heading=h.9lk1l7gqxxfs)
  document to address issues with the existing implementation.
* Make inventories and booking easier to understand and more predictable for
  beginners.

This document aims to explain how inventories work from the ground up, noting
differences to the existing Beancount implementation.

## Two Kinds of Inventory

Turbobean tracks account balances using *inventories*. Every account gets
exactly one inventory when it is opened, and there are two kinds of
inventories. The inventory can be plain and just keeps track of the accumulated
units. Or, it can keep track of individual lots which each having a cost basis
associated with it.

This distinction is different from Beancount where inventories can hold
positions both at cost and without cost. It makes it easier to mentally track
what an account contains, as well as helps implement one of the new design
changes of the booking syntax (see below).

The inventory kind depends on whether a booking method is specified when
opening the account:

```beancount
; No booking method => Just tracks units per currency
2020-01-01 open Expenses:Food

; Booking method defined => Tracks individual lots with cost basis
2020-01-01 open Assets:Stocks "FIFO"
```

In contrast to Beancount, for inventories held at cost, a booking method always
has to be defined. The booking method doesn't default to strict, like in
Beancount.

### Plain Inventory

A plain inventory maps each currency to a running total of units. Postings
simply add to or subtract from that total. There is no cost basis, no lot
tracking, and no booking logic. Use this inventory for tracking cash, expenses
etc.

```beancount
2020-01-01 open Assets:Cash

2020-01-02 * "Paycheck"
  Assets:Cash    1000 USD
  Income:Salary

2020-01-03 * "Groceries"
  Assets:Cash    -50 USD
  Expenses:Food
```

After these transactions, `Assets:Cash` holds `950 USD`.

#### Currency Conversions

A transaction can convert one currency to another in plain inventories:

```beancount
2020-01-02 * "Buy NZD"
  Assets:Cash   -10 EUR @ 2.00 NZD
  Assets:Cash    20 NZD
```

After this transaction, the `Assets:Cash` account has `10 EUR` less and `20 NZD` more.
The transaction is balanced through the conversion rate of `2.00 NZD/EUR`, but no cost
basis for the newly obtained NZD is tracked.

### Lot-Based Inventory

In contrast to a plain inventory, a lot-based inventory tracks the cost basis of each
new position (lot) in the inventory. This is useful for trading accounts or accounts that
contain securities and where you want to properly calculate profit/loss when closing
positions.

Let's say you open a position in Apple stock:

```beancount
2020-01-01 open Assets:Stocks "FIFO"

2025-01-01 * "Buy AAPL"
  Assets:Stocks   2 AAPL @ 10 EUR
  Assets:Cash
```

After this transaction, `Assets:Stocks` contains the following lot: `2 AAPL
@ 10 EUR {2025-01-01}`. The lot keeps track of the fact that you bought the two
Apple shares for 10 Euros each on 2025-01-01.

- **units** — how many units of the commodity
- **cost price** — the per-unit cost at acquisition
- **cost currency** — what currency the cost is denominated in
- **cost date** — when the lot was acquired (defaults to the transaction date)
- **label** — an optional string for explicit lot matching

Lots inventories are created when the `open` directive includes a booking
method string (`"FIFO"`, `"LIFO"`, or `"STRICT"`).

## Booking methods

The booking method determines how lots are consumed when you reduce a position
(e.g. selling shares). Three methods are supported:

### FIFO (First In, First Out)

The oldest lots are consumed first.

```beancount
2020-01-01 open Assets:Stocks AAPL "FIFO"
2020-01-01 open Assets:Cash

2020-01-02 * "Buy 10 shares at $10"
  Assets:Stocks   10 AAPL @ 10 USD
  Assets:Cash   -100 USD

2020-01-03 * "Buy 10 shares at $15"
  Assets:Stocks   10 AAPL @ 15 USD
  Assets:Cash   -150 USD

2020-01-04 * "Sell 15 shares at $30"
  Assets:Stocks  -15 AAPL @ 30 USD
  Assets:Cash    450 USD
```

The sale of 15 shares consumes all 10 shares from the $10 lot (oldest) and 5
shares from the $15 lot, leaving 5 AAPL at a cost basis of $15.

### LIFO (Last In, First Out)

The newest lots are consumed first.

```beancount
2020-01-01 open Assets:Stocks AAPL "LIFO"
2020-01-01 open Assets:Cash

2020-01-02 * "Buy 10 shares at $10"
  Assets:Stocks   10 AAPL @ 10 USD
  Assets:Cash   -100 USD

2020-01-03 * "Buy 10 shares at $15"
  Assets:Stocks   10 AAPL @ 15 USD
  Assets:Cash   -150 USD

2020-01-04 * "Sell 10 shares at $30"
  Assets:Stocks  -10 AAPL @ 30 USD
  Assets:Cash    300 USD
```

The sale consumes all 10 shares from the $15 lot (newest), leaving 10 AAPL at
a cost basis of $10.

### STRICT

Lot matching must be unambiguous. Either you sell the **exact total** of all
held lots (closing the entire position), or you provide an explicit lot spec in
`{}` to identify which lot to reduce.

Selling the entire position without a lot spec:

```beancount
2020-01-01 open Assets:Stocks AAPL "STRICT"
2020-01-01 open Assets:Cash

2020-01-02 * "Buy"
  Assets:Stocks   10 AAPL @ 10 USD
  Assets:Cash   -100 USD

2020-01-03 * "Buy"
  Assets:Stocks   10 AAPL @ 15 USD
  Assets:Cash   -150 USD

2020-01-04 * "Sell all 20 shares"
  Assets:Stocks  -20 AAPL @ 30 USD
  Assets:Cash    600 USD
```

Selling a partial position requires a lot spec:

```beancount
2020-01-04 * "Sell only the $10 lot"
  Assets:Stocks  -10 AAPL {10 USD} @ 30 USD
  Assets:Cash    300 USD
```

A partial sale without a lot spec produces an `ambiguous_strict_booking` error.

## Lot specs

A lot spec in `{}` narrows which lot a posting targets. It can contain any
combination of cost price, date, and label:

```beancount
; Match by cost price
Assets:Stocks  -10 AAPL {10 USD} @ 30 USD

; Match by date
Assets:Stocks  -10 AAPL {2020-01-02} @ 30 USD

; Match by label
Assets:Stocks  -10 AAPL {"magic lot"} @ 30 USD

; Match by cost price and date
Assets:Stocks  -10 AAPL {10 USD, 2020-01-02} @ 30 USD
```

All specified fields must match exactly. If the spec matches zero lots, a
`lot_spec_no_match` error is produced. If it matches more than one lot, a
`lot_spec_ambiguous_match` error is produced. If the matched lot holds fewer
units than the posting requests, a `lot_spec_match_too_small` error is
produced.

### Lot specs when adding

Lot specs can also appear on postings that **add** to a position. The spec
fields override the defaults for the new lot:

```beancount
; Override the cost date (useful for stock splits or transfers)
2020-01-03 * "Split"
  Assets:Stocks  -10 AAPL {10 USD, 2020-01-02} @ 2 USD
  Assets:Stocks   20 AAPL {5 USD,  2020-01-02} @ 1 USD
```

This is useful for stock splits (adjusting the number of shares and cost per
share while preserving the original acquisition date) and for transferring lots
between accounts:

```beancount
2020-01-03 * "Move shares to another account"
  Assets:Stocks      -10 AAPL {10 USD, 2020-01-02} @ 1 USD
  Assets:MoreStocks   10 AAPL {10 USD, 2020-01-02} @ 1 USD
```

### Labels

Labels are arbitrary strings that tag a lot for later identification, useful
with `STRICT` booking:

```beancount
2020-01-02 * "Buy"
  Assets:Stocks   10 AAPL {"magic lot"} @ 10 USD
  Assets:Cash   -100 USD

2020-01-03 * "Buy"
  Assets:Stocks   10 AAPL {"magic lot"} @ 15 USD
  Assets:Cash   -150 USD
```

Note: if multiple lots share the same label and you try to match by label
alone, the match is ambiguous and produces an error. You would need to combine
the label with a cost price or date to disambiguate.

## Short positions

Lots inventories support short positions. A short is opened by posting a
negative amount to a booked account that has no existing long position:

```beancount
2020-01-01 open Assets:Stocks SHORT "FIFO"
2020-01-01 open Assets:Cash

2020-01-02 * "Open short"
  Assets:Stocks  -1 SHORT @ 10 USD
  Assets:Cash    10 USD

2020-01-03 * "Close short, cross line"
  Assets:Stocks   2 SHORT @ 20 USD
  Assets:Cash   -40 USD
```

Booking 2 units against a short of 1 consumes the short and creates a new long
of 1. The same FIFO/LIFO/STRICT rules apply in reverse: for LIFO shorts, the
most recently opened short is closed first.

The inventory enforces that an account holds **either longs or shorts** for a
given commodity at any point, never both simultaneously. A posting can cross
from one side to the other (as in the example above), but the resulting
inventory will only contain positions on one side.

## Currency restrictions

The `open` directive can restrict which commodities an account may hold:

```beancount
; Can only hold AAPL
2020-01-01 open Assets:Stocks AAPL "FIFO"

; Can hold AAPL and GOOG
2020-01-01 open Assets:Stocks AAPL, GOOG "FIFO"

; Can hold any commodity (unrestricted)
2020-01-01 open Assets:Stocks "FIFO"

; Plain account restricted to USD and EUR
2020-01-01 open Assets:Cash USD, EUR
```

Posting a commodity that is not in the restriction list produces a
`does_not_hold_currency` error.

## Price annotations

The `@` and `@@` annotations specify the cost per unit or total cost:

```beancount
; Per-unit price: 10 AAPL at 100 USD each
Assets:Stocks  10 AAPL @ 100 USD

; Total price: 10 AAPL for 1000 USD total (= 100 USD each)
Assets:Stocks  10 AAPL @@ 1000 USD
```

For lots inventories, the price annotation determines the **cost basis** of the
new lot. For plain inventories, price annotations are not supported for booking
but are recorded for price tracking.

A posting with a price annotation goes through `bookPosition` (lots inventory
path). A posting without one goes through `addPosition` (plain inventory
path). This means that **any posting with `@` or `@@` requires the target
account to have a lots inventory** (i.e., a booking method must be specified in
the `open` directive).

## Inferred prices

When a lot spec provides a cost price but no `@` annotation, the cost price is
used directly:

```beancount
2025-12-10 open Assets:Stocks "FIFO"
2025-12-10 open Assets:Cash

2025-12-10 * "Buy"
  Assets:Stocks  10 AAPL {2 USD}
  Assets:Cash
```

This creates a lot of 10 AAPL with a cost basis of 2 USD per share, and
auto-balances the cash leg to -20 USD.

## Differences from Python Beancount

### No NONE or AVERAGE booking

Python beancount supports `NONE` (no reduction, lots accumulate) and `AVERAGE`
(weighted average cost) booking methods. Turbobean only supports `FIFO`,
`LIFO`, and `STRICT`.

### Cost spec syntax

Python beancount uses `{...}` for both specifying cost on new lots and matching
existing lots, with fields like `{100 USD, 2020-01-15, "label"}`. Turbobean
uses the same syntax and supports the same fields (price, date, label), but the
semantics are slightly different:

- In turbobean, a lot spec on an **adding** posting overrides the lot's stored
  cost fields (price, date, label). The `@` annotation determines the actual
  cost price used for booking.
- In Python beancount, `{...}` on a new posting *is* the cost specification,
  and `@` is the acquisition price with more complex interpolation rules.
