local M = {}

---@param panel sidekick.cli.Panel
---@param target? string|integer Session id or native tabpage id.
---@return boolean
function M.matches(panel, target)
  if target == nil then
    return true
  end
  if type(target) == "number" then
    return panel.tab == target
  end
  return panel.active == target or vim.list_contains(panel.order, target)
end

---@param panels table<integer,sidekick.cli.Panel>
---@param target? string|integer Session id or native tabpage id.
---@param cb fun(tab:integer,panel:sidekick.cli.Panel)
function M.each(panels, target, cb)
  for tab, panel in pairs(panels) do
    if M.matches(panel, target) then
      cb(tab, panel)
    end
  end
end

return M
