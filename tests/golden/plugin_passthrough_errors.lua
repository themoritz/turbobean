-- Identity plugin: the post-plugin pipeline (balance, check) must still
-- surface its errors at the original .bean source — `Expenses:NotOpened`
-- in the posting list — instead of the synth file.
return function(entries)
  return entries, {}
end
