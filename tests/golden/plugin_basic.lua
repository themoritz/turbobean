return function(entries)
  local errors = {}
  for _, e in ipairs(entries) do
    if e.type == "transaction" then
      table.insert(errors, {
        message = string.format(
          "txn %s payee=%s narration=%s postings=%d",
          e.date,
          e.payee or "?",
          e.narration or "?",
          #e.postings
        ),
        entry = e,
      })
    end
  end
  return entries, errors
end
