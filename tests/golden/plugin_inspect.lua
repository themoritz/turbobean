-- Walks every entry kind and emits a single error per entry summarizing
-- shape — locks the Data -> Lua schema in a golden output. Each error is
-- attached to its source entry so the squiggly underlines the directive.

local function keys(t)
  local out = {}
  for k, _ in pairs(t) do out[#out+1] = k end
  table.sort(out)
  return table.concat(out, ",")
end

return function(entries)
  local errors = {}
  for _, e in ipairs(entries) do
    local s
    if e.type == "transaction" then
      local p = e.postings[1]
      s = string.format(
        "tx %s flag=%s payee=%s narration=%s postings=%d tags=%s links=%s p1.account=%s p1.amount=%s p1.currency=%s",
        e.date, e.flag, e.payee, e.narration, #e.postings,
        table.concat(e.tags, ","), table.concat(e.links, ","),
        p.account, p.amount or "nil", p.currency or "nil"
      )
    elseif e.type == "open" then
      s = string.format(
        "open %s account=%s currencies=%s booking=%s meta=%s",
        e.date, e.account,
        table.concat(e.currencies or {}, ","),
        e.booking_method or "nil",
        keys(e.meta)
      )
    elseif e.type == "close" then
      s = string.format("close %s account=%s", e.date, e.account)
    elseif e.type == "balance" then
      s = string.format(
        "balance %s account=%s amount=%s currency=%s",
        e.date, e.account, e.amount, e.currency
      )
    elseif e.type == "commodity" then
      s = string.format("commodity %s currency=%s meta=%s", e.date, e.currency, keys(e.meta))
    elseif e.type == "price" then
      s = string.format(
        "price %s currency=%s amount=%s amount_currency=%s",
        e.date, e.currency, e.amount, e.amount_currency
      )
    elseif e.type == "event" then
      s = string.format("event %s variable=%s value=%s", e.date, e.variable, e.value)
    elseif e.type == "note" then
      s = string.format("note %s account=%s note=%s", e.date, e.account, e.note)
    else
      s = string.format("entry %s type=%s", e.date, e.type)
    end
    table.insert(errors, { message = s, entry = e })
  end
  return entries, errors
end
