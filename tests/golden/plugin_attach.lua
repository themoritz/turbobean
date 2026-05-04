-- Demonstrates `error.entry` (squiggly on the directive),
-- `error.posting` (squiggly on the offending account), and
-- `error.severity` ("warn" or "error", default "error").
return function(entries)
  local errors = {}
  for _, e in ipairs(entries) do
    if e.type == "transaction" and e.payee == "Acme" then
      table.insert(errors, {
        message = "Acme is on the watchlist",
        severity = "warn",
        entry = e,
      })
    end
    if e.postings then
      for _, p in ipairs(e.postings) do
        if p.account:match("^Equity:") then
          table.insert(errors, {
            message = "no Equity postings allowed",
            posting = p,
          })
        end
      end
    end
  end
  return entries, errors
end
