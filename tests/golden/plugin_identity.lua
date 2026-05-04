-- Identity plugin: returns entries unchanged. The resulting tree must match
-- what you'd get without any plugin — i.e. a faithful Data -> Lua -> Data
-- round-trip preserves balances and checks.
return function(entries)
  return entries, {}
end
