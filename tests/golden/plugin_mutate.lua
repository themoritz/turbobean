return function(entries)
	for _, e in ipairs(entries) do
		if e.type == "transaction" then
			for _, p in ipairs(e.postings) do
				if p.amount then
					p.amount = tostring(tonumber(p.amount) * 2)
				end
			end
		end
	end
	return entries, {}
end
