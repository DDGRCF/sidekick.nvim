---@module 'luassert'

local Config = require("sidekick.config")

local providers = {
  { name = "antigravity", capabilities = { resume = true, fork = true, continue = true, managed_session = false } },
  { name = "claude", capabilities = { resume = true, fork = true, continue = true, managed_session = false } },
  { name = "codex", capabilities = { resume = true, fork = true, continue = true, managed_session = false } },
  { name = "copilot", capabilities = { resume = true, fork = false, continue = true, managed_session = true } },
  { name = "crush", capabilities = { resume = true, fork = false, continue = false, managed_session = false } },
  { name = "cursor", capabilities = { resume = true, fork = true, continue = false, managed_session = false } },
  { name = "grok", capabilities = { resume = true, fork = true, continue = false, managed_session = false } },
  { name = "omp", capabilities = { resume = true, fork = true, continue = true, managed_session = true } },
  { name = "opencode", capabilities = { resume = true, fork = true, continue = true, managed_session = false } },
  { name = "pi", capabilities = { resume = true, fork = false, continue = true, managed_session = true } },
}

describe("cli provider capabilities", function()
  for _, provider in ipairs(providers) do
    it("declares " .. provider.name .. " capabilities", function()
      local tool = Config.get_tool(provider.name)
      local capabilities = tool.config.capabilities

      assert.are.same(provider.capabilities, capabilities)
      assert.are.equal(capabilities.resume, tool.config.resume ~= nil)
      assert.are.equal(capabilities.fork, tool.config.fork ~= nil and tool.config.fork ~= false)
      assert.are.equal(capabilities.continue, tool.config.continue ~= nil)
    end)
  end

  it("infers capabilities for custom providers that do not declare them", function()
    local name = "sidekick-capability-test"
    local original = Config.cli.tools[name]
    Config.cli.tools[name] = {
      cmd = { "true" },
      resume = { "resume" },
      fork = { "fork" },
    }

    local capabilities = Config.get_tool(name).config.capabilities
    Config.cli.tools[name] = original

    assert.are.same({ resume = true, fork = true, continue = false, managed_session = false }, capabilities)
  end)
end)
