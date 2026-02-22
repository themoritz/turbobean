# How Inventories Work in Turbobean

Inventories in Turbobean are handled a little bit different from Beancount,
with the following two goals in mind:

* Follow the [Booking Rules
  Redesign](https://docs.google.com/document/d/1H0UDD1cKenraIMe40PbdMgnqJdeqI6yKv0og51mXk-0/view?tab=t.0#heading=h.9lk1l7gqxxfs)
  document to address issues with the existing implementation. Please refer to
  that document for the motivations behind the redesign.
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

A transaction can convert one currency to another in a plain inventory:

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
Apple shares for 10 EUR each on 2025-01-01.

In accordance with the Beancount Booking Rules Redesign, the syntax for buying stock
is the same as for converting currency above. The difference in behavior is just coming
from the fact that the accounts are of a different kind.

**Note:** In Beancount, you would write above posting as `Assets:Stocks   2 AAPL {10 EUR}`.
This is still possible in Turbobean for backwards compatibility. You just get a warning.

Let's say you buy more AAPL:

```beancount
2025-01-02 * "Buy more AAPL"
  Assets:Stocks  1 AAPL @ 15 EUR
  Assets:Cash
```

Now the inventory looks like this:

```
• 2 AAPL @ 10 EUR {2025-01-01}
• 1 AAPL @ 15 EUR {2025-01-02}
```

As you can see, every new lot is individually tracked along with the price and
date it was added to the inventory.

#### Booking Methods

The booking method determines how lots are consumed when you reduce a position
(e.g. selling shares). The choice of which lot to consume can be automatic (FIFO/LIFO)
or manual (STRICT).

##### FIFO (First In, First Out)

The oldest lots are consumed first. Let's say you sell AAPL with the following
transaction:

```beancount
2020-01-01 open Assets:Stocks "FIFO"

[...]

2020-01-04 * "Sell some AAPL"
  Assets:Stocks  -2 AAPL @ 30 USD
  Assets:Cash    60 EUR
```

The sale of 2 shares consumes all 2 shares from the 10 EUR lot (oldest) and none
from the 15 EUR lot, leaving 1 AAPL at a cost basis of 15 EUR:

```
• 1 AAPL @ 20 EUR {2025-01-02}
```

##### LIFO (Last In, First Out)

The newest lots are consumed first. The sale comsumes the 1 share at 15 EUR cost basis
and one of the two shares at 10 EUR cost. After above transaction the inventory looks
as follows:

```
• 1 AAPL @ 10 EUR {2025-01-01}
```

##### STRICT

You provide an explicit lot spec in `{}` to identify which lot to reduce.

```beancount
2020-01-01 open Assets:Stocks "STRICT"

[...]

2025-01-04 * "Sell only from the 10 EUR lot"
  Assets:Stocks  -1 AAPL {10 EUR} @ 30 EUR
  Assets:Cash    30 EUR
```

Here, we're saying explicitly to sell one of the AAPL shares we've bought for
10 EUR. You can also use other properties of the lot to identify it, as long as
it's unique. We could also identify the same lot by its date:

```beancount
2025-01-04 * "Sell from the first lot"
  Assets:Stocks  -1 AAPL {2025-01-01} @ 30 EUR
  Assets:Cash    30 EUR
```

Strict booking also allows to closing the whole existing position if the size
is equal to the amount sold. Here we're selling the whole inventory of 3 AAPL
shares:

```beancount
2025-01-04 * "Sell all my AAPL"
  Assets:Stocks  -3 AAPL @ 30 EUR
  Assets:Cash    90 EUR
```

##### Manual Override

Even with FIFO or LIFO booking, you can always override which lot to reduce
with a lot spec in curly braces `{}`. The cost spec can contain any
combination of cost price, date, and label.

All specified fields in the curly braces must match exactly, and exactly one
lot has to be matched. The matched lot has to hold at least as many units as the posting
requests to be reduced.

#### Lot Specs When Adding

Lot specs can also appear on postings that **add** to a position. The spec
fields override the defaults for the new lot:

```beancount
; Override the cost date (useful for stock splits or transfers)
2020-01-03 * "Split"
  Assets:Stocks  -10 AAPL {10 USD, 2020-01-02} @ 2 USD
  Assets:Stocks   20 AAPL { 5 USD, 2020-01-02} @ 1 USD
```

This is useful for stock splits (adjusting the number of shares and cost per
share while preserving the original acquisition date) and for transferring lots
between accounts:

```beancount
2020-01-03 * "Move shares to another account"
  Assets:Stocks      -10 AAPL {10 USD, 2020-01-02} @ 1 USD
  Assets:MoreStocks   10 AAPL {10 USD, 2020-01-02} @ 1 USD
```

#### Lot Labels

Labels are arbitrary strings that tag a lot for later identification, useful
with `STRICT` booking:

```beancount
2020-01-02 * "Buy"
  Assets:Stocks   10 AAPL {"magic lot"} @ 10 USD
  Assets:Cash   -100 USD

2020-01-03 * "Sell"
  Assets:Stocks  -10 AAPL {"magic lot"} @ 15 USD
  Assets:Cash    150 USD
```

Note: if multiple lots share the same label and you try to match by label
alone, the match is ambiguous and produces an error. You would need to combine
the label with a cost price or date to disambiguate.

#### Short positions

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

#### Profit and Loss

When you reduce a position this incurs a profit or loss, based on the cost that you
paid when purchasing the stock as well as the sales price. Turbobean can automatically
post this profit or loss to an account of your choosing:

```beancount
2020-01-01 open Assets:Cash
2020-01-01 open Income:Gains
2020-01-01 open Assets:Stocks "LIFO"

2020-01-01 pnl Assets:Stocks Income:Gains

2025-01-01 * "Buy AAPL"
  Assets:Stocks  2 AAPL @ 10 EUR
  Assets:Cash

2025-01-04 * "Sell some AAPL"
  Assets:Stocks  -1 AAPL @ 30 EUR
  Assets:Cash
```

The account `Income:Gains` has `-20 EUR` now (remember that income has
a negative sign in Beancount).

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

Posting a commodity that is not in the restriction list produces an error.

## Compatibility and Migration Guide

My aim (not yet achieved) is to design Turbobean in a way that it is compatible
with Beancount in the following way:

- Be backwards-compatible with existing .bean files as much as possible.
- Where this is not possible, you migrate your .bean files with a few simple changes.
  Ideally, if you don't have transactions with complex bookings, you only have
  to touch account definitions and no transactions.
- The migrated .bean files should still work with Beancount.

The following migrations are necessary because the new booking system prevents
backwards-compatibility:

* If you have accounts that hold lots with and without cost basis, split them
  into two accounts. For example, I used to have brokerage accounts
  (e.g. `Assets:Securities:Fidelity`) that contained the securities as well as
  cash, where the securities had a cost basis and the cash didn't. Now, I have
  an additional account `Assets:Securities:Fidelity:Cash`.
* Add an explicit booking method to each lot-based account.
